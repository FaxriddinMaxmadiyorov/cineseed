require "test_helper"

class SeedStreamTest < ActiveSupport::TestCase
  test "page seed combines seed and page with a multiply-add and stays within 64 bits" do
    expected = (123 * SeedStream::MULTIPLIER + 7 * SeedStream::INCREMENT) & SeedStream::MASK64
    assert_equal expected, SeedStream.page_seed(123, 7)
    refute_equal SeedStream.page_seed(123, 7), SeedStream.page_seed(123, 8)
    refute_equal SeedStream.page_seed(123, 7), SeedStream.page_seed(124, 7)
    assert_operator SeedStream.page_seed(SeedStream::MAX_SEED, 10**12), :<=, SeedStream::MASK64
  end

  test "derived streams are fixed values, identical on every machine and every day" do
    # SHA-256 based: if this ever changes, every catalog changes with it
    assert_equal 9_058_008_478_411_856_631, SeedStream.derive("core", "en-US", 1, 0)
    assert_equal SeedStream.random("x", 1).rand(1000), SeedStream.random("x", 1).rand(1000)
  end

  test "parse accepts 64-bit numbers and turns any other text into a stable seed" do
    assert_equal 42, SeedStream.parse(" 42 ")
    assert_equal 2**64 - 1, SeedStream.parse((2**64 - 1).to_s)
    assert_equal 2**48 + 5, SeedStream.parse((2**48 + 5).to_s)
    text = SeedStream.parse("summer night")
    assert_kind_of Integer, text
    assert_equal text, SeedStream.parse("summer night")
    refute_equal SeedStream.parse("summer night"), SeedStream.parse("summer nights")
    assert_kind_of Integer, SeedStream.parse("1" * 25) # too big for 64 bits: hashed, not rejected
    assert_nil SeedStream.parse("   ")
  end

  test "random seeds have more than 48 bits of range" do
    seeds = Array.new(50) { SeedStream.random_seed }
    assert seeds.any? { |s| s >= 2**48 }
    assert seeds.all? { |s| s < 2**53 }
  end
end
