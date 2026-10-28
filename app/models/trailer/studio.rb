require "open3"
require "fileutils"
require "tmpdir"

module Trailer
  # Front door for trailers and posters: plans, renders and caches them on disk.
  #
  # Rendering is deterministic, so a file rendered once is reused forever (it is a cache, not
  # storage: deleting tmp/trailers only costs a re-render). A file lock prevents two requests from
  # rendering the same trailer twice and semaphores cap the number of concurrent ffmpeg processes.
  module Studio
    VERSION = "v3"
    ROOT = Rails.root.join("tmp", "trailers", VERSION)
    MAX_FILES = Integer(ENV.fetch("TRAILER_CACHE_FILES", 3000))
    RENDERS = Concurrent::Semaphore.new(Integer(ENV.fetch("TRAILER_CONCURRENCY", 2)))
    POSTERS = Concurrent::Semaphore.new(Integer(ENV.fetch("POSTER_CONCURRENCY", 3)))
    WARMERS = Concurrent::ThreadPoolExecutor.new(min_threads: 0, max_threads: 2, max_queue: 40, fallback_policy: :discard)

    module_function

    def trailer(movie)
      cached(movie, "mp4") do |tmp, workdir|
        RENDERS.acquire
        begin
          plan = Director.plan(movie)
          Renderer.new(plan).render(tmp, ass_path: File.join(workdir, "trailer.ass"), fonts_dir: fonts_for(plan.ass, workdir))
        ensure
          RENDERS.release
        end
      end
    end

    def poster(movie)
      cached(movie, "jpg") do |tmp, workdir|
        POSTERS.acquire
        begin
          plan = Director.plan(movie)
          render_poster(plan, tmp, File.join(workdir, "poster.ass"), fonts_for(plan.poster_ass, workdir))
        ensure
          POSTERS.release
        end
      end
    end

    # libass reads every font in its fonts directory, so each render gets a directory with links to
    # just the fonts its script uses.
    def fonts_for(ass, workdir)
      dir = File.join(workdir, "fonts")
      FileUtils.mkdir_p(dir)
      families = ass.scan(/^Style: [^,]+,([^,]+),/).flatten.uniq
      Config.fonts.each_value do |font|
        next unless families.include?(font["family"])

        link = File.join(dir, font["file"])
        File.symlink(Config::FONTS_DIR.join(font["file"]).to_s, link) unless File.exist?(link)
      end
      dir
    end

    # ffmpeg runs with a lower CPU priority so that page requests stay quick while videos render.
    NICE = File.executable?("/usr/bin/nice") || File.executable?("/bin/nice") ? %w[nice -n 10] : [].freeze

    def ffmpeg(*args) = [*NICE, "ffmpeg", *args]

    # Starts rendering in the background, e.g. when a table row opens, so that the video is usually
    # ready by the time someone presses play. A request for the same trailer simply waits on the lock.
    def warm(movie)
      return false if path_for(movie, "mp4").exist?

      WARMERS.post do
        Rails.application.executor.wrap { trailer(movie) }
      rescue StandardError => e
        Rails.logger.warn("trailer warm-up failed for #{movie.key}: #{e.message}")
      end
      true
    end

    def path_for(movie, ext) = ROOT.join(movie.region.code, movie.seed.to_s, "#{movie.index}.#{ext}")

    def cached(movie, ext)
      path = path_for(movie, ext)
      return path if path.exist?

      FileUtils.mkdir_p(path.dirname)
      File.open("#{path}.lock", File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        return path if path.exist?

        Dir.mktmpdir("trailer", path.dirname) do |workdir|
          tmp = File.join(workdir, "out.#{ext}")
          yield tmp, workdir
          File.rename(tmp, path)
        end
      end
      prune if rand < 0.02
      path
    end

    # Freeze frame: the hero shot of the trailer, graded like the trailer, with the title card
    # typography rendered on top.
    def render_poster(plan, output, ass_path, fonts_dir)
      File.write(ass_path, plan.poster_ass)
      shot = plan.hero
      at = (shot.in_point + 0.6).round(3)
      vignette = Renderer::VIGNETTE
      graph = [
        "[0:v]#{cover(shot.clip)}",
        *plan.grade[:filters],
        "eq=brightness=#{-(plan.hero_darkness * 0.65).round(3)}:saturation=0.9",
        "setsar=1[bg]",
        "[bg][1:v]overlay=0:0,ass=filename=#{escape(ass_path)}:fontsdir=#{escape(fonts_dir)}[out]"
      ]
      graph = "#{graph[0..-2].join(',')};#{graph.last}"
      cmd = ffmpeg("-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", at.to_s, "-i", shot.clip.path, "-i", vignette,
        "-filter_complex", graph, "-map", "[out]", "-frames:v", "1", "-q:v", "3", output)
      _out, err, status = Open3.capture3(*cmd)
      raise Renderer::Error, "poster failed: #{err.lines.last(3).join}" unless status.success?
    end

    def cover(clip)
      clip.aspect > Director::W.to_f / Director::H ? "scale=-2:#{Director::H},crop=#{Director::W}:#{Director::H}" : "scale=#{Director::W}:-2,crop=#{Director::W}:#{Director::H}"
    end

    def escape(path) = path.gsub("\\", "\\\\\\\\").gsub(":", "\\\\:").gsub("'", "\\\\'")

    # Keeps the cache bounded: oldest files go first.
    def prune
      files = Dir[ROOT.join("**", "*.{mp4,jpg}")]
      return if files.size <= MAX_FILES

      files.sort_by { |f| File.mtime(f) }.first(files.size - MAX_FILES).each { |f| FileUtils.rm_f(f) }
    rescue SystemCallError
      nil
    end
  end
end
