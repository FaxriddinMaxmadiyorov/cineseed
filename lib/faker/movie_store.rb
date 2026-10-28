module Faker
  # Faker generator for the movie store, built the way Faker documents custom generators: a subclass
  # of Faker::Base whose data lives in locale YAML under `faker.movie_store` (config/regions/*.yml).
  # Values are read with Faker's own translate/fetch/sample, so they honour Faker::Config.locale and
  # Faker::Config.random just like the built-in generators.
  class MovieStore < Base
    CACHE = Concurrent::Map.new

    class << self
      def genre_name(key) = data(:genres)[key.to_sym].to_s
      def kind_name(kind) = data(:kinds)[kind.to_sym].to_s

      def title(genre:)
        Cineseed::TitleComposer.new(data(:title), random: Faker::Config.random, genre: genre).compose
      end

      def tagline(genre:) = sample(data(:taglines)[genre.to_sym])

      # A person's name with matching first/last name forms where the locale distinguishes gender
      # (Ukrainian surnames, for example). Falls back to Faker's generic keys.
      def person(gender = nil)
        gender ||= sample(%i[male female])
        first = gendered("name.#{gender}_first_name", "name.first_name")
        last = gendered("name.#{gender}_last_name", "name.last_name")
        "#{first} #{last}"
      end

      # Usernames from the region's own names, transliterated to ASCII with the region's rules
      # (i18n.transliterate.rule in the region file) and shaped by its username patterns.
      # (Faker::Internet.username always switches to English names.)
      def username
        gender = sample(%i[male female])
        first = ascii(gendered("name.#{gender}_first_name", "name.first_name"))
        last = ascii(gendered("name.#{gender}_last_name", "name.last_name"))
        return Faker::Internet.username(specifier: 5..14) if first.empty? || last.empty?

        random = Faker::Config.random
        interpolate(sample(data(:usernames)), first: first, last: last, f: first[0], l: last[0],
          nn: random.rand(1..99), yy: format("%02d", random.rand(60..109) % 100))
      end

      def ascii(text)
        I18n.transliterate(text.to_s.downcase, locale: Faker::Config.locale, replacement: "").gsub(/[^a-z0-9]/, "")
      end

      def studio = expand(sample(data(:trailer)[:studios]))
      def company = expand(sample(data(:trailer)[:companies]))
      def platform = sample(data(:trailer)[:platforms]).to_s

      def rating(kind:, genre:)
        table = data(:rating_by_genre)[kind.to_sym]
        weights = table[genre.to_sym] || table[:default]
        Weighted.pick(weights.transform_keys(&:to_s), Faker::Config.random)
      end

      def rating_label(code) = data(:ratings)[code.to_sym].to_s

      def runtime(minutes)
        template = (optional_data(:runtime_minutes) if minutes < 60) || data(:runtime)
        format(template, h: minutes / 60, m: minutes % 60)
      end
      def seasons_label(count)
        label = data(:seasons)
        label = label[count == 1 ? :one : :other] || label[:other] if label.is_a?(Hash)
        format(label, count: count)
      end
      def season_line(number:, year:, episodes:) = format(data(:season_line), n: number, year: year, episodes: episodes)

      # One review: opener + one or two body lines (maybe a genre-specific one) + optional closer.
      # Series get their own pool, written about episodes and seasons.
      def review(title:, genre:, genre_name:, actors:, director:, rating:, series: false)
        reviews = data(:reviews)
        pool = series && reviews[:series] ? reviews[:series] : reviews
        mood = rating >= 7 ? :positive : (rating >= 5 ? :mixed : :negative)
        parts = [sample(pool[:openers][mood])]
        lines = pool[:lines][mood].dup
        genre_lines = series ? nil : reviews.dig(:genre_lines, genre.to_sym, mood)
        parts << sample(genre_lines) if genre_lines.present? && Faker::Config.random.rand < 0.5
        parts << lines.delete_at(Faker::Config.random.rand(lines.size))
        parts << lines.delete_at(Faker::Config.random.rand(lines.size)) if Faker::Config.random.rand < 0.35
        parts << sample(pool[:closers][mood]) if Faker::Config.random.rand < 0.6

        cast = actors.shuffle(random: Faker::Config.random)
        values = { title: title, actor: cast[0], actor2: cast[1] || cast[0], director: director, genre: genre_name, genre_lower: genre_name.downcase, rating: rating }
        parts.map { |p| interpolate(p, values) }.join(" ")
      end

      def critic(name) = format(data(:reviews)[:critic_suffix], name: name, outlet: sample(data(:reviews)[:critic_outlets]))

      # Trailer copy: everything typeset on screen comes from the region file as well.
      def trailer_copy = data(:trailer)

      def interpolate(template, values)
        template.to_s.gsub(/\{(\w+)\}/) { values.fetch(Regexp.last_match(1).to_sym) { Regexp.last_match(0) }.to_s }
      end

      # Expands {faker:Name.last_name} placeholders inside list values (studio names and the like).
      def expand(template)
        template.to_s.gsub(/\{faker:(\w+)\.(\w+)\}/) do
          klass, method = Regexp.last_match(1), Regexp.last_match(2)
          raise ArgumentError, "Faker::#{klass}.#{method} is not allowed" unless Cineseed::TitleComposer::FAKER.fetch(klass, []).include?(method)

          Faker.const_get(klass).public_send(method)
        end
      end

      private

      def data(key)
        CACHE.compute_if_absent([Faker::Config.locale, key]) { translate("faker.movie_store.#{key}") }
      end

      # For keys a region file may leave out.
      def optional_data(key)
        data(key).presence
      rescue I18n::MissingTranslationData
        nil
      end

      def gendered(key, fallback)
        fetch(key)
      rescue I18n::MissingTranslationData
        fetch(fallback)
      end
    end
  end
end
