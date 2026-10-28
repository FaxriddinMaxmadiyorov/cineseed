require "test_helper"

class TitleComposerTest < ActiveSupport::TestCase
  test "titles never leak template syntax and vary a lot" do
    Region.all.each do |region|
      titles = region.with_faker(Random.new(11)) do
        Trailer::Config.genres.keys.flat_map { |genre| Array.new(25) { Faker::MovieStore.title(genre: genre) } }
      end
      titles.each { |t| refute_match(/[{}@]|\s{2}|\A\s|\s\z/, t, "#{region.code}: #{t.inspect}") }
      assert_operator titles.uniq.size, :>, titles.size * 0.9, "#{region.code} titles repeat too often"
    end
  end

  test "German adjectives agree with the noun's gender" do
    data = I18n.t("faker.movie_store.title", locale: :"de-DE")
    endings = data.dig(:adjective_endings)
    refute_nil endings
    titles = region("de-DE").with_faker(Random.new(3)) { Array.new(300) { Faker::MovieStore.title(genre: "drama") } }
    # "Der/Die/Das <adj>e <Noun>": the strong article forms are followed by a weak -e ending
    titles.grep(/\A(Der|Die|Das) \p{Ll}+ /).each do |title|
      assert_match(/\A(Der|Die|Das) \p{Ll}+e[n]? /, title)
    end
  end
end
