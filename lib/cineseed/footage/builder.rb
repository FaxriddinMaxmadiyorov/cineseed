require "open3"
require "json"
require "yaml"
require "fileutils"
require "net/http"
require "uri"

module Cineseed
  module Footage
    # Turns the long source videos listed in footage/sources.yml into a library of short, normalized
    # shots that the trailer engine can cut together quickly:
    #
    #   1. scene detection (ffmpeg `select=gt(scene,...)`) inside the allowed time ranges
    #   2. every scene becomes one or more shots of min_shot..max_shot seconds
    #   3. each shot is re-encoded to 24 fps, at most 960x540, H.264 with a short GOP (fast seeking)
    #   4. a still is extracted (used for posters) and luma / saturation / warmth / motion are measured
    #
    # Nothing here runs at request time; the result is footage/manifest.json plus clips/ and stills/.
    class Builder
      FPS = 24
      MAX_W = 854
      MAX_H = 480

      attr_reader :root

      def initialize(root:, only: nil, jobs: 2, out: $stdout)
        @root = Pathname(root)
        @only = Array(only).map(&:to_s).reject(&:empty?)
        @jobs = jobs
        @out = out
      end

      def run!
        config = YAML.load_file(root.join("sources.yml"))
        defaults = config.fetch("defaults", {})
        sources = config.fetch("sources")
        sources = sources.select { |s| @only.include?(s["id"]) } if @only.any?

        manifest = load_manifest
        sources.each do |source|
          opts = defaults.merge(source)
          path = fetch(source)
          clips = process(path, opts)
          manifest["clips"].reject! { |c| c["source"] == source["id"] }
          manifest["clips"].concat(clips)
          manifest["sources"][source["id"]] = source.slice("family", "license", "attribution", "url", "tags")
          log "#{source['id']}: #{clips.size} shots"
        end

        manifest["clips"].sort_by! { |c| c["id"] }
        File.write(root.join("manifest.json"), JSON.pretty_generate(manifest))
        log "manifest: #{manifest['clips'].size} shots from #{manifest['sources'].size} sources"
        manifest
      end

      private

      def load_manifest
        path = root.join("manifest.json")
        data = path.exist? ? JSON.parse(path.read) : {}
        { "version" => 1, "fps" => FPS, "sources" => data.fetch("sources", {}), "clips" => data.fetch("clips", []) }
      end

      def log(msg) = @out.puts("[footage] #{msg}")

      # --- download -------------------------------------------------------------------------------

      def fetch(source)
        dir = root.join("sources")
        FileUtils.mkdir_p(dir)
        existing = Dir[dir.join("#{source['id']}.*").to_s].first
        return existing if existing && File.size?(existing)

        url = source.fetch("url")
        ext = File.extname(URI(url).path).presence || ".mp4"
        dest = dir.join("#{source['id']}#{ext}").to_s
        log "downloading #{url}"
        download(url, dest)
        dest
      end

      def download(url, dest, limit = 5)
        raise "too many redirects for #{url}" if limit.zero?

        uri = URI(url)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 600) do |http|
          http.request(Net::HTTP::Get.new(uri)) do |response|
            case response
            when Net::HTTPRedirection
              return download(URI.join(url, response["location"]).to_s, dest, limit - 1)
            when Net::HTTPSuccess
              File.open("#{dest}.part", "wb") { |f| response.read_body { |chunk| f.write(chunk) } }
              File.rename("#{dest}.part", dest)
            else
              raise "download failed (#{response.code}) for #{url}"
            end
          end
        end
      end

      # --- shot detection -------------------------------------------------------------------------

      def process(path, opts)
        duration = probe_duration(path)
        ranges = (opts["include"] || [[0, duration]]).map { |a, b| [a.to_f, [b.to_f, duration].min] }

        segments = ranges.flat_map do |from, to|
          cuts = detect_cuts(path, opts["pre"], from, to, opts["scene_threshold"].to_f)
          segments_between([from, *cuts, to], opts)
        end
        segments = spread(segments, opts["max_shots"].to_i)

        clips = []
        mutex = Mutex.new
        queue = Queue.new
        segments.each_with_index { |seg, i| queue << [seg, i] }
        workers = Array.new(@jobs) do
          Thread.new do
            loop do
              seg, i = begin
                queue.pop(true)
              rescue ThreadError
                break
              end
              clip = encode_shot(path, opts, seg, i)
              mutex.synchronize { clips << clip } if clip
            end
          end
        end
        workers.each(&:join)
        clips.sort_by { |c| c["start"] }
      end

      def detect_cuts(path, pre, from, to, threshold)
        vf = [pre, "fps=12", "scale=256:-2", "select='gt(scene,#{threshold})'", "metadata=print:file=-"].compact.join(",")
        stdout, = ffmpeg("-ss", from.to_s, "-t", (to - from).to_s, "-i", path, "-vf", vf, "-an", "-f", "null", "-")
        stdout.scan(/pts_time:([\d.]+)/).flatten.map { |t| from + t.to_f }.select { |t| t > from + 0.3 && t < to - 0.3 }
      end

      # Each scene becomes shots of at most max_shot seconds; a long scene yields several shots that
      # share the same `scene` id so the trailer director never uses two of them in one trailer.
      def segments_between(bounds, opts)
        min_len = opts["min_shot"].to_f
        max_len = opts["max_shot"].to_f
        bounds.each_cons(2).with_index.flat_map do |(a, b), scene_idx|
          a += 0.12
          b -= 0.12
          len = b - a
          next [] if len < min_len

          pieces = (len / max_len).ceil
          piece = len / pieces
          Array.new(pieces) do |k|
            s = a + k * piece
            { start: s.round(3), duration: [piece, max_len].min.round(3), scene: scene_idx }
          end
        end
      end

      # Keep at most `count` shots, spread evenly over the source so every part of it is represented.
      def spread(segments, count)
        return segments if count <= 0 || segments.size <= count

        step = segments.size.to_f / count
        Array.new(count) { |i| segments[(i * step).floor] }.uniq
      end

      # --- encoding + measurements ---------------------------------------------------------------

      def encode_shot(path, opts, seg, index)
        id = format("%s-%03d", opts["id"], index + 1)
        clip_rel = "clips/#{id}.mp4"
        still_rel = "stills/#{id}.jpg"
        clip_path = root.join(clip_rel).to_s
        still_path = root.join(still_rel).to_s
        FileUtils.mkdir_p(File.dirname(clip_path))
        FileUtils.mkdir_p(File.dirname(still_path))

        scale = "scale='min(#{MAX_W},iw)':'min(#{MAX_H},ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos"
        vf = [opts["pre"], "fps=#{FPS}", scale, "setsar=1", "format=yuv420p"].compact.join(",")
        ffmpeg("-y", "-ss", seg[:start].to_s, "-t", seg[:duration].to_s, "-i", path, "-vf", vf, "-an",
               "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-maxrate", "850k", "-bufsize", "1700k",
               "-tune", "film", "-g", "24",
               "-movflags", "+faststart", clip_path)
        return nil unless File.size?(clip_path)

        stats = measure(clip_path)
        if stats[:luma] < 18 || stats[:range] < 30
          FileUtils.rm_f(clip_path)
          return nil
        end

        clip_duration = probe_duration(clip_path)
        ffmpeg("-y", "-ss", (clip_duration * 0.4).round(2).to_s, "-i", clip_path, "-frames:v", "1", "-q:v", "3", still_path)
        width, height = probe_size(clip_path)

        {
          "id" => id,
          "source" => opts["id"],
          "family" => opts["family"],
          "file" => clip_rel,
          "still" => still_rel,
          "start" => seg[:start],
          "scene" => "#{opts['id']}:#{seg[:scene]}",
          "duration" => clip_duration.round(3),
          "width" => width,
          "height" => height,
          "tags" => opts["tags"],
          "luma" => stats[:luma].round(1),
          "saturation" => stats[:saturation].round(1),
          "warmth" => stats[:warmth].round(1),
          "motion" => stats[:motion].round(4)
        }
      end

      def measure(clip_path)
        vf = "fps=6,scale=192:-2,signalstats,select='gte(scene,0)',metadata=print:file=-"
        stdout, = ffmpeg("-i", clip_path, "-vf", vf, "-an", "-f", "null", "-")
        values = Hash.new { |h, k| h[k] = [] }
        stdout.scan(/lavfi\.(signalstats\.\w+|scene_score)=([\d.]+)/) { |k, v| values[k] << v.to_f }
        avg = ->(k) { (v = values[k]).empty? ? 0.0 : v.sum / v.size }
        {
          luma: avg.("signalstats.YAVG"),
          range: avg.("signalstats.YHIGH") - avg.("signalstats.YLOW"),
          saturation: avg.("signalstats.SATAVG"),
          warmth: avg.("signalstats.VAVG") - avg.("signalstats.UAVG"),
          motion: values["scene_score"].drop(1).then { |v| v.empty? ? 0.0 : v.sum / v.size }
        }
      end

      def probe_duration(path)
        out, = Open3.capture2("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path)
        out.to_f
      end

      def probe_size(path)
        out, = Open3.capture2("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", path)
        out.strip.split(",").map(&:to_i)
      end

      def ffmpeg(*args)
        Open3.capture3("ffmpeg", "-hide_banner", "-nostats", "-loglevel", "error", *args)
      end
    end
  end
end
