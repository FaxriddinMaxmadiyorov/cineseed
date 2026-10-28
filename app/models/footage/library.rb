module Footage
  # Runtime view of footage/manifest.json: every shot with its measurements and tags.
  class Library
    ROOT = Rails.root.join("footage")

    Clip = Data.define(:id, :source, :family, :path, :still, :duration, :width, :height, :scene, :tags, :luma, :saturation, :warmth, :motion) do
      def aspect = width.to_f / height
    end

    def self.instance = (@instance ||= new(ROOT))

    attr_reader :clips

    def initialize(root)
      manifest = JSON.parse(root.join("manifest.json").read)
      @clips = manifest.fetch("clips").map do |c|
        Clip.new(
          id: c["id"], source: c["source"], family: c["family"],
          path: root.join(c["file"]).to_s, still: root.join(c["still"]).to_s,
          duration: c["duration"].to_f, width: c["width"], height: c["height"], scene: c["scene"],
          tags: (Array(c["tags"]) + mood_tags(c)).uniq.freeze,
          luma: c["luma"], saturation: c["saturation"], warmth: c["warmth"], motion: c["motion"]
        )
      end.freeze
      @by_family = @clips.group_by(&:family).freeze
    end

    def family(name) = @by_family.fetch(name.to_s, [])
    def families = @by_family.keys

    # Shots of a family scored for a genre's clip rules (require any / prefer / avoid). Sources are
    # tagged with the genres they suit, which counts most; sources that were cut into many shots are
    # damped so that one long video does not dominate the pool.
    def scored(family:, rules:, genre: nil)
      pool = family(family)
      required = Array(rules["require"])
      if required.any?
        strict = pool.select { |c| (c.tags & required).any? }
        pool = strict if strict.size >= 8
      end
      prefer = Array(rules["prefer"])
      avoid = Array(rules["avoid"])
      per_source = pool.group_by(&:source).transform_values(&:size)
      pool.map do |clip|
        score = 1.0 + 0.8 * (clip.tags & prefer).size - 1.5 * (clip.tags & avoid).size
        score += 1.6 if genre && clip.tags.include?(genre.to_s)
        [clip, [score, 0.05].max / Math.sqrt(per_source[clip.source])]
      end
    end

    private

    # Mood tags derived from the measured statistics (thresholds sit near the library quartiles).
    def mood_tags(c)
      tags = []
      tags << "dark" if c["luma"] < 62
      tags << "bright" if c["luma"] > 138
      tags << "warm" if c["warmth"] > 14
      tags << "cool" if c["warmth"] < -4
      tags << "mono" if c["saturation"] < 4.5
      tags << "dynamic" if c["motion"] > 0.035
      tags << "calm" if c["motion"] < 0.008
      tags
    end
  end
end
