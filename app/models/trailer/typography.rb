module Trailer
  # Builds the Advanced SubStation (ASS) script that libass renders on top of the cut: animated
  # titles, tagline cards, star names and the billing block. Animations are ASS override tags
  # (\t transforms, \move, \clip, per-letter timing), so the typography is real text rendered by a
  # proper text engine with the region's fonts, not pixels drawn by hand.
  class Typography
    W = 854
    H = 480
    SPACE = 0.28 # width of a space relative to the font size

    Layout = Data.define(:lines, :size, :width, :height)

    def initialize(script:)
      @script = script.to_s
      @styles = {}
      @events = []
    end

    # --- document ----------------------------------------------------------------------------------

    def style(font_key, size:, color: "FFFFFF", outline_color: "000000", outline: 0, shadow: 0, spacing: 0, box: false)
      font = Config.font(font_key)
      name = "S#{@styles.size}"
      @styles[name] = [name, font["family"], size.round, ass_style_color(color), ass_style_color(color), ass_style_color(outline_color),
        "&H96000000", font["bold"] ? -1 : 0, 0, 0, 0, 100, 100, spacing.round(1), 0, box ? 3 : 1, outline, shadow, 5, 10, 10, 10, 1].join(",")
      name
    end

    def event(start, finish, style, text, layer: 0)
      @events << [layer, timestamp(start), timestamp(finish), style, text]
    end

    def to_ass
      header = <<~ASS
        [Script Info]
        ScriptType: v4.00+
        PlayResX: #{W}
        PlayResY: #{H}
        WrapStyle: 2
        ScaledBorderAndShadow: yes
        YCbCr Matrix: TV.601

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
      ASS
      styles = @styles.values.map { |s| "Style: #{s}" }.join("\n")
      events = @events.sort_by { |e| [e[1], e[0]] }.map { |layer, from, to, style, text| "Dialogue: #{layer},#{from},#{to},#{style},,0,0,0,,#{text}" }
      "#{header}#{styles}\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n#{events.join("\n")}\n"
    end

    # --- layout ------------------------------------------------------------------------------------

    def prepare(font_key, text)
      text = self.class.clean(text)
      Config.font(font_key)["case"] == "upper" ? text.upcase : text
    end

    # Characters with a meaning in ASS (override blocks, escapes) are replaced in user-facing text.
    def self.clean(text) = text.to_s.tr("{}\\", "()/").gsub(/\s+/, " ").strip

    # Font size and line breaks so the text fits max_width (two lines at most).
    def layout(font_key, text, max_width:, max_size:, min_size:, spacing: 0, two_line_size: nil)
      lines = [text]
      size = fit_size(font_key, lines, max_width, max_size, spacing)
      if size < min_size && text.include?(" ")
        lines = split_lines(text)
        size = fit_size(font_key, lines, max_width, two_line_size || max_size * 0.78, spacing)
      end
      size = [size, min_size * 0.75].max
      width = lines.map { |l| text_width(font_key, l, size, spacing) }.max
      cap = Config.font(font_key)["cap"].to_f.nonzero? || 0.7
      Layout.new(lines: lines, size: size.round, width: width, height: (lines.size * 1.15 * size + cap * size * 0.2))
    end

    def text_width(font_key, text, size, spacing = 0)
      font = Config.font(font_key)
      widths = font["width"]
      cyr = text.match?(/\p{Cyrillic}/)
      upper = text == text.upcase
      factor = widths["#{cyr ? 'cyrillic' : 'latin'}_#{upper ? 'upper' : 'mixed'}"] || widths["latin_#{upper ? 'upper' : 'mixed'}"] || widths.values.first
      chars = text.delete(" ").length
      spaces = text.count(" ")
      chars * factor * size + spaces * SPACE * size + [text.length - 1, 0].max * spacing
    end

    def fits_script?(font_key) = Array(Config.font(font_key)["scripts"]).include?(@script)

    # --- effects -----------------------------------------------------------------------------------
    # Every effect receives: start/finish (s), style name, text (\N separated lines), x/y anchor,
    # layout and the effect-specific random stream; it appends one or more events.

    def fx(name, start:, finish:, style:, text:, x:, y:, layout:, random:, colors: {})
      send(:"fx_#{name}", start, finish, style, text, x, y, layout, random, colors)
    end

    def fx_cut(start, finish, style, text, x, y, _layout, _random, _colors)
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})}#{text}")
    end

    def fx_tracking(start, finish, style, text, x, y, layout, random, _colors)
      dur = ms(finish - start)
      longest = text.split("\\N").map(&:length).max.to_i
      room = (W - 50 - layout.width) / [longest - 1, 1].max # the wide start must still fit the frame
      wide = [(layout.size * (0.25 + random.rand * 0.25)), room].min.clamp(0, 99).round(1)
      tight = (layout.size * 0.04).round(1)
      fade_in = [dur * 0.25, 450].min.round
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\fsp#{wide}\\alpha&HFF&\\blur6\\t(0,#{fade_in},\\alpha&H00&\\blur0)\\t(0,#{(dur * 0.85).round},0.45,\\fsp#{tight})#{fade_out(dur)}}#{text}")
    end

    def fx_fade_up(start, finish, style, text, x, y, _layout, _random, _colors)
      dur = ms(finish - start)
      event(start, finish, style, "{\\an5\\move(#{x},#{y + 16},#{x},#{y},0,#{[dur * 0.5, 600].min.round})\\alpha&HFF&\\t(0,#{[dur * 0.35, 420].min.round},\\alpha&H00&)#{fade_out(dur)}}#{text}")
    end

    def fx_slam(start, finish, style, text, x, y, _layout, random, colors)
      dur = ms(finish - start)
      zoom = 160 + random.rand(90)
      land = 140 + random.rand(80)
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\fscx#{zoom}\\fscy#{zoom}\\alpha&HFF&\\blur10\\t(0,70,\\alpha&H00&)\\t(0,#{land},0.35,\\fscx100\\fscy100\\blur0)\\t(#{land},#{dur},\\fscx106\\fscy106)#{fade_out(dur)}}#{text}")
      flash(start, [finish, start + 0.6].min, style, text, x, y, colors[:flash] || "FFFFFF")
    end

    def fx_zoom_through(start, finish, style, text, x, y, _layout, _random, _colors)
      dur = ms(finish - start)
      arrive = [dur * 0.35, 700].min.round
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\fscx22\\fscy22\\alpha&HFF&\\blur3\\t(0,#{arrive},2.2,\\fscx100\\fscy100\\alpha&H00&\\blur0)\\t(#{arrive},#{dur - 260},\\fscx108\\fscy108)\\t(#{dur - 260},#{dur},3,\\fscx260\\fscy260\\alpha&HFF&\\blur6)}#{text}")
    end

    def fx_blur_focus(start, finish, style, text, x, y, _layout, random, _colors)
      dur = ms(finish - start)
      focus = [dur * 0.45, 900].min.round
      blur = 12 + random.rand(10)
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\alpha&HFF&\\blur#{blur}\\fscx112\\fscy112\\t(0,#{focus},0.5,\\alpha&H00&\\blur0\\fscx100\\fscy100)\\t(#{focus},#{dur},\\fscx105\\fscy105)#{fade_out(dur)}}#{text}")
    end

    def fx_cascade(start, finish, style, text, x, y, _layout, random, _colors)
      dur = ms(finish - start)
      letters = text.split("\\N").map(&:chars)
      count = letters.sum(&:size)
      step = [[(dur * 0.45) / [count, 1].max, 70].min, 18].max
      order = (0...count).to_a
      order = order.shuffle(random: random) if random.rand < 0.4
      i = -1
      body = letters.map do |chars|
        chars.map do |ch|
          i += 1
          t0 = (order[i] * step).round
          ch == " " ? " " : "{\\alpha&HFF&\\blur6\\t(#{t0},#{t0 + 260},\\alpha&H00&\\blur0)}#{ch}"
        end.join
      end.join("\\N")
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\t(0,#{dur},\\fscx104\\fscy104)#{fade_out(dur)}}#{body}")
    end

    def fx_typewriter(start, finish, style, text, x, y, _layout, _random, _colors)
      dur = ms(finish - start)
      lines = text.split("\\N").map(&:chars)
      count = lines.sum(&:size)
      step = [[(dur * 0.5) / [count, 1].max, 75].min, 22].max
      i = -1
      body = lines.map do |chars|
        chars.map do |ch|
          i += 1
          t0 = (i * step).round
          ch == " " ? " " : "{\\alpha&HFF&\\t(#{t0},#{t0 + 1},\\alpha&H00&)}#{ch}"
        end.join
      end.join("\\N")
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})#{fade_out(dur)}}#{body}")
    end

    def fx_wipe(start, finish, style, text, x, y, layout, random, colors)
      dur = ms(finish - start)
      left = (x - layout.width / 2 - 24).round
      right = (x + layout.width / 2 + 24).round
      sweep = [dur * 0.45, 800].min.round
      reverse = random.rand < 0.3
      from, to = reverse ? ["#{right},0,#{right},#{H}", "#{left},0,#{right},#{H}"] : ["#{left},0,#{left},#{H}", "#{left},0,#{right},#{H}"]
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\clip(#{from})\\t(0,#{sweep},0.6,\\clip(#{to}))#{fade_out(dur)}}#{text}")
      a, b = reverse ? [right, left] : [left, right]
      top = (y - layout.height / 2 - 10).round
      height = (layout.height + 20).round
      streak = "{\\an7\\move(#{a},#{top},#{b},#{top},0,#{sweep})\\p1\\bord0\\shad0\\blur4\\1c&H#{bgr(colors[:flash] || 'FFFFFF')}&\\alpha&H40&\\t(#{sweep - 120},#{sweep},\\alpha&HFF&)}m 0 0 l 4 0 4 #{height} 0 #{height}{\\p0}"
      event(start, start + sweep / 1000.0, style, streak, layer: 2)
    end

    def fx_shine(start, finish, style, text, x, y, layout, random, _colors)
      dur = ms(finish - start)
      fx_blur_focus(start, finish, style, text, x, y, layout, random, {})
      left = (x - layout.width / 2 - 70).round
      right = (x + layout.width / 2 + 70).round
      t0 = [dur * 0.35, 650].min.round
      t1 = t0 + 700
      band = 46 + random.rand(30)
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\1c&HFFFFFF&\\blur1.5\\clip(#{left - band},0,#{left},#{H})\\t(#{t0},#{t1},0.8,\\clip(#{right},0,#{right + band},#{H}))#{fade_out(dur)}}#{text}", layer: 1)
    end

    def fx_burn(start, finish, style, text, x, y, _layout, _random, colors)
      dur = ms(finish - start)
      hot = bgr(colors[:glow] || "FF7A1A")
      cool = bgr(colors[:title] || "F0F0F0")
      settle = [dur * 0.5, 1100].min.round
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\1c&H#{hot}&\\3c&H#{hot}&\\bord3\\blur6\\alpha&HFF&\\t(0,160,\\alpha&H00&)\\t(0,#{settle},\\1c&H#{cool}&\\3c&H000000&\\bord0\\blur0)\\t(#{settle},#{dur},\\fscx104\\fscy104)#{fade_out(dur)}}#{text}")
      event(start, start + settle / 1000.0 + 0.4, style, "{\\an5\\pos(#{x},#{y})\\1c&H#{hot}&\\3c&H#{hot}&\\bord8\\blur14\\alpha&H50&\\t(0,#{settle + 400},\\alpha&HFF&)}#{text}", layer: 0)
    end

    def fx_flicker(start, finish, style, text, x, y, _layout, random, colors)
      dur = ms(finish - start)
      t = 0
      tags = +"\\alpha&HFF&"
      on = false
      while t < [dur * 0.4, 900].min
        t += 40 + random.rand(110)
        on = !on
        tags << "\\t(#{t},#{t + 1},\\alpha&H#{on ? '00' : 'D0'}&)"
      end
      tags << "\\t(#{t + 60},#{t + 61},\\alpha&H00&)"
      glow = bgr(colors[:glow] || "8B0000")
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})#{tags}#{fade_out(dur)}}#{text}", layer: 1)
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\1c&H#{glow}&\\3c&H#{glow}&\\bord5\\blur12#{tags}\\t(#{t},#{dur},\\alpha&H70&)#{fade_out(dur)}}#{text}", layer: 0)
    end

    def fx_glitch(start, finish, style, text, x, y, layout, random, _colors)
      dur = ms(finish - start)
      settle = [dur * 0.35, 700].min / 1000.0
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\alpha&HFF&\\t(#{(settle * 600).round},#{(settle * 1000).round},\\alpha&H00&)#{fade_out(dur)}}#{text}", layer: 2)
      [["FFFF00", -1], ["FF00FF", 1]].each do |color, dir|
        off = (2 + random.rand * 3).round(1) * dir
        event(start + settle, finish, style, "{\\an5\\pos(#{x + off},#{y})\\1c&H#{color}&\\alpha&HA0&\\t(0,500,\\alpha&HE0&)#{fade_out(dur - settle * 1000)}}#{text}", layer: 1)
      end
      top = (y - layout.height / 2 - 6).round
      bottom = (y + layout.height / 2 + 6).round
      t = start
      while t < start + settle
        len = 0.04 + random.rand * 0.06
        a = top + random.rand([bottom - top, 1].max)
        b = [a + 6 + random.rand(22), bottom].min
        dx = (random.rand * 28 - 14).round
        event(t, t + len, style, "{\\an5\\pos(#{x + dx},#{y})\\clip(0,#{a},#{W},#{b})}#{text}", layer: 3)
        event(t, t + len, style, "{\\an5\\pos(#{x - dx / 2},#{y})\\1c&HFFFF00&\\alpha&H60&\\clip(0,#{[a - 8, 0].max},#{W},#{a})}#{text}", layer: 3) if random.rand < 0.6
        t += len
      end
    end

    def fx_drop_bounce(start, finish, style, text, x, y, _layout, random, _colors)
      dur = ms(finish - start)
      fall = 260 + random.rand(120)
      event(start, finish, style, "{\\an5\\move(#{x},#{y - 150},#{x},#{y},0,#{fall})\\alpha&HFF&\\t(0,90,\\alpha&H00&)\\t(#{fall},#{fall + 90},\\fscx114\\fscy84)\\t(#{fall + 90},#{fall + 260},\\fscx97\\fscy104)\\t(#{fall + 260},#{fall + 380},\\fscx100\\fscy100)#{fade_out(dur)}}#{text}")
    end

    def fx_split(start, finish, style, text, x, y, _layout, random, colors)
      dur = ms(finish - start)
      join = 220 + random.rand(140)
      spread = 180 + random.rand(140)
      event(start, finish, style, "{\\an5\\move(#{x - spread},#{y},#{x},#{y},0,#{join})\\clip(0,0,#{W},#{y})\\t(#{join},#{dur},\\fscx105\\fscy105)#{fade_out(dur)}}#{text}")
      event(start, finish, style, "{\\an5\\move(#{x + spread},#{y},#{x},#{y},0,#{join})\\clip(0,#{y},#{W},#{H})\\t(#{join},#{dur},\\fscx105\\fscy105)#{fade_out(dur)}}#{text}")
      flash(start + join / 1000.0, [finish, start + join / 1000.0 + 0.5].min, style, text, x, y, colors[:flash] || "FFFFFF")
    end

    def fx_flip3d(start, finish, style, text, x, y, _layout, random, _colors)
      dur = ms(finish - start)
      turn = 380 + random.rand(260)
      axis = random.rand < 0.5 ? "frx" : "fry"
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\org(#{x},#{y})\\#{axis}90\\alpha&HFF&\\t(0,80,\\alpha&H00&)\\t(0,#{turn},0.4,\\#{axis}0)\\t(#{turn},#{dur},\\fscx105\\fscy105)#{fade_out(dur)}}#{text}")
    end

    private

    def flash(start, finish, style, text, x, y, color)
      event(start, finish, style, "{\\an5\\pos(#{x},#{y})\\1c&H#{bgr(color)}&\\3c&H#{bgr(color)}&\\bord6\\blur16\\alpha&H40&\\t(0,#{ms(finish - start)},\\alpha&HFF&\\fscx125\\fscy125)}#{text}", layer: 0)
    end

    def fade_out(dur, length = 220) = "\\t(#{[dur - length, 0].max},#{dur},\\alpha&HFF&)"

    def fit_size(font_key, lines, max_width, max_size, spacing)
      widest = lines.map { |l| text_width(font_key, l, 1.0, 0) }.max
      size = (max_width - spacing * lines.map(&:length).max) / [widest, 0.01].max
      [size, max_size].min
    end

    # Break at a colon when there is one, otherwise at the space closest to the middle.
    def split_lines(text)
      if (i = text.index(": "))
        return [text[0..i], text[(i + 2)..]]
      end

      spaces = text.enum_for(:scan, " ").map { Regexp.last_match.begin(0) }
      cut = spaces.min_by { |s| (s - text.length / 2.0).abs }
      [text[0...cut], text[(cut + 1)..]]
    end

    def ms(seconds) = (seconds * 1000).round

    def timestamp(seconds)
      seconds = [seconds, 0].max
      cs = (seconds * 100).round
      format("%d:%02d:%02d.%02d", cs / 360_000, (cs / 6000) % 60, (cs / 100) % 60, cs % 100)
    end

    def bgr(hex) = hex.to_s.scan(/../).reverse.join.upcase
    def ass_style_color(hex) = "&H00#{bgr(hex)}"
  end
end
