# Streams a ZIP with the trailers of one table page, each file named after its movie. Trailers that
# are not cached yet are rendered in parallel (bounded by Trailer::Studio) while the archive streams.
class ExportsController < ApplicationController
  include ZipKit::RailsStreaming

  def show
    catalog = Catalog.from_params(params)
    page = [params[:page].to_i, 1].max
    movies = catalog.indexes(page).map { |i| MovieFactory.new(region: catalog.region, seed: catalog.seed, index: i).build }
    renders = movies.map do |movie|
      Concurrent::Promises.future { Rails.application.executor.wrap { Trailer::Studio.trailer(movie) } }
    end
    names = unique_names(movies)

    zip_kit_stream(filename: "trailers-#{catalog.region.code}-#{catalog.seed}-page-#{page}.zip") do |zip|
      movies.each_index do |i|
        path = renders[i].value!
        # mp4 is already compressed: store the files as they are
        zip.write_stored_file(names[i]) { |sink| File.open(path, "rb") { |file| IO.copy_stream(file, sink) } }
      end
    end
  end

  private

  def unique_names(movies)
    seen = Hash.new(0)
    movies.map do |movie|
      name = movie.file_name("mp4")
      seen[name] += 1
      seen[name] == 1 ? name : name.sub(/\.mp4\z/, " (#{seen[name]}).mp4")
    end
  end
end
