require "test_helper"

class CatalogTest < ActiveSupport::TestCase
  test "the same parameters always produce the same page" do
    a = catalog(seed: 987_654_321).page(3).map { |m| core(m) + [m.likes, m.reviews.map(&:text)] }
    b = catalog(seed: 987_654_321).page(3).map { |m| core(m) + [m.likes, m.reviews.map(&:text)] }
    assert_equal a, b
  end

  test "records are numbered from 1 and pages continue the sequence" do
    assert_equal (1..20).to_a, catalog.page(1).map(&:index)
    assert_equal (41..60).to_a, catalog.page(3).map(&:index)
    assert_equal core(catalog.page(2).first), core(catalog.movie(21))
  end

  test "seed and region change the data" do
    titles = ->(c) { c.page(1).map(&:title) }
    refute_equal titles.(catalog(seed: 1)), titles.(catalog(seed: 2))
    refute_equal titles.(catalog("en-US")), titles.(catalog("de-DE"))
    refute_equal titles.(catalog(seed: 1)), catalog(seed: 1).page(2).map(&:title)
  end

  test "changing likes changes only the like counts" do
    low = catalog(likes: 1.2).page(2)
    high = catalog(likes: 8.6).page(2)
    assert_equal low.map { |m| core(m) }, high.map { |m| core(m) }
    assert_equal low.map { |m| m.reviews.map(&:text) }, high.map { |m| m.reviews.map(&:text) }
    assert low.zip(high).all? { |l, h| h.likes >= l.likes }
  end

  test "changing reviews only adds or removes reviews" do
    few = catalog(reviews: 1.5).page(1)
    many = catalog(reviews: 6.5).page(1)
    assert_equal few.map { |m| core(m) + [m.likes] }, many.map { |m| core(m) + [m.likes] }
    few.zip(many).each do |f, m|
      assert_operator m.reviews.size, :>=, f.reviews.size
      assert_equal f.reviews, m.reviews.first(f.reviews.size), "existing reviews must stay as they are"
    end
  end

  test "whole averages are exact and fractional ones are met on average" do
    assert catalog(likes: 0).page(1).all? { |m| m.likes.zero? }
    assert catalog(likes: 10).page(1).all? { |m| m.likes == 10 }
    assert catalog(reviews: 4).page(1).all? { |m| m.reviews.size == 4 }

    counts = Array.new(4000) { |i| MovieFactory.count_for(0.5, SeedStream.random("t", i)) }
    assert_equal [0, 1], counts.uniq.sort
    assert_in_delta 0.5, counts.sum / 4000.0, 0.04

    movies = (1..10).flat_map { |p| catalog(likes: 3.7, seed: 77).page(p) }
    assert movies.all? { |m| [3, 4].include?(m.likes) }
    assert_in_delta 3.7, movies.sum(&:likes) / movies.size.to_f, 0.15
  end

  test "averages from the toolbar are clamped to 0..10" do
    assert_equal 10.0, Catalog.average("25", 1)
    assert_equal 0.0, Catalog.average("-3", 1)
    assert_equal 3.7, Catalog.average("3.7", 1)
    assert_equal 1, Catalog.average("abc", 1)
  end

  test "every region produces realistic localized data without placeholders" do
    { "en-US" => /\A[\p{Latin}\d\s'’&:,.!?\-–—]+\z/, "de-DE" => /\A[\p{Latin}\d\s'’&:,.!?\-–—„“]+\z/, "uk-UA" => /\A[IVX\p{Cyrillic}\d\s'’ʼ&:,.!?\-–—«»]+\z/ }.each do |code, pattern|
      catalog(code, seed: 5).page(1).each do |movie|
        assert_match pattern, movie.title, "#{code} title #{movie.title.inspect}"
        assert_match pattern, movie.genre_name
        movie.actors.each { |name| assert_match pattern, name }
        refute_match(/[{}%]|lorem|translation missing/i, [movie.title, movie.tagline, movie.reviews.map(&:text)].join(" "))
      end
    end
  end

  test "some records are series with seasons" do
    series = (1..5).flat_map { |p| catalog(seed: 3).page(p) }.select(&:series?)
    assert series.any?
    series.each do |s|
      assert s.seasons.any?
      assert_equal (1..s.seasons.size).to_a, s.seasons.map(&:number)
      assert_equal s.seasons.map(&:year).sort, s.seasons.map(&:year)
    end
  end
end
