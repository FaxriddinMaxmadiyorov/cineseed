require "open3"
require "fileutils"

module Trailer
  # Renders a Director::Plan with ffmpeg: every footage shot is retimed, reframed (sub-pixel zoom/pan
  # through `perspective`), color graded and grained, letterboxed; shots and black cards are joined
  # with `xfade` transitions; libass draws the typography; the music excerpt is ducked under the
  # title hit and mixed with the sound effects.
  class Renderer
    FPS = 24
    W = Director::W
    H = Director::H
    VIGNETTE = Rails.root.join("vendor", "trailer", "vignette_854x480.png").to_s

    class Error < StandardError; end

    def initialize(plan)
      @plan = plan
    end

    def render(output, ass_path:, fonts_dir: Config::FONTS_DIR.to_s)
      File.write(ass_path, @plan.ass)
      run(command(output, ass_path, fonts_dir: fonts_dir))
    end

    def command(output, ass_path, fonts_dir: Config::FONTS_DIR.to_s)
      inputs = []
      graph = []
      labels = []

      @plan.segments.each_with_index do |segment, i|
        # a few spare frames: xfade stops when its first input ends before the transition does
        length = (segment.duration + segment.transition_length.to_f + 0.12).round(3)
        label = "s#{i}"
        if segment.kind == :shot
          inputs << input(segment.shot, length)
          graph << shot_chain(inputs.size - 1, segment.shot, length, label, active_height: @plan.active_height)
        elsif segment.kind == :title && @plan.hero.treatment != "black"
          inputs << input(@plan.hero, length)
          graph << hero_chain(inputs.size - 1, @plan.hero, length, label)
        else
          graph << "color=c=black:s=#{W}x#{H}:r=#{FPS}:d=#{length},format=yuv420p,setsar=1[#{label}]"
        end
        labels << label
      end

      current = labels.first
      @plan.segments.each_cons(2).with_index do |(a, b), i|
        out = "x#{i + 1}"
        graph << "[#{current}][#{labels[i + 1]}]xfade=transition=#{xfade_name(a.transition)}:duration=#{[a.transition_length, 0.042].max}:offset=#{b.start}[#{out}]"
        current = out
      end

      vignette_index = inputs.size
      inputs << ["-i", VIGNETTE]
      graph << "[#{current}][#{vignette_index}:v]overlay=0:0,ass=filename=#{escape(ass_path)}:fontsdir=#{escape(fonts_dir)},format=yuv420p[vout]"

      audio_graph(inputs, graph)

      [*Studio::NICE, "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y", *inputs.flatten,
        "-filter_complex", graph.join(";"), "-map", "[vout]", "-map", "[aout]",
        "-t", @plan.duration.round(3).to_s, "-r", FPS.to_s,
        "-c:v", "libx264", "-preset", ENV.fetch("TRAILER_X264_PRESET", "veryfast"), "-crf", "23", "-pix_fmt", "yuv420p",
        "-profile:v", "high", "-movflags", "+faststart", "-c:a", "aac", "-b:a", "128k", "-ar", "44100", output]
    end

    private

    def input(shot, length)
      source = (length * shot.speed + 0.15).round(3)
      ["-ss", shot.in_point.to_s, "-t", source.to_s, "-i", shot.clip.path]
    end

    def shot_chain(index, shot, length, label, active_height:)
      pad_y = ((H - active_height) / 2).floor
      [
        "[#{index}:v]setpts=(PTS-STARTPTS)/#{shot.speed}",
        "fps=#{FPS}",
        cover(shot.clip, W, active_height),
        reframe(shot, W, active_height, length),
        (shot.hflip ? "hflip" : nil),
        *@plan.grade[:filters],
        "noise=c0s=#{grain}:allf=t",
        (pad_y.positive? ? "pad=#{W}:#{H}:0:#{pad_y}:black" : nil),
        "setsar=1,format=yuv420p",
        # clips that end early hold their last frame instead of shortening the cut
        "tpad=stop_mode=clone:stop_duration=2",
        "trim=duration=#{length},setpts=PTS-STARTPTS[#{label}]"
      ].compact.join(",")
    end

    def hero_chain(index, shot, length, label)
      darken = @plan.hero_darkness
      dim = if shot.treatment == "blur"
        "gblur=sigma=2.5,eq=brightness=#{-(darken + 0.03).round(3)}:saturation=0.75"
      else
        "eq=brightness=#{-(darken + 0.04).round(3)}:saturation=0.8:contrast=1.05"
      end
      [
        "[#{index}:v]setpts=(PTS-STARTPTS)/#{shot.speed}",
        "fps=#{FPS}",
        cover(shot.clip, W, H),
        reframe(shot.dup.tap { |s| s.zoom_from = 1.0; s.zoom_to = 1.07; s.pan_x = 0.0 }, W, H, length),
        *@plan.grade[:filters],
        dim,
        "setsar=1,format=yuv420p",
        "tpad=stop_mode=clone:stop_duration=2",
        "trim=duration=#{length},setpts=PTS-STARTPTS[#{label}]"
      ].join(",")
    end

    # Scale so the clip covers width x height, then crop the center.
    def cover(clip, width, height)
      if clip.aspect > width.to_f / height
        "scale=-2:#{height}:flags=bicubic,crop=#{width}:#{height}"
      else
        "scale=#{width}:-2:flags=bicubic,crop=#{width}:#{height}"
      end
    end

    # Sub-pixel push/pull/drift: `perspective` samples a shrinking (or moving) source window.
    def reframe(shot, width, height, length)
      return nil if shot.zoom_from == 1.0 && shot.zoom_to == 1.0 && shot.pan_x.zero?

      frames = [(length * FPS).round, 1].max
      p = "min(on/#{frames},1)"
      z = "(#{shot.zoom_from}+#{(shot.zoom_to - shot.zoom_from).round(4)}*#{p})"
      cx = "(#{width / 2.0}+#{(shot.pan_x * width).round(2)}*#{p})"
      cy = (height / 2.0).to_s
      hw = "(#{width / 2.0}/#{z})"
      hh = "(#{height / 2.0}/#{z})"
      x_left = "#{cx}-#{hw}"
      x_right = "#{cx}+#{hw}"
      y_top = "#{cy}-#{hh}"
      y_bottom = "#{cy}+#{hh}"
      "perspective=x0='#{x_left}':y0='#{y_top}':x1='#{x_right}':y1='#{y_top}':x2='#{x_left}':y2='#{y_bottom}':x3='#{x_right}':y3='#{y_bottom}':eval=frame"
    end

    def grain = @plan.grade[:name] == "noir" || @plan.grade[:name] == "sepia" ? 11 : 7

    def xfade_name(kind)
      case kind
      when "cut", "dissolve", nil then "fade"
      else kind
      end
    end

    def audio_graph(inputs, graph)
      total = @plan.duration.round(3)
      music_index = inputs.size
      inputs << ["-i", @plan.music.path]
      duck = @plan.music_volume[:duck_at]
      volume = duck ? "volume='if(lt(t,#{duck}),1,max(0,1-(t-#{duck})/0.2))':eval=frame" : "volume=1"
      fade_out = duck ? "" : ",afade=t=out:st=#{[total - 0.9, 0].max}:d=0.9"
      graph << "[#{music_index}:a]atrim=0:#{total + 0.2},asetpts=PTS-STARTPTS,afade=t=in:d=0.2,#{volume}#{fade_out},aformat=sample_rates=44100:channel_layouts=stereo[mus]"
      mix = ["[mus]"]
      @plan.effects.each_with_index do |cue, i|
        index = inputs.size
        inputs << ["-i", cue.path]
        timing = if cue.at.negative?
          "atrim=start=#{(-cue.at).round(3)},asetpts=PTS-STARTPTS"
        else
          ms = (cue.at * 1000).round
          "adelay=#{ms}|#{ms}"
        end
        graph << "[#{index}:a]aformat=sample_rates=44100:channel_layouts=stereo,#{timing},volume=#{cue.gain}[c#{i}]"
        mix << "[c#{i}]"
      end
      graph << "#{mix.join}amix=inputs=#{mix.size}:duration=longest:normalize=0,atrim=0:#{total},afade=t=out:st=#{[total - 0.5, 0].max}:d=0.5,alimiter=limit=0.93:level=false[aout]"
    end

    # ffmpeg filter argument escaping (for paths inside the graph).
    def escape(path) = path.gsub("\\", "\\\\\\\\").gsub(":", "\\\\:").gsub("'", "\\\\'")

    def run(cmd)
      _out, err, status = Open3.capture3(*cmd)
      raise Error, "ffmpeg failed: #{err.lines.last(5).join}" unless status.success?

      true
    end
  end
end
