module CatalogHelper
  def media_url_for(movie, format) = media_path(region: movie.region.code, seed: movie.seed, index: movie.index, format: format)
  def warm_url_for(movie) = warm_media_path(region: movie.region.code, seed: movie.seed, index: movie.index)

  # Current generation parameters as query parameters (the seed as the user typed it).
  def catalog_query(**overrides)
    { region: @catalog.region.code, seed: @seed_text, likes: number_value(@catalog.likes),
      reviews: number_value(@catalog.reviews), view: @view }.merge(overrides)
  end

  def number_value(value) = (value % 1).zero? ? value.to_i.to_s : value.to_s

  # The swatch next to a genre uses the glow color of that genre's trailer titles.
  def genre_color(movie) = "##{Trailer::Config.genre(movie.genre).dig('palette', 'glow')}"

  def year_label(movie)
    return movie.year.to_s unless movie.series?

    first, last = movie.seasons.first.year, movie.seasons.last.year
    first == last ? first.to_s : "#{first}–#{last}"
  end

  def kind_label(movie) = movie.series? ? "#{movie.kind_name}, #{movie.seasons_label}" : nil

  def actors_label(movie) = movie.actors.join(", ")
end
