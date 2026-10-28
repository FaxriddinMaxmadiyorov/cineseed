# A language/region the catalog can be generated for. Regions are discovered from the YAML files in
# config/regions, so adding or removing a region never requires a code change: drop in a file with
# a `cineseed.region` block and a `faker.movie_store` dataset and it shows up in the selector.
class Region
  DIR = Rails.root.join("config", "regions")

  attr_reader :code, :name, :short, :script, :order

  def self.all
    @all ||= Dir[DIR.join("*.yml")].filter_map { |path| from_file(path) }.sort_by { |r| [r.order, r.code] }.freeze
  end

  def self.find(code)
    all.find { |r| r.code == code.to_s }
  end

  def self.default = all.first

  def self.from_file(path)
    data = YAML.load_file(path)
    code, tree = data.first
    meta = tree.dig("cineseed", "region")
    return unless meta && tree.dig("faker", "movie_store")

    new(code: code, name: meta["name"], short: meta["short"] || code, script: meta["script"] || "latin", order: meta["order"] || 100)
  end

  def initialize(code:, name:, short:, script:, order:)
    @code = code.to_s
    @name = name
    @short = short
    @script = script.to_s
    @order = order.to_i
  end

  def locale = code.to_sym

  def to_param = code

  # Runs Faker inside this region with the given random stream (both are thread-local in Faker).
  def with_faker(random)
    previous_locale = Faker::Config.own_locale
    previous_random = Thread.current[:faker_config_random]
    Faker::Config.locale = locale
    Faker::Config.random = random
    yield
  ensure
    Faker::Config.locale = previous_locale
    Faker::Config.random = previous_random
  end

  def ==(other) = other.is_a?(Region) && other.code == code
  alias eql? ==
  def hash = code.hash
end
