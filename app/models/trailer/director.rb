module Trailer
  # Turns a Movie into an edit decision list: which real footage shots to use and for how long,
  # in which order, with which transitions, grade, typography, music cue and sound effects.
  #
  # All decisions come from the movie's trailer seed, so the same seed always produces the same cut.
  # The cut follows the music: shot lengths are counted in beats of the chosen excerpt and the title
  # lands on a downbeat, where the hit sound effect is placed.
  class Director
    W = Typography::W
    H = Typography::H
    ASPECT_HEIGHTS = { "scope" => 358, "flat" => 462, "full" => 480 }.freeze
    TRANSITION_LENGTHS = {
      "cut" => [0.042, 0.042], "dissolve" => [0.35, 0.6], "fadeblack" => [0.3, 0.5], "fadewhite" => [0.12, 0.22],
      "hblur" => [0.2, 0.3], "slideleft" => [0.25, 0.35], "circleopen" => [0.35, 0.5], "pixelize" => [0.25, 0.35],
      "zoomin" => [0.25, 0.35], "radial" => [0.35, 0.5], "wipeleft" => [0.3, 0.4]
    }.freeze
    LOGO_FONTS = %w[playfair cinzel oswald montserrat_black tenor forum cormorant_sc spectral_sc].freeze

    Shot = Struct.new(:clip, :in_point, :speed, :zoom_from, :zoom_to, :pan_x, :pan_y, :hflip, :treatment, keyword_init: true)
    Segment = Struct.new(:kind, :duration, :shot, :text, :transition, :transition_length, :start, keyword_init: true) do
      def finish = start + duration
    end
    Cue = Struct.new(:path, :at, :gain, :offset, :length, keyword_init: true)
    Plan = Struct.new(:movie, :segments, :duration, :aspect, :active_height, :grade, :music, :music_volume, :effects,
      :ass, :poster_ass, :hero, :hero_darkness, :title_font, :palette, keyword_init: true)

    def self.plan(movie) = new(movie).plan

    def initialize(movie, footage: Footage::Library.instance, audio: Audio::Library.instance)
      @movie = movie
      @footage = footage
      @audio = audio
      @rng = Random.new(movie.trailer_seed)
      @profile = Config.genre(movie.genre)
    end

    def plan
      @family = pick_family
      @pool = @footage.scored(family: @family, rules: @profile["clips"] || {}, genre: @movie.genre)
      @music = Weighted.pick(@audio.music_for(@profile["music"]), @rng)
      @beats = beat_grid(@music)
      @aspect = Weighted.pick(@profile["aspect"], @rng)
      @grade = build_grade
      @copy = @movie.region.with_faker(@rng) { Faker::MovieStore.trailer_copy.deep_dup.merge(crew: crew) }
      @typo = Typography.new(script: @movie.region.script)
      @title_font = pick_font(@profile["title_fonts"])
      @card_font = pick_font(@profile["card_fonts"])
      @palette = @profile["palette"]

      segments = layout_segments(storyboard(Weighted.pick(@profile["structures"], @rng)))
      assign_shots(segments)
      assign_transitions(segments)
      time_segments(segments)
      typeset(segments)
      effects, volume = sound_design(segments)

      Plan.new(movie: @movie, segments: segments, duration: segments.last.finish, aspect: @aspect,
        active_height: ASPECT_HEIGHTS.fetch(@aspect), grade: @grade, music: @music, music_volume: volume,
        effects: effects, ass: @typo.to_ass, poster_ass: poster_ass(segments), hero: @hero,
        hero_darkness: @profile["hero_darkness"].to_f, title_font: @title_font, palette: @palette)
    end

    private

    # --- choices -----------------------------------------------------------------------------------

    def pick_family
      options = @profile["families"].select { |f, _| @footage.family(f).size >= 6 }
      Weighted.pick(options.presence || { @footage.families.max_by { |f| @footage.family(f).size } => 1 }, @rng)
    end

    def pick_font(weights)
      usable = weights.select { |key, _| @typo.fits_script?(key) }
      usable = { "oswald" => 1 } if usable.empty?
      Weighted.pick(usable, @rng)
    end

    def build_grade
      weights = @family == "archival" ? Config.family_grades["archival"] : @profile["grades"]
      name = Weighted.pick(weights, @rng)
      grade = Config.grades.fetch(name)
      values = grade["params"].to_h { |k, (min, max)| [k, (min + @rng.rand * (max - min)).round(3)] }
      { name: name, filters: grade["filters"].map { |f| f.gsub(/\{(\w+)\}/) { values.fetch(Regexp.last_match(1)) } } }
    end

    def crew
      { music: Faker::MovieStore.person, editor: Faker::MovieStore.person, photography: Faker::MovieStore.person,
        producers: Array.new(2) { Faker::MovieStore.person }, writer: Faker::MovieStore.person, company: Faker::MovieStore.company }
    end

    # Usable beat times of the excerpt (every other beat when the tempo is fast).
    def beat_grid(music)
      beats = music.beats
      beats = beats.each_slice(2).map(&:first) if music.bpm > 150
      unit = beats.each_cons(2).map { |a, b| b - a }.then { |d| d.empty? ? music.unit : d.sum / d.size }
      unit = unit.clamp(0.4, 1.0)
      beats += Array.new(30) { |i| beats.last + unit * (i + 1) }
      { times: beats, unit: unit, downbeats: music.downbeats }
    end

    # --- structure -----------------------------------------------------------------------------------

    def storyboard(structure)
      hooks = Array(@copy.dig(:hooks, @movie.genre.to_sym)).sample(random: @rng) || []
      opener = @movie.series? ? season_card : (@copy[:when].sample(random: @rng) if @rng.rand < 0.55)
      board = []
      board << { kind: :ident } if @rng.rand < 0.3 && structure != "cold_open"
      case structure
      when "hooks"
        hooks.each_with_index do |line, i|
          board << { kind: :card, text: line }
          board << { kind: :shot }
          board << { kind: :shot } if i.zero? || @rng.rand < 0.4
        end
        board << { kind: :shot }
      when "cold_open"
        board << { kind: :shot, caption: from_line }
        board << { kind: :shot }
        board << { kind: :shot }
        board << { kind: :card, text: opener || hooks.first }
        board << { kind: :shot }
        board << { kind: :shot, fast: true }
      when "stars"
        stars = @movie.actors.first(2)
        board << { kind: :shot }
        board << { kind: :card, text: stars[0], star: true }
        board << { kind: :shot }
        board << { kind: :card, text: "#{@copy[:and_prefix]}#{stars[1]}", star: true } if stars[1]
        board << { kind: :shot }
        board << { kind: :shot, fast: true }
      when "montage"
        board << { kind: :card, text: opener } if opener
        5.times { board << { kind: :shot, fast: true } }
      when "teaser"
        board << { kind: :shot, long: true }
        board << { kind: :shot, long: true }
        board << { kind: :card, text: hooks.last || opener || from_line }
        board << { kind: :shot, long: true }
      else # classic
        board << { kind: :shot } if @rng.rand < 0.4
        board << { kind: :card, text: opener || from_line }
        board << { kind: :shot }
        board << { kind: :shot }
        board << { kind: :card, text: hooks.first || from_line }
        board << { kind: :shot }
        board << { kind: :shot, fast: true }
      end
      board << { kind: :title }
      board
    end

    def season_card
      season = @movie.seasons.size
      list = season > 1 ? @copy[:season] : @copy[:season_first]
      text = list.sample(random: @rng)
      text.gsub("{n}", season.to_s)
    end

    def from_line
      template = (@movie.series? ? @copy[:series_from] : @copy[:from]).sample(random: @rng)
      Faker::MovieStore.interpolate(template, other_title: @movie.other_title, studio: @movie.studio, director: @movie.director, platform: @movie.platform)
    end

    # Durations in beats, then fitted so the whole trailer lasts 7-9.5 seconds (the task asks for
    # 5-10 s). The budget is counted on the excerpt's real beat grid, so it is exact.
    MAX_LENGTH = 9.4
    MIN_LENGTH = 7.2
    FLOORS = { shot: 0.6, card: 0.85, ident: 0.9, title: 2.5 }.freeze
    TEXT_SHARE = 0.4 # text cards on black never take more than this share of the cut before the title

    def layout_segments(board)
      unit = @beats[:unit]
      pace = @profile["pace"]
      segments = board.map do |item|
        beats = case item[:kind]
        when :ident then (1.8 / unit).round.clamp(2, 4)
        when :card then (1.15 / unit).round.clamp(2, 3)
        when :title then (3.0 / unit).round.clamp(3, 7)
        else
          if item[:fast] then [pace[0], 1].max
          elsif item[:long] then pace[1] + 1
          else @rng.rand(pace[0]..pace[1])
          end
        end
        beats = [beats, floor(item[:kind])].max
        beats -= 1 while beats > floor(item[:kind]) && beats * unit > (item[:kind] == :title ? 3.6 : 2.6)
        Segment.new(kind: item[:kind], duration: beats, text: item[:text] || item[:caption], shot: item[:star] ? :star : item[:caption] ? :caption : nil)
      end
      budget = beat_budget(MAX_LENGTH)
      fit_to_budget(segments, budget)
      limit_text(segments)
      while seconds_for(segments.sum(&:duration)) < MIN_LENGTH
        room = budget - segments.sum(&:duration)
        beats = [[pace[0], floor(:shot)].max, room].min
        break if beats < floor(:shot)

        segments.insert(segments.size - 1, Segment.new(kind: :shot, duration: beats))
      end
      segments
    end

    def seconds_for(beats) = @beats[:times][beats] - @beats[:times][0]
    def beat_budget(seconds) = @beats[:times].each_index.select { |n| seconds_for(n) <= seconds }.max
    def floor(kind) = (FLOORS.fetch(kind) / @beats[:unit] - 0.15).ceil.clamp(1, 99)

    # Shortens the longest pieces first and only drops whole segments when nothing else is left.
    def fit_to_budget(segments, budget)
      while segments.sum(&:duration) > budget
        shots = segments.select { |s| s.kind == :shot }
        long_shot = shots.select { |s| s.duration > [floor(:shot), 2].max }.max_by(&:duration)
        card = segments.select { |s| %i[card ident].include?(s.kind) && s.duration > floor(s.kind) }.max_by(&:duration)
        title = segments.last.duration > floor(:title) ? segments.last : nil
        short_shot = shots.select { |s| s.duration > floor(:shot) }.max_by(&:duration)
        if long_shot then long_shot.duration -= 1
        elsif card then card.duration -= 1
        elsif title then title.duration -= 1
        elsif short_shot then short_shot.duration -= 1
        elsif (i = segments.index { |s| s.kind == :ident }) then segments.delete_at(i)
        elsif shots.size > 3 && (i = removable(segments, :shot)) then segments.delete_at(i)
        elsif (i = removable(segments, :card)) then segments.delete_at(i)
        elsif (i = removable(segments, :shot)) then segments.delete_at(i)
        else break
        end
      end
    end

    def limit_text(segments)
      loop do
        body = segments[0...-1]
        text = body.reject { |s| s.kind == :shot }.sum(&:duration)
        break if text <= TEXT_SHARE * body.sum(&:duration)

        i = removable(segments, :card) || segments.index { |s| s.kind == :ident }
        break unless i

        segments.delete_at(i)
      end
    end

    # A segment that can go without leaving two text cards (or a card and the title) side by side.
    def removable(segments, kind)
      candidates = segments.each_index.select do |i|
        next false unless segments[i].kind == kind && i < segments.size - 1
        next false if kind == :shot && segments.count { |s| s.kind == :shot } <= 2

        before = i.positive? ? segments[i - 1] : nil
        after = segments[i + 1]
        before.nil? || before.kind == :shot || after.kind == :shot
      end
      candidates.reject { |i| segments[i].shot == :caption }.last || candidates.last
    end

    # --- footage -------------------------------------------------------------------------------------

    def assign_shots(segments)
      used_scenes = []
      used_sources = []
      speeds = @profile["speed"]
      shot_segments = segments.select { |s| s.kind == :shot }
      shot_segments.each do |segment|
        length = segment.duration * @beats[:unit] + 0.75
        candidates = @pool.reject { |clip, _| used_scenes.include?(clip.scene) }
        candidates = @pool if candidates.empty?
        candidates = candidates.map { |clip, w| [clip, used_sources.include?(clip.source) ? w * 0.4 : w] }
        clip = Weighted.pick(candidates, @rng)
        used_scenes << clip.scene
        used_sources << clip.source
        speed = (speeds[0] + @rng.rand * (speeds[1] - speeds[0])).round(3)
        speed = [speed, (clip.duration - 0.05) / length].min.round(3)
        speed = 0.5 if speed < 0.5
        caption = segment.shot == :caption
        segment.text = segment.text if caption
        segment.shot = build_shot(clip, speed, length)
        segment.kind = :shot
        segment[:text] = caption ? segment.text : nil
      end
      @hero = pick_hero(shot_segments)
    end

    def build_shot(clip, speed, length, treatment: nil)
      needed = [length * speed, clip.duration].min
      in_point = ((clip.duration - needed) * @rng.rand).round(3)
      zoom = Weighted.pick(@profile["zoom"], @rng)
      from, to = case zoom
      when "push" then [1.0, 1.05 + @rng.rand * 0.07]
      when "pull" then [1.07 + @rng.rand * 0.07, 1.0]
      when "drift" then [1.08, 1.08]
      else [1.0, 1.0]
      end
      pan = zoom == "drift" ? (0.025 + @rng.rand * 0.025) * (@rng.rand < 0.5 ? -1 : 1) : 0.0
      Shot.new(clip: clip, in_point: in_point, speed: speed, zoom_from: from.round(3), zoom_to: to.round(3),
        pan_x: pan.round(3), pan_y: 0.0, hflip: @rng.rand < 0.25, treatment: treatment)
    end

    # The title card sits on black or on a blurred / dimmed hero shot; posters use the same frame.
    def pick_hero(shot_segments)
      bright = @pool.select { |c, _| c.luma.between?(55, 200) }
      clip = Weighted.pick(bright.presence || @pool, @rng)
      treatment = Weighted.pick({ "black" => 5, "blur" => 4, "dim" => 2 }, @rng)
      build_shot(clip, 0.85, 4.0, treatment: treatment)
    end

    # --- transitions & timing --------------------------------------------------------------------

    def assign_transitions(segments)
      segments.each_cons(2) do |a, b|
        kind = if b.kind == :title
          Weighted.pick({ "cut" => 3, "fadeblack" => 3, "fadewhite" => 1, "dissolve" => 1 }, @rng)
        elsif a.kind == :card || b.kind == :card || a.kind == :ident
          Weighted.pick({ "cut" => 3, "fadeblack" => 2, "dissolve" => 1 }, @rng)
        else
          Weighted.pick(@profile["transitions"], @rng)
        end
        min, max = TRANSITION_LENGTHS.fetch(kind)
        a.transition = kind
        a.transition_length = (min + @rng.rand * (max - min)).round(3)
      end
      segments.last.transition = nil
      segments.last.transition_length = 0.0
    end

    # Beat counts become times on the excerpt's real beat grid; the title moves to a downbeat.
    def time_segments(segments)
      times = @beats[:times]
      index = 0
      segments.each do |segment|
        start = times[index] - times[0]
        index += segment.duration
        segment.start = start.round(3)
        segment.duration = (times[index] - times[0] - start).round(3)
      end
      title = segments.last
      downbeat = @beats[:downbeats].map { |d| d - times[0] }.select { |d| (d - title.start).between?(-0.9, 0.9) && d > 5.5 }.min_by { |d| (d - title.start).abs }
      if downbeat && segments.size > 1
        shift = (downbeat - title.start).round(3)
        before = segments[-2]
        if before.duration + shift > 0.55 && title.finish + shift <= 9.9
          before.duration = (before.duration + shift).round(3)
          title.start = (title.start + shift).round(3)
        end
      end
      title.duration = [title.duration, 2.4].max.round(3)
      title.duration = (9.95 - title.start).round(3) if title.finish > 9.95
      segments.each_cons(2) do |a, b|
        limit = ([a.duration, b.duration].min * 0.45).round(3)
        a.transition_length = [a.transition_length, limit].min
      end
    end

    # --- typography ----------------------------------------------------------------------------------

    def typeset(segments)
      segments.each_with_index do |segment, i|
        lead = i.positive? ? segments[i - 1].transition_length / 2 : 0
        from = segment.start + lead
        to = segment.finish + segment.transition_length * 0.4
        case segment.kind
        when :ident then ident(from, to)
        when :card then card(segment.text, from, to, star: segment.shot == :star)
        when :title then title(from, segment.finish)
        when :shot then caption(segment.text, from + 0.2, to) if segment.text
        end
      end
    end

    def ident(from, to)
      template = @copy.dig(:billing, :presents).to_s
      before, after = template.split("{studio}", 2)
      font = pick_font(LOGO_FONTS.to_h { |f| [f, 1] })
      name = @typo.prepare(font, @movie.studio)
      layout = @typo.layout(font, name, max_width: 560, max_size: 40, min_size: 20)
      style = @typo.style(font, size: layout.size, color: "EDEDED", spacing: 2)
      text = layout.lines.join("\\N")
      @typo.fx(%w[shine tracking blur_focus].sample(random: @rng), start: from, finish: to, style: style, text: text, x: W / 2, y: H / 2 - 8, layout: layout, random: @rng, colors: { flash: "FFFFFF" })
      word = Typography.clean("#{before} #{after}").upcase
      return if word.empty?

      small = @typo.style(@card_font, size: 13, color: "BDBDBD", spacing: 5)
      @typo.fx("fade_up", start: from + 0.35, finish: to, style: small, text: word, x: W / 2, y: H / 2 + layout.height / 2 + 14, layout: layout, random: @rng)
    end

    def card(text, from, to, star: false)
      return if text.blank?

      content = @typo.prepare(@card_font, text).upcase
      spacing = star ? 6 : 3
      layout = @typo.layout(@card_font, content, max_width: 720, max_size: star ? 56 : 62, min_size: 30, spacing: spacing)
      style = @typo.style(@card_font, size: layout.size, color: @palette["title"], spacing: spacing)
      fx = star ? "tracking" : Weighted.pick(@profile["card_fx"], @rng)
      @typo.fx(fx, start: from, finish: to, style: style, text: layout.lines.join("\\N"), x: W / 2, y: H / 2, layout: layout, random: @rng, colors: palette_colors)
    end

    def caption(text, from, to)
      content = @typo.prepare(@card_font, text).upcase
      layout = @typo.layout(@card_font, content, max_width: 640, max_size: 22, min_size: 14)
      style = @typo.style(@card_font, size: layout.size, color: "F2F2F2", outline_color: "000000", shadow: 1, spacing: 3)
      y = (H / 2 + ASPECT_HEIGHTS.fetch(@aspect) / 2 - 34).round
      @typo.fx("fade_up", start: from, finish: to, style: style, text: layout.lines.join("\\N"), x: W / 2, y: y, layout: layout, random: @rng)
    end

    def title(from, to)
      @title_layout = title_layout
      text = @title_layout.lines.join("\\N")
      fx = Weighted.pick(@profile["title_fx"], @rng)
      @title_fx = fx
      @typo.fx(fx, start: from, finish: to, style: @title_style, text: text, x: W / 2, y: title_y, layout: @title_layout, random: @rng, colors: palette_colors)
      glow = @typo.style(@title_font, size: @title_layout.size, color: @palette["glow"], outline_color: @palette["glow"], outline: 3)
      @typo.event(from + 0.25, to, glow, "{\\an5\\pos(#{W / 2},#{title_y})\\blur14\\alpha&HFF&\\t(150,900,\\alpha&HA8&)\\t(#{((to - from) * 1000 - 260).round},#{((to - from) * 1000).round},\\alpha&HFF&)}#{text}", layer: 0)
      release(from + 0.7, to)
      billing(from + 0.9, to)
      rating_badge(from + 1.1, to) unless @movie.series?
    end

    def title_layout
      name = @typo.prepare(@title_font, @movie.title)
      layout = @typo.layout(@title_font, name, max_width: 720, max_size: 86, min_size: 44, two_line_size: 62)
      @title_style = @typo.style(@title_font, size: layout.size, color: @palette["title"], outline_color: "000000", shadow: 0)
      layout
    end

    def title_y = (H / 2 - 30).round

    def release(from, to)
      line = release_text
      content = @typo.prepare(@card_font, line).upcase
      layout = @typo.layout(@card_font, content, max_width: 600, max_size: 25, min_size: 15)
      style = @typo.style(@card_font, size: layout.size, color: readable(@palette["accent"]), spacing: 4)
      y = (title_y + @title_layout.height / 2 + 28).round
      @typo.fx("tracking", start: from, finish: to, style: style, text: layout.lines.join("\\N"), x: W / 2, y: y, layout: layout, random: @rng)
    end

    def release_text
      list = @movie.series? ? @copy[:series_release] : @copy[:release]
      date = Faker::MovieStore.interpolate(@copy[:date], day: @movie.release_day, month: @copy[:months][@movie.release_month - 1],
        month_gen: Array(@copy[:months_gen]).presence&.at(@movie.release_month - 1) || @copy[:months][@movie.release_month - 1])
      Faker::MovieStore.interpolate(list.sample(random: @rng), date: date, platform: @movie.platform)
    end

    def billing(from, to)
      b = @copy[:billing]
      crew = @copy[:crew]
      cast = @movie.actors.join("  ")
      sub = ->(t) { Faker::MovieStore.interpolate(t, studio: @movie.studio, company: crew[:company], director: @movie.director) }
      words = [sub.(b[:presents]), sub.(b[:production]), sub.(b[:film_by]), "#{b[:starring]} #{cast}",
        "#{b[:music]} #{crew[:music]}", "#{b[:edited]} #{crew[:editor]}", "#{b[:photography]} #{crew[:photography]}",
        "#{b[:produced]} #{crew[:producers].join('  ')}", "#{b[:written]} #{crew[:writer]}", "#{b[:directed]} #{@movie.director}"]
      text = Typography.clean(words.join("   ")).upcase
      lines = wrap(text, "fira_xcond", 13, 0.8, 790)
      style = @typo.style("fira_xcond", size: 13, color: "CFCFCF", spacing: 0.6)
      body = lines.join("\\N")
      @typo.event(from, to, style, "{\\an2\\pos(#{W / 2},#{H - 14})\\fscx80\\alpha&HFF&\\t(0,500,\\alpha&H50&)\\t(#{((to - from) * 1000 - 220).round},#{((to - from) * 1000).round},\\alpha&HFF&)}#{body}", layer: 1)
    end

    def wrap(text, font, size, scale, width)
      lines = [+""]
      text.split("   ").each do |chunk|
        candidate = lines.last.empty? ? chunk : "#{lines.last}   #{chunk}"
        if @typo.text_width(font, candidate, size) * scale > width && !lines.last.empty?
          lines << chunk.dup
        else
          lines[-1] = candidate
        end
      end
      lines.first(4)
    end

    def rating_badge(from, to)
      code = @movie.rating.to_s
      style = @typo.style("oswald", size: 16, color: "E0E0E0", outline_color: "E0E0E0", outline: 1, box: false)
      @typo.event(from, to, style, "{\\an4\\pos(28,#{H - 70})\\bord1\\3c&HD0D0D0&\\alpha&HFF&\\t(0,400,\\alpha&H30&)\\t(#{((to - from) * 1000 - 220).round},#{((to - from) * 1000).round},\\alpha&HFF&)} #{Typography.clean(code)} ", layer: 1)
    end

    def palette_colors = { title: @palette["title"], glow: @palette["glow"], flash: @palette["accent"] }

    # Small text in a dark accent color (horror crimson) disappears on black: mix it toward white.
    def readable(hex)
      r, g, b = hex.scan(/../).map { |c| c.to_i(16) }
      return hex if 0.299 * r + 0.587 * g + 0.114 * b >= 140

      [r, g, b].map { |c| (c * 0.55 + 255 * 0.45).round.to_s(16).rjust(2, "0") }.join.upcase
    end

    # Static version of the final title card, rendered over the hero frame for the freeze frame.
    def poster_ass(_segments)
      typo = Typography.new(script: @movie.region.script)
      layout = @title_layout
      style = typo.style(@title_font, size: layout.size, color: @palette["title"], outline_color: "000000", shadow: 0)
      glow = typo.style(@title_font, size: layout.size, color: @palette["glow"], outline_color: @palette["glow"], outline: 3)
      text = layout.lines.join("\\N")
      typo.event(0, 5, glow, "{\\an5\\pos(#{W / 2},#{title_y})\\blur14\\alpha&HA8&}#{text}")
      typo.event(0, 5, style, "{\\an5\\pos(#{W / 2},#{title_y})\\blur0.6}#{text}", layer: 1)
      line = @typo.prepare(@card_font, Typography.clean(@movie.tagline)).then { |t| t.length > 60 ? t[0, 58] + "…" : t }
      tag_layout = typo.layout(@card_font, line, max_width: 660, max_size: 21, min_size: 13)
      tag = typo.style(@card_font, size: tag_layout.size, color: readable(@palette["accent"]), spacing: 2)
      typo.event(0, 5, tag, "{\\an5\\pos(#{W / 2},#{(title_y + layout.height / 2 + 26).round})\\alpha&H20&}#{tag_layout.lines.join('\\N')}", layer: 1)
      typo.to_ass
    end

    # --- sound -------------------------------------------------------------------------------------

    def sound_design(segments)
      title = segments.last
      cues = []
      intense = @profile["riser"]
      drop = intense && @rng.rand < 0.75
      if drop && (riser = @audio.effect("riser", @rng))
        cues << Cue.new(path: riser.path, at: (title.start - riser.peak_at).round(3), gain: 0.75)
      end
      hit_kind = Array(@profile["hit"]).sample(random: @rng)
      if (hit = @audio.effect(hit_kind, @rng) || @audio.effect("boom", @rng))
        cues << Cue.new(path: hit.path, at: (title.start - hit.peak_at).round(3), gain: hit_kind == "toon" ? 0.8 : 1.0)
      end
      segments.each_cons(2).with_index do |(a, b), i|
        next unless b.kind == :card || (a.transition && a.transition != "cut" && @rng.rand < 0.3)
        next unless @rng.rand < 0.6 && (whoosh = @audio.effect("whoosh", @rng))

        cues << Cue.new(path: whoosh.path, at: (b.start - 0.12 - whoosh.peak_at).round(3), gain: 0.45)
      end
      extras = @profile["extras"] || {}
      @rng.rand(1..2).times do
        break if extras.empty?

        kind = Weighted.pick(extras, @rng)
        next unless (fx = @audio.effect(kind, @rng))

        at = case kind
        when "wind" then 0.0
        when "heartbeat", "creak", "tick", "bell" then [segments.first.start + 0.1, 0].max
        else segments.select { |s| s.kind == :shot }.sample(random: @rng)&.start.to_f
        end
        gain = { "wind" => 0.35, "heartbeat" => 0.7, "tick" => 0.5, "bell" => 0.5 }.fetch(kind, 0.6)
        cues << Cue.new(path: fx.path, at: at.round(3), gain: gain)
      end
      cut = drop ? (title.start - 0.32).round(3) : nil
      [cues.reject { |c| c.at > title.finish }, { duck_at: cut, end_at: title.finish }]
    end
  end
end
