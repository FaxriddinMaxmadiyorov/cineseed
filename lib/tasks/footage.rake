namespace :footage do
  desc "Download sources and build the shot library (footage/manifest.json). ONLY=id1,id2 JOBS=2"
  task build: :environment do
    Cineseed::Footage::Builder.new(
      root: Rails.root.join("footage"),
      only: ENV.fetch("ONLY", "").split(","),
      jobs: ENV.fetch("JOBS", "2").to_i
    ).run!
  end

  desc "Render a contact sheet of every shot to tmp/footage_contact.jpg (needs ImageMagick montage)"
  task contact_sheet: :environment do
    manifest = JSON.parse(Rails.root.join("footage/manifest.json").read)
    clips = manifest["clips"]
    clips = clips.select { |c| ENV["ONLY"].split(",").include?(c["source"]) } if ENV["ONLY"]
    out = Rails.root.join("tmp/footage_contact.jpg")
    args = clips.flat_map { |c| ["-label", "#{c['id']} L#{c['luma'].round} W#{c['warmth'].round} M#{(c['motion'] * 100).round(1)}", Rails.root.join("footage", c["still"]).to_s] }
    system("montage", *args, "-tile", "10x", "-geometry", "180x101+2+2", "-pointsize", "9", "-background", "#222", "-fill", "white", out.to_s, exception: true)
    puts out
  end
end
