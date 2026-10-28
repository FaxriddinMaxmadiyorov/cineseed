# Cineseed

A movie store showcase that generates its whole catalog from a seed: titles, cast, genres, series with seasons, likes, reviews, and a playable trailer with sound for every title. Nothing is stored. The same region and seed give the same catalog on any machine on any day.

Built with Ruby on Rails 8.1, Hotwire (Turbo and Stimulus), Faker, zip_kit and FFmpeg.

## What you can do

The toolbar holds the generation parameters in one row: region (English USA, German, Ukrainian), seed (any number up to 64 bits, or any text, plus a button for a random one), average likes and average reviews per movie (0 to 10, fractions allowed), and the view. Every change applies as you type or slide. Changing anything sends the table back to page 1 and the gallery back to the top.

- **Table view** with pagination. Clicking a row opens it in place: the freeze frame of the trailer with the title rendered on it, a play button, director, cast, rating, runtime or seasons, likes and reviews. Clicking again closes it.
- **Gallery view** with infinite scroll. Each card has the freeze frame and plays its trailer inline; likes and reviews open on request.
- **Export**: the table footer downloads a ZIP with the 20 trailers of the current page, each file named after its movie.
- **Series**: about a fifth of the titles are series with several seasons.

## How the data is generated

All generation runs on the server, in memory.

- **Faker, extended through its own API.** `Faker::MovieStore` is a `Faker::Base` generator whose data lives in locale files, one per region: `config/regions/en-US.yml`, `de-DE.yml`, `uk-UA.yml`. Names, cities and the like come from Faker's built-in locales. The code holds no region specific words; adding a region means adding a YAML file, and it shows up in the selector.
- **Titles** come from a small grammar engine (`lib/cineseed/title_composer.rb`). Patterns such as `{art.def@x} {adj.weak@x} {noun:x}` pick nouns and adjectives that agree in gender, number and case, so German declension and Ukrainian adjective endings are just data. Genre tags steer the vocabulary: a horror film gets different words than a family comedy.
- **Seeds.** The page seed is a multiply-add of the user seed and the page number (`app/models/seed_stream.rb`). Each record then derives independent random streams from the page seed with SHA-256: one for the core data, one for likes, one for the number of reviews, one per review and one for the trailer. That is why moving the likes slider only changes like counts, and raising the reviews average only appends reviews.
- **Fractional averages.** A record gets `floor(avg)` items, plus one more with probability equal to the fraction. With 0.5 half the movies have one like and half have none; with 10 every movie has ten.

## How the trailers are made

Trailers are real video with real sound, cut from a library of openly licensed footage and music. See [CREDITS.md](CREDITS.md) for every source.

- **Footage**: 288 shots cut by scene detection from 41 videos, in four visual worlds (Blender open movies, live action and nature footage, NASA launches, archival newsreels). A trailer never mixes worlds. Shots carry genre and mood tags. `bin/rails footage:build` rebuilds the library from `footage/sources.yml`.
- **Music and sound**: 125 eleven-second excerpts from 63 game soundtracks, analysed for tempo, beats and energy, plus 38 sound effects (impacts, risers, whooshes, thunder, heartbeats). `script/build_audio_library.py` rebuilds them from `audio/sources.yml`.
- **Direction** (`app/models/trailer/director.rb`): every decision comes from the record's trailer seed. The director picks a structure (classic, hooks, cold open, star billing, montage or teaser), cuts shots to the beat grid of the chosen music, lands the title card on a downbeat with an impact sound, and picks footage, playback speed, push in, pull out or drift, transitions, one of 15 color grades, fonts and one of 16 typographic animations, all weighted by genre (`config/trailer/genres.yml`). Text cards ("THIS SUMMER", star names, "FROM THE DIRECTOR OF...") come from the region file, in the region's language.
- **Rendering** (`app/models/trailer/renderer.rb`): one FFmpeg filter graph per trailer retimes, reframes, grades and grains the shots, letterboxes them, joins them with transitions, draws the typography with libass and mixes the ducked music with the effects. Output is 854x480 H.264 with AAC audio, 7 to 10 seconds long.
- **Caching**: a trailer is rendered on its first request (about 5 seconds on two cores) and kept in `tmp/trailers`. Rendering is deterministic, so the cache is only a cache. Opening a table row starts rendering in the background, so the video is usually ready by the time you press play. The freeze frame is the trailer's hero shot with the title card on it and takes a fraction of a second.

## Running it

With Docker:

```sh
docker build -t cineseed .
docker run -p 3000:3000 cineseed
```

Then open http://localhost:3000.

Without Docker you need Ruby 3.3 and FFmpeg built with libass and libx264 (the standard Debian, Ubuntu and Homebrew packages are).

```sh
bundle install
bin/rails server
```

Tests (they render one real trailer and one freeze frame, so FFmpeg is needed):

```sh
bin/rails test
```

## Deploying

Any host that runs a Docker image works (Render, Fly.io, Railway, a VPS). Useful settings:

| Variable | Default | Meaning |
|---|---|---|
| `FORCE_SSL`, `ASSUME_SSL` | off | Set to `true` behind an HTTPS proxy. |
| `SECRET_KEY_BASE` | generated | Only signs the session cookie; the image creates one if it is missing. |
| `TRAILER_CONCURRENCY` | 2 | Trailers rendered at the same time. Roughly one per CPU core. |
| `POSTER_CONCURRENCY` | 3 | Freeze frames rendered at the same time. |
| `TRAILER_CACHE_FILES` | 3000 | Rendered files kept before the oldest are removed. |
| `RAILS_MAX_THREADS` | 10 | Puma threads. Requests mostly wait on FFmpeg, so more threads than cores is fine. |

A persistent volume on `/rails/tmp/trailers` keeps rendered trailers across restarts, but nothing breaks without one.

## Where things are

| Path | What |
|---|---|
| `app/controllers` | Catalog pages and gallery batches, media (video, freeze frame), ZIP export |
| `app/models/catalog.rb`, `movie_factory.rb`, `seed_stream.rb` | Seeded generation of records |
| `lib/faker/movie_store.rb`, `lib/cineseed/title_composer.rb` | Faker extension and the title grammar |
| `config/regions/*.yml` | Everything region specific: vocabulary, genres, ratings, reviews, trailer copy |
| `app/models/trailer/*` | Trailer direction, typography, rendering and caching |
| `config/trailer/*.yml` | Genre styles, color grades, font metrics |
| `footage/`, `audio/`, `vendor/fonts/` | The media library and the fonts used in trailers |
| `app/views/catalog`, `app/javascript/controllers` | Table, gallery, toolbar, row and player behaviour |
