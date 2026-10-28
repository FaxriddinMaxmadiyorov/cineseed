require "test_helper"

class RegionTest < ActiveSupport::TestCase
  test "regions are discovered from config/regions" do
    assert_equal %w[en-US de-DE uk-UA], Region.all.map(&:code)
    assert_equal "en-US", Region.default.code
    assert_nil Region.find("xx-XX")
  end

  test "usernames are built from the region's own names" do
    uk = region("uk-UA").with_faker(Random.new(1)) { Array.new(30) { Faker::MovieStore.username } }
    assert uk.all? { |u| u.match?(/\A[a-z0-9._]+\z/) }
    de = region("de-DE").with_faker(Random.new(1)) { Array.new(5) { Faker::MovieStore.username } }
    refute_equal uk.first(5), de
  end
end
