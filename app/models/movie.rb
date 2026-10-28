# One generated catalog entry (a movie or a series). Plain Ruby object: nothing is persisted, every
# field is recomputed from (region, seed, index) on demand.
class Movie
  Review = Data.define(:author, :critic, :rating, :text)
  Season = Data.define(:number, :year, :episodes, :label)

  attr_reader :region, :seed, :index, :kind, :genre, :genre_name, :title, :year, :actors, :director,
    :runtime_minutes, :rating, :rating_label, :tagline, :studio, :seasons, :likes, :likers, :reviews,
    :trailer_seed, :release_month, :release_day, :other_title, :platform

  def initialize(**attrs)
    attrs.each { |k, v| instance_variable_set(:"@#{k}", v) }
  end

  def series? = kind == "series"
  def kind_name = @kind_name
  def runtime_label = @runtime_label
  def seasons_label = @seasons_label

  def page = (index - 1) / Catalog.page_size + 1
  def offset = (index - 1) % Catalog.page_size

  def key = "#{region.code}/#{seed}/#{index}"

  # File name used in the ZIP export.
  def file_name(ext)
    base = title.to_s.unicode_normalize(:nfc).gsub(%r{[/\\:*?"<>|\u0000-\u001f]}, " ").squeeze(" ").strip
    "#{base.presence || "movie-#{index}"}.#{ext}"
  end
end
