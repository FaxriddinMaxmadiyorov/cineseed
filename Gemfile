source "https://rubygems.org"

ruby ">= 3.3.0"

gem "rails", "~> 8.1.4"
# Modern asset pipeline + JS without a bundler step
gem "propshaft"
gem "importmap-rails"
# Hotwire: Turbo Frames give us partial page updates and lazy-loaded infinite scrolling,
# Stimulus wires the toolbar, row expansion and trailer playback.
gem "turbo-rails"
gem "stimulus-rails"
gem "puma", ">= 5.0"

# Fake data generation (names, cities, usernames) + our own locale datasets loaded through Faker's I18n API
gem "faker", "~> 3.8"
# Streaming ZIP archives for the trailer export
gem "zip_kit", "~> 6.4"

gem "tzinfo-data", platforms: %i[ windows jruby ]

group :development, :test do
  # Minitest 6 moved `minitest/mock` (used for stubs in the tests) out into a separate gem
  gem "minitest", "< 6"
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
end
