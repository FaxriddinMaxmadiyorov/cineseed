# Builds a single Movie from (region, page seed, offset). Each concern uses its own random stream:
#
#   core     -> genre, kind, title, year, cast, director, runtime, rating, tagline, seasons, studio
#   likes    -> how many likes this record gets for the current average and who left them
#   review N -> the N-th review (its rating, author and text); the count has its own stream too
#   trailer  -> the edit decisions of the trailer (consumed by Trailer::Director)
#
# so the likes/reviews sliders can never change titles, and adding reviews only appends new ones.
class MovieFactory
  def initialize(region:, seed:, index:)
    @region = region
    @seed = seed
    @index = index
    page = (index - 1) / Catalog.page_size + 1
    @page_seed = SeedStream.page_seed(seed, page)
    @offset = (index - 1) % Catalog.page_size
    @config = Rails.configuration.x.catalog
  end

  def build(likes: 0, reviews: 0)
    core = core_attributes
    like_count, likers = like_attributes(likes)
    Movie.new(
      **core,
      region: @region,
      seed: @seed,
      index: @index,
      likes: like_count,
      likers: likers,
      reviews: review_list(reviews, core),
      trailer_seed: SeedStream.derive("trailer", @region.code, @page_seed, @offset)
    )
  end

  # Fractional averages are realised per record: floor(avg) plus one more with probability frac.
  # The deciding uniform number is drawn first from a dedicated stream, so moving the slider changes
  # counts monotonically and never reshuffles anything else.
  def self.count_for(average, random)
    average = average.to_f.clamp(0.0, Rails.configuration.x.catalog["max_per_movie"].to_f)
    base = average.floor
    base += 1 if random.rand < average - base
    base
  end

  private

  def stream(*parts) = SeedStream.random(*parts, @region.code, @page_seed, @offset)

  def core_attributes
    rng = stream("core")
    @region.with_faker(rng) do
      genre = Weighted.pick(Trailer::Config.genre_weights, rng)
      kind = Weighted.chance(rng, @config["series_share"]) ? "series" : "movie"
      year = pick_year(rng)
      title = Faker::MovieStore.title(genre: genre)
      cast = Array.new(Weighted.range(rng, @config["actors"])) { Faker::MovieStore.person }
      director = Faker::MovieStore.person
      runtime = kind == "series" ? Weighted.range(rng, @config["episode_runtime"]) : Weighted.range(rng, @config["runtime"][genre] || @config["runtime"]["default"])
      rating = Faker::MovieStore.rating(kind: kind, genre: genre)
      seasons = kind == "series" ? seasons_for(rng, year) : []
      {
        kind: kind,
        kind_name: Faker::MovieStore.kind_name(kind),
        genre: genre,
        genre_name: Faker::MovieStore.genre_name(genre),
        title: title,
        year: year,
        actors: cast,
        director: director,
        runtime_minutes: runtime,
        runtime_label: Faker::MovieStore.runtime(runtime),
        rating: rating,
        rating_label: Faker::MovieStore.rating_label(rating),
        tagline: Faker::MovieStore.tagline(genre: genre),
        studio: Faker::MovieStore.studio,
        platform: Faker::MovieStore.platform,
        other_title: Faker::MovieStore.title(genre: genre),
        release_month: rng.rand(1..12),
        release_day: rng.rand(1..28),
        seasons: seasons,
        seasons_label: seasons.any? ? Faker::MovieStore.seasons_label(seasons.size) : nil
      }
    end
  end

  def pick_year(rng)
    years = @config["years"]
    decade = Weighted.pick(years["decade_weights"].transform_keys(&:to_i), rng)
    rng.rand([decade, years["from"]].max..[decade + 9, years["to"]].min)
  end

  def seasons_for(rng, start_year)
    count = Weighted.pick(@config["seasons"].transform_keys(&:to_i), rng)
    year = start_year
    Array.new(count) do |i|
      year += rng.rand < 0.75 ? 1 : 2 if i.positive?
      episodes = Weighted.range(rng, @config["episodes"])
      episodes = rng.rand(18..24) if start_year < 2000 && rng.rand < 0.6
      Movie::Season.new(number: i + 1, year: year, episodes: episodes, label: Faker::MovieStore.season_line(number: i + 1, year: year, episodes: episodes))
    end.select { |s| s.year <= @config["years"]["to"] + 1 }.presence || [Movie::Season.new(number: 1, year: start_year, episodes: 8, label: Faker::MovieStore.season_line(number: 1, year: start_year, episodes: 8))]
  end

  def like_attributes(average)
    rng = stream("likes")
    count = self.class.count_for(average, rng)
    likers = @region.with_faker(rng) { Array.new(count) { Faker::MovieStore.username } }
    [count, likers]
  end

  def review_list(average, core)
    count = self.class.count_for(average, stream("review-count"))
    Array.new(count) do |n|
      rng = stream("review", n)
      @region.with_faker(rng) do
        rating = Weighted.pick(@config["review_ratings"].transform_keys(&:to_i), rng)
        critic = Weighted.chance(rng, @config["critic_share"])
        author = critic ? Faker::MovieStore.critic(Faker::MovieStore.person) : Faker::MovieStore.username
        text = Faker::MovieStore.review(title: core[:title], genre: core[:genre], genre_name: core[:genre_name], actors: core[:actors],
          director: core[:director], rating: rating, series: core[:kind] == "series")
        Movie::Review.new(author: author, critic: critic, rating: rating, text: text)
      end
    end
  end
end
