# The infinite catalog for one combination of generation parameters.
class Catalog
  DEFAULT_LIKES = 3.7
  DEFAULT_REVIEWS = 2.5

  attr_reader :region, :seed, :likes, :reviews

  def self.page_size = Rails.configuration.x.catalog["page_size"]

  def self.from_params(params, seed: nil)
    region = Region.find(params[:region]) || Region.default
    seed ||= SeedStream.parse(params[:seed]) || 0
    new(region: region, seed: seed, likes: average(params[:likes], DEFAULT_LIKES), reviews: average(params[:reviews], DEFAULT_REVIEWS))
  end

  def self.average(value, default)
    return default if value.blank?

    Float(value).clamp(0.0, 10.0).round(2)
  rescue ArgumentError, TypeError
    default
  end

  def initialize(region:, seed:, likes: DEFAULT_LIKES, reviews: DEFAULT_REVIEWS)
    @region = region
    @seed = seed
    @likes = likes
    @reviews = reviews
  end

  def page(number)
    indexes(number).map { |index| movie(index) }
  end

  def indexes(number)
    number = [number.to_i, 1].max
    first = (number - 1) * self.class.page_size + 1
    first...(first + self.class.page_size)
  end

  def movie(index)
    MovieFactory.new(region: region, seed: seed, index: index).build(likes: likes, reviews: reviews)
  end

  def to_params = { region: region.code, seed: seed.to_s, likes: likes, reviews: reviews }
end
