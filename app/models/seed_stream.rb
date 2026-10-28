require "digest"
require "securerandom"

# Deterministic random streams.
#
# The user seed is combined with the page number by a multiply-add (MAD) step, exactly once per
# page. Every record on that page then derives its own independent streams from the page seed and
# its offset: one for the core data (title, cast, genre...), one for likes, one per review and one
# for the trailer. Because the streams are independent, changing the likes average never touches
# titles, and adding reviews only appends new ones.
module SeedStream
  MASK64 = (1 << 64) - 1
  MULTIPLIER = 6_364_136_223_846_793_005 # Knuth's MMIX LCG multiplier
  INCREMENT = 1_442_695_040_888_963_407
  MAX_SEED = MASK64

  module_function

  def page_seed(seed, page)
    (seed.to_i * MULTIPLIER + page.to_i * INCREMENT) & MASK64
  end

  # 64-bit integer derived from arbitrary parts (SHA-256 is identical on every platform).
  def derive(*parts)
    Digest::SHA256.digest(parts.map(&:to_s).join("\u001f")).unpack1("Q>")
  end

  def random(*parts)
    Random.new(derive(*parts))
  end

  # A seed typed by the user. Decimal numbers up to 64 bits are used as they are; any other text
  # ("summer night", a 30-digit number) is hashed to 64 bits, so every input is a valid, stable seed.
  # Blank input gives nil.
  def parse(value)
    str = value.to_s.strip
    return nil if str.empty?

    if str.match?(/\A\d{1,20}\z/)
      int = Integer(str, 10)
      return int if int <= MAX_SEED
    end
    derive("text-seed", str.unicode_normalize(:nfc))
  end

  # A fresh 53-bit seed (well above the required 48 bits, and still exact as a JavaScript number).
  def random_seed = SecureRandom.random_number(1 << 53)
end
