module Trailer
  # Read-only access to config/trailer/*.yml (genre styles, fonts, color grades).
  module Config
    DIR = Rails.root.join("config", "trailer")
    FONTS_DIR = Rails.root.join("vendor", "fonts")

    module_function

    def genres = (@genres ||= load("genres")["genres"].freeze)
    def defaults = (@defaults ||= load("genres")["defaults"].freeze)
    def fonts = (@fonts ||= load("fonts")["fonts"].freeze)
    def grades = (@grades ||= load("grades")["grades"].freeze)
    def family_grades = (@family_grades ||= load("grades")["family_grades"].freeze)

    def genre_weights = (@genre_weights ||= genres.transform_values { |g| g["weight"] }.freeze)

    # Genre profile with defaults filled in.
    def genre(key)
      (@genre_profiles ||= {})[key.to_s] ||= defaults.merge(genres.fetch(key.to_s)).freeze
    end

    def font(key) = fonts.fetch(key.to_s)

    def load(name) = YAML.load_file(DIR.join("#{name}.yml"))
  end
end
