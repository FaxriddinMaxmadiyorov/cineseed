require "test_helper"

class Trailer::DirectorTest < ActiveSupport::TestCase
  test "a movie always gets the same cut" do
    movie = catalog(seed: 2024).movie(7)
    a = Trailer::Director.plan(movie)
    b = Trailer::Director.plan(catalog(seed: 2024, likes: 9, reviews: 9).movie(7))
    assert_equal a.ass, b.ass
    assert_equal a.segments.map { |s| [s.kind, s.start, s.duration, s.shot&.clip&.id, s.transition] },
      b.segments.map { |s| [s.kind, s.start, s.duration, s.shot&.clip&.id, s.transition] }
    assert_equal a.music.id, b.music.id
  end

  test "trailers last 5 to 10 seconds, are made of real footage and end on the title" do
    plans = %w[en-US de-DE uk-UA].flat_map { |code| catalog(code, seed: 99).page(1).map { |m| Trailer::Director.plan(m) } }
    plans.each do |plan|
      assert_includes 5.0..10.0, plan.duration
      assert_equal :title, plan.segments.last.kind
      shots = plan.segments.select { |s| s.kind == :shot }
      assert_operator shots.size, :>=, 3
      shots.each { |s| assert File.exist?(s.shot.clip.path) }
      plan.segments.each_cons(2) { |a, b| assert_in_delta a.finish, b.start, 0.002 }
      typeset = plan.ass.gsub(/\{[^}]*\}/, "").upcase # text without the animation tags
      Trailer::Typography.clean(plan.movie.title).split.each { |word| assert_includes typeset, word.upcase }
    end
  end

  test "trailers vary in footage, music, grade, fonts and animation" do
    plans = catalog(seed: 31).page(1).map { |m| Trailer::Director.plan(m) }
    assert_operator plans.map { |p| p.music.id }.uniq.size, :>=, 10
    assert_operator plans.map { |p| p.grade[:name] }.uniq.size, :>=, 5
    assert_operator plans.map(&:title_font).uniq.size, :>=, 8
    assert_operator plans.flat_map { |p| p.segments.filter_map { |s| s.shot.is_a?(Trailer::Director::Shot) ? s.shot.clip.id : nil } }.uniq.size, :>=, 60
  end

  test "Ukrainian trailers only use fonts with Cyrillic glyphs" do
    catalog("uk-UA", seed: 8).page(1).each do |movie|
      plan = Trailer::Director.plan(movie)
      assert_includes Trailer::Config.font(plan.title_font)["scripts"], "cyrillic"
      plan.ass.scan(/^Style: \w+,([^,]+),/).flatten.uniq.each do |family|
        font = Trailer::Config.fonts.values.find { |f| f["family"] == family }
        assert_includes font["scripts"], "cyrillic", family
      end
    end
  end
end
