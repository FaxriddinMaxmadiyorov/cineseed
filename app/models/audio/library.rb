module Audio
  # Runtime view of audio/manifest.json: beat-analysed music excerpts and trailer sound effects.
  class Library
    ROOT = Rails.root.join("audio")

    Excerpt = Data.define(:id, :track, :path, :moods, :duration, :bpm, :beats, :downbeats, :energy, :hits, :score) do
      # Seconds per musical "unit" used to cut shots: one beat, or two at fast tempos.
      def unit = (60.0 / bpm) * (bpm > 135 ? 2 : 1)
    end
    Effect = Data.define(:id, :kind, :path, :duration, :peak_at)

    def self.instance = (@instance ||= new(ROOT))

    attr_reader :excerpts, :effects

    def initialize(root)
      manifest = JSON.parse(root.join("manifest.json").read)
      @excerpts = manifest.fetch("music").filter_map do |m|
        next if m["score"].to_f < 0.1 || m["beats"].size < 8

        Excerpt.new(id: m["id"], track: m["track"], path: root.join(m["file"]).to_s, moods: m["moods"].freeze,
          duration: m["duration"].to_f, bpm: m["bpm"].to_f, beats: m["beats"].freeze, downbeats: m["downbeats"].freeze,
          energy: m["energy"].freeze, hits: m["hits"].freeze, score: m["score"].to_f)
      end.freeze
      @effects = manifest.fetch("sfx").to_h do |kind, list|
        [kind, list.map { |e| Effect.new(id: e["id"], kind: kind, path: root.join(e["file"]).to_s, duration: e["duration"].to_f, peak_at: e["peak_at"].to_f) }.freeze]
      end.freeze
    end

    # Excerpts matching any of the moods, weighted by how many moods match and by excerpt quality.
    def music_for(moods)
      moods = Array(moods)
      matching = excerpts.filter_map do |e|
        overlap = (e.moods & moods).size
        [e, overlap * (0.5 + e.score)] if overlap.positive?
      end
      matching.presence || excerpts.map { |e| [e, e.score] }
    end

    def effect(kind, random)
      list = effects.fetch(kind.to_s, [])
      list[random.rand(list.size)] if list.any?
    end
  end
end
