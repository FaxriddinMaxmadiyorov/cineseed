require "test_helper"

class ExportsControllerTest < ActionDispatch::IntegrationTest
  test "the export is a ZIP of the page's trailers named after the movies" do
    sample = file_fixture("sample.mp4").to_s
    Trailer::Studio.stub(:trailer, ->(_movie) { sample }) do
      get export_path(region: "de-DE", seed: 555, page: 2)
    end
    assert_response :success
    assert_equal "application/zip", response.media_type
    names = zip_names(response.body)
    expected = Catalog.new(region: Region.find("de-DE"), seed: 555).page(2).map { |m| m.file_name("mp4") }
    assert_equal 20, names.size
    assert_equal expected.uniq.size, names.uniq.size
    expected.each { |name| assert names.any? { |n| n.start_with?(name.delete_suffix(".mp4")) }, name }
  end

  private

  # Reads the central directory with plain Ruby (no zip gem in the bundle).
  def zip_names(data)
    eocd = data.rindex("PK\x05\x06".b)
    count = data[eocd + 10, 2].unpack1("v")
    offset = data[eocd + 16, 4].unpack1("V")
    Array.new(count) do
      length = data[offset + 28, 2].unpack1("v")
      extra = data[offset + 30, 2].unpack1("v")
      comment = data[offset + 32, 2].unpack1("v")
      name = data[offset + 46, length].force_encoding("UTF-8")
      offset += 46 + length + extra + comment
      name
    end
  end
end
