# Trailer videos and freeze frames. A file is rendered on its first request and reused afterwards;
# it depends only on region, seed and index, so responses are cached as immutable.
class MediaController < ApplicationController
  skip_forgery_protection only: :warm

  TYPES = { "mp4" => "video/mp4", "jpg" => "image/jpeg" }.freeze

  def show
    movie = find_movie or return head(:not_found)
    path = params[:format] == "mp4" ? Trailer::Studio.trailer(movie) : Trailer::Studio.poster(movie)
    response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    send_media(path.to_s, TYPES.fetch(params[:format]))
  rescue Trailer::Renderer::Error => e
    logger.error(e.message)
    head :service_unavailable
  end

  # Called when a table row opens: rendering starts before anyone presses play.
  def warm
    movie = find_movie or return head(:not_found)
    Trailer::Studio.warm(movie)
    head :accepted
  end

  private

  def find_movie
    region = Region.find(params[:region])
    seed = SeedStream.parse(params[:seed])
    index = params[:index].to_i
    return unless region && seed && index.positive?

    MovieFactory.new(region: region, seed: seed, index: index).build
  end

  # Range requests matter for video: Safari will not play a file from a server that ignores them.
  def send_media(path, type)
    size = File.size(path)
    response.headers["Accept-Ranges"] = "bytes"
    ranges = Rack::Utils.get_byte_ranges(request.headers["Range"], size)
    if ranges.nil? || ranges.size > 1
      send_file path, type: type, disposition: "inline"
    elsif ranges.empty?
      response.headers["Content-Range"] = "bytes */#{size}"
      head :range_not_satisfiable
    else
      range = ranges.first
      response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{size}"
      send_data File.binread(path, range.size, range.begin), type: type, disposition: "inline", status: :partial_content
    end
  end
end
