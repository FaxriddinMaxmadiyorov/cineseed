require "test_helper"

# These tests run ffmpeg for real.
class MediaControllerTest < ActionDispatch::IntegrationTest
  test "the freeze frame is a JPEG of the trailer's hero shot with the title" do
    get media_path(region: "en-US", seed: 31_337, index: 3, format: :jpg)
    assert_response :success
    assert_equal "image/jpeg", response.media_type
    assert_equal "\xFF\xD8".b, response.body.b[0, 2]
    assert_match(/immutable/, response.headers["Cache-Control"])
  end

  test "trailers are mp4 videos that support range requests" do
    get media_path(region: "uk-UA", seed: 31_337, index: 4, format: :mp4), headers: { "Range" => "bytes=0-99" }
    assert_response :partial_content
    assert_equal "video/mp4", response.media_type
    assert_equal 100, response.body.bytesize
    assert_equal "ftyp", response.body[4, 4]
    path = Trailer::Studio.path_for(MovieFactory.new(region: Region.find("uk-UA"), seed: 31_337, index: 4).build, "mp4")
    probe = JSON.parse(`ffprobe -v error -show_entries format=duration:stream=codec_type,width,height -of json #{path}`)
    assert_includes 5.0..10.0, probe.dig("format", "duration").to_f
    assert_equal %w[audio video], probe["streams"].map { |s| s["codec_type"] }.sort
  end

  test "unknown regions and bad indexes are not found" do
    get "/media/xx-XX/1/1.jpg"
    assert_response :not_found
    get "/media/en-US/1/0.jpg"
    assert_response :not_found
  end

  test "warming up a trailer answers at once" do
    Trailer::Studio.stub(:warm, true) do
      post warm_media_path(region: "en-US", seed: 1, index: 1)
    end
    assert_response :accepted
  end
end
