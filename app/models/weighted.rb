# Weighted sampling with an explicit random stream (never the global RNG).
module Weighted
  module_function

  # choices: Hash{value => weight} or Array of [value, weight] / items with a block returning weight.
  def pick(choices, random, &weight)
    pairs = if choices.is_a?(Hash)
      choices.to_a
    elsif weight
      choices.map { |c| [c, weight.call(c)] }
    else
      choices
    end
    pairs = pairs.select { |_, w| w.to_f.positive? }
    raise ArgumentError, "nothing to pick from" if pairs.empty?

    target = random.rand * pairs.sum { |_, w| w.to_f }
    pairs.each do |value, w|
      target -= w.to_f
      return value if target < 0
    end
    pairs.last.first
  end

  def range(random, (min, max))
    min.is_a?(Integer) && max.is_a?(Integer) ? random.rand(min..max) : min + random.rand * (max - min)
  end

  def chance(random, probability) = random.rand < probability.to_f
end
