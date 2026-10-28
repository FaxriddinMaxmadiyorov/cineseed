module Cineseed
  # Builds movie titles from a region's title grammar (faker.movie_store.title).
  #
  # The engine knows nothing about any particular language. Patterns reference slots:
  #   {noun:x} / {nouns:x}   bind a singular / plural noun to variable x
  #   {noun:x.gen}           another case form of x (keys come from the data: nom, gen, pl, pl_gen)
  #   {adj@x} {adj.weak@x.gen}  adjective agreeing with x (stem + ending table, or an invariant base)
  #   {art.def@x.gen}        article from the region's article table
  #   {pick:list}            entry of title.lists.list (entries can be templates themselves)
  #   {base}                 a nested title built from patterns marked `base: true`
  #   {faker:Name.first_name} a value from Faker (allow-listed generators only, `avoid` values redrawn)
  # Grammatical gender, cases and endings all live in the YAML, so German declension and Ukrainian
  # agreement are just data.
  class TitleComposer
    TOKEN = /\{([^{}]+)\}/
    GENRE_BIAS = 0.7
    FAKER = { "Name" => %w[first_name last_name], "Address" => %w[city] }.freeze

    def initialize(data, random:, genre:)
      @data = data
      @random = random
      @genre = genre.to_s
      @used_nouns = []
      @used_adjectives = []
    end

    def compose
      finish(render(pattern(base_only: false)[:t], {}))
    end

    private

    def pattern(base_only:)
      list = @data[:patterns]
      list = list.select { |p| p[:base] } if base_only
      Weighted.pick(list, @random) { |p| p[:w] || 1 }
    end

    def render(template, vars)
      bind(template.to_s, vars)
      template.to_s.gsub(TOKEN) { resolve(Regexp.last_match(1), vars) }
    end

    # Nouns are bound before rendering so that articles and adjectives can appear before their noun.
    def bind(template, vars)
      template.scan(TOKEN).flatten.each do |token|
        match = token.match(/\A(nouns?):(\w+)(?:\.(\w+))?\z/) or next
        name = match[2]
        next if vars[name]

        plural = match[1] == "nouns"
        candidates = @data[:nouns].select do |n|
          next false if @used_nouns.include?(n[:nom])
          next false if plural && !n[:pl]
          next false if match[3] == "gen" && !plural && !n[:gen]

          true
        end
        entry = pick(candidates)
        @used_nouns << entry[:nom]
        vars[name] = { entry: entry, plural: plural }
      end
    end

    def resolve(token, vars)
      case token
      when "base"
        render(pattern(base_only: true)[:t], {})
      when /\Apick:(\w+)\z/
        render(pick(@data.dig(:lists, Regexp.last_match(1).to_sym))[:v], vars)
      when /\Afaker:(\w+)\.(\w+)\z/
        faker(Regexp.last_match(1), Regexp.last_match(2))
      when /\Anouns?:(\w+)(?:\.(\w+))?\z/
        noun_form(vars.fetch(Regexp.last_match(1)), Regexp.last_match(2))
      when /\Aadj(?:\.(\w+))?@(\w+)(?:\.(\w+))?\z/
        adjective(Regexp.last_match(1), vars.fetch(Regexp.last_match(2)), Regexp.last_match(3))
      when /\Aart\.(\w+)@(\w+)(?:\.(\w+))?\z/
        article(Regexp.last_match(1), vars.fetch(Regexp.last_match(2)), Regexp.last_match(3))
      else
        token
      end
    end

    def noun_form(var, kase)
      entry = var[:entry]
      if var[:plural]
        kase == "gen" ? (entry[:pl_gen] || entry[:pl]) : entry[:pl]
      else
        kase && entry[kase.to_sym] ? entry[kase.to_sym] : entry[:nom]
      end.to_s
    end

    def agreement_key(var) = var[:plural] ? :pl : (var[:entry][:g] || :m).to_sym

    def adjective(mode, var, kase)
      candidates = @data[:adjectives].reject { |a| @used_adjectives.include?(a) }
      entry = pick(candidates)
      @used_adjectives << entry
      return entry[:base].to_s if entry[:base]

      mode = (mode || "default").to_sym
      kase = (kase || "nom").to_sym
      key = agreement_key(var)
      override = entry.dig(:forms, mode, kase, key)
      return override.to_s if override

      ending = @data.dig(:adjective_endings, entry[:class].to_sym, mode, kase, key)
      "#{entry[:stem]}#{ending}"
    end

    def article(kind, var, kase)
      @data.dig(:articles, kind.to_sym, (kase || "nom").to_sym, agreement_key(var)).to_s
    end

    # Values listed under `avoid` in the region's title data are drawn again.
    def faker(klass, method)
      raise ArgumentError, "Faker::#{klass}.#{method} is not allowed in titles" unless FAKER.fetch(klass, []).include?(method)

      avoid = Array(@data[:avoid]).map(&:to_s)
      value = nil
      16.times do
        value = Faker.const_get(klass).public_send(method).to_s
        break unless avoid.include?(value)
      end
      value
    end

    # Genre-flavoured choice: most of the time take an entry tagged with the movie's genre.
    def pick(list)
      raise ArgumentError, "empty title lexicon" if list.blank?

      tagged = list.select { |e| e.is_a?(Hash) && Array(e[:tags]).map(&:to_s).include?(@genre) }
      pool = tagged.size >= 3 && @random.rand < GENRE_BIAS ? tagged : list
      pool[@random.rand(pool.size)]
    end

    def finish(text)
      text = text.gsub(/\s+/, " ").gsub(" :", ":").strip
      case @data[:case].to_s
      when "words" then title_case(text)
      else sentence_case(text)
      end
    end

    def sentence_case(text)
      text = upcase_first(text)
      text.gsub(/(:\s+)(\p{Ll})/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).upcase}" }
    end

    def title_case(text)
      small = Array(@data[:small_words]).map { |w| w.to_s.downcase }
      words = text.split(" ")
      words.each_with_index.map do |word, i|
        after_colon = i.positive? && words[i - 1].end_with?(":")
        if i.zero? || i == words.size - 1 || after_colon || !small.include?(word.downcase)
          upcase_first(word)
        else
          word.downcase
        end
      end.join(" ")
    end

    def upcase_first(word)
      return word if word.empty?

      first = word[0]
      first.match?(/\p{L}/) ? first.upcase + word[1..] : word
    end
  end
end
