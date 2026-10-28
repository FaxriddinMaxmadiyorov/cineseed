# The store page. Everything shown is generated in memory from the request parameters: region,
# seed, likes and reviews averages, view (table or gallery) and page. Nothing is stored.
class CatalogController < ApplicationController
  before_action :load_catalog

  # Full page on the first visit. Parameter changes and table pagination come back as requests for
  # the "catalog" turbo-frame and get the same template without the layout.
  def index
    @page = page_param
    @movies = @catalog.page(@page)
  end

  # One gallery batch, requested by the lazy frame that ends the previous batch.
  def batch
    @page = page_param
    @movies = @catalog.page(@page)
    render partial: "catalog/batch", locals: { movies: @movies, page: @page }
  end

  private

  def load_catalog
    # No seed in the URL (a fresh visit): start from a random one so the store opens with data.
    @seed_text = params[:seed].to_s.strip.first(200).presence || SeedStream.random_seed.to_s
    @catalog = Catalog.from_params(params, seed: SeedStream.parse(@seed_text))
    @view = params[:view] == "gallery" ? "gallery" : "table"
  end

  # No upper limit: page numbers are plain integers, however far someone pages or scrolls.
  def page_param = [params[:page].to_i, 1].max
end
