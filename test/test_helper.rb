ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    def region(code = "en-US") = Region.find(code)
    def catalog(code = "en-US", seed: 42, likes: 3.7, reviews: 2.5) = Catalog.new(region: region(code), seed: seed, likes: likes, reviews: reviews)
    def core(movie) = [movie.title, movie.actors, movie.year, movie.genre, movie.director, movie.tagline, movie.kind, movie.trailer_seed]
  end
end
