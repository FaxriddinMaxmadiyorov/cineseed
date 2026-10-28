require "test_helper"

class CatalogControllerTest < ActionDispatch::IntegrationTest
  test "the store opens with data: toolbar and a first table page from a random seed" do
    get root_path
    assert_response :success
    assert_select "form#toolbar select[name=region] option", Region.all.size
    assert_select "#seed[value]"
    assert_select "tbody.entry", 20
    assert_select "tbody.entry .ledger__index", text: "1"
    assert_select "tr.entry__details[hidden]", 20
  end

  test "the same seed renders the same table" do
    get root_path(seed: "4242", region: "de-DE")
    first = css_select("button.entry__title").map(&:text)
    get root_path(seed: "4242", region: "de-DE")
    assert_equal first, css_select("button.entry__title").map(&:text)
  end

  test "table pages continue the numbering and link to their neighbours" do
    get root_path(seed: "7", page: 3)
    assert_select "tbody.entry .ledger__index", text: "41"
    assert_select "a[rel=prev][href*='page=2']"
    assert_select "a[rel=next][href*='page=4']"
    assert_select "a.export[href*='page=3']"
  end

  test "frame requests get only the catalog" do
    get root_path(seed: "7"), headers: { "Turbo-Frame" => "catalog" }
    assert_response :success
    assert_select "form#toolbar", 0
    assert_select "turbo-frame#catalog tbody.entry", 20
  end

  test "the gallery shows cards and a lazy frame for the next batch" do
    get root_path(seed: "7", view: "gallery")
    assert_select "article.card", 20
    assert_select "article.card video", 0
    assert_select "article.card details.card__audience:not([open])", 20
    assert_select "turbo-frame#batch-2[loading=lazy][src*='page=2']"
  end

  test "a gallery batch continues where the previous one stopped" do
    get gallery_batch_path(seed: "7", page: 2), headers: { "Turbo-Frame" => "batch-2" }
    assert_response :success
    assert_select "turbo-frame#batch-2 article.card", 20
    assert_select "article.card .card__index", text: "21"
    assert_select "turbo-frame#batch-3[loading=lazy]"
  end

  test "text seeds work" do
    get root_path(seed: "summer night")
    assert_response :success
    assert_select "#seed[value='summer night']"
  end
end
