Rails.application.routes.draw do
  # The store: toolbar plus the first table page or gallery batch, rendered with the first response.
  root "catalog#index"

  # Next gallery batch, requested by the lazy turbo-frame at the end of the previous batch.
  get "batch" => "catalog#batch", as: :gallery_batch

  # Trailer video and freeze frame of one record. They depend only on region, seed and index, so the
  # URLs are immutable and cached for good.
  scope "media/:region/:seed", constraints: { region: /[a-z]{2,3}(-[A-Za-z0-9]{2,8})*/i, seed: /\d{1,20}/, index: /\d+/ } do
    get ":index.:format" => "media#show", as: :media, constraints: { format: /mp4|jpg/ }
    post ":index/warm" => "media#warm", as: :warm_media
  end

  # ZIP with the trailers of one table page, each file named after its movie.
  get "export" => "exports#show", as: :export

  get "up" => "rails/health#show", as: :rails_health_check
end
