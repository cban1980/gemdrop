# Artists: where C64 musicians and remixers come from, by MusicBrainz
# (musicbrainz.org, the open music database), remembered once found.
#
#   COUNTRY <artist>               an artist's country
#   COUNTRY SET <artist> <code>    (bot admins) set it by hand, e.g. COUNTRY SET Makke SE
#   COUNTRY UNSET <artist>         (bot admins) back to MusicBrainz's
#
# Other plugins ask country(name) (the remembered answer, or nil at once)
# and look_up(names) (finds them in the background), so their answers
# never wait for MusicBrainz. A name shared by several artists is settled
# by MusicBrainz's description and tags: the one described as C64, SID,
# demoscene, remix, chiptune or game music.
#
# MusicBrainz asks for at most one request a second and a user agent that
# says who is asking; both are kept, for all networks together.
#
# Install: bin/gemdrop-docker plugin install contrib/plugins/artists.rb
require "date"
require "json"
require "uri"

class Artists < Gemdrop::Plugin
  description "Where C64 musicians and remixers come from (MusicBrainz)"
  help_group "Music"

  API = "https://musicbrainz.org/ws/2/artist/"
  FOUND_DAYS = 180   # a country found is asked again after this long
  MISSING_DAYS = 30  # and a name not found after this long
  QUEUE = 500        # names waiting to be looked up
  # Names that are no one in particular ("Anonymous" would find someone).
  NOBODY = /\A(anonymous|unknown|various( artists)?|n\/?a|none|traditional|trad|\?+|-+)\z/i
  C64 = /\b(c64|c-64|commodore|sid|demo ?scene|remix(?:er)?|chip ?tune|chip ?music|game music|video game|8-?bit|tracker|amiga|scener)\b/i

  # ISO 3166 codes as names, for the countries C64 musicians come from.
  NAMES = {
    "AR" => "Argentina", "AT" => "Austria", "AU" => "Australia", "BE" => "Belgium", "BG" => "Bulgaria", "BR" => "Brazil",
    "BY" => "Belarus", "CA" => "Canada", "CH" => "Switzerland", "CL" => "Chile", "CN" => "China", "CZ" => "Czechia",
    "DE" => "Germany", "DK" => "Denmark", "EE" => "Estonia", "ES" => "Spain", "FI" => "Finland", "FR" => "France",
    "GB" => "United Kingdom", "GR" => "Greece", "HR" => "Croatia", "HU" => "Hungary", "IE" => "Ireland", "IL" => "Israel",
    "IN" => "India", "IS" => "Iceland", "IT" => "Italy", "JP" => "Japan", "KR" => "South Korea", "LT" => "Lithuania",
    "LU" => "Luxembourg", "LV" => "Latvia", "MX" => "Mexico", "NL" => "Netherlands", "NO" => "Norway",
    "NZ" => "New Zealand", "PL" => "Poland", "PT" => "Portugal", "RO" => "Romania", "RS" => "Serbia", "RU" => "Russia",
    "SE" => "Sweden", "SI" => "Slovenia", "SK" => "Slovakia", "TR" => "Turkey", "UA" => "Ukraine", "US" => "United States",
    "ZA" => "South Africa"
  }.freeze

  command "COUNTRY", usage: "COUNTRY <artist> | SET <artist> <code> | UNSET <artist>",
                     help: "where a C64 musician or remixer comes from", cooldown: 5,
                     details: "COUNTRY <artist>: the artist's country, from MusicBrainz or as set by a bot admin.\n" \
                              "COUNTRY SET <artist> <code> and UNSET <artist> (bot admins): set it by hand, " \
                              "with a two-letter code (SE, NO, GB ...)." do |ctx, args|
    ctx.usage! if args.empty?
    case args.first.upcase
    when "SET"
      raise Gemdrop::Error, "Only bot admins can set countries." unless ctx.admin?

      code = args.last.to_s.upcase
      name = args[1..-2].join(" ")
      ctx.usage! if name.strip.empty? || !code.match?(/\A[A-Z]{2}\z/)
      remember(name, "country" => code, "source" => "set by #{ctx.account}")
      ctx.reply_privately("#{name}: #{label(code)}, as set by you.")
    when "UNSET"
      raise Gemdrop::Error, "Only bot admins can set countries." unless ctx.admin?

      name = args.drop(1).join(" ")
      forget(name)
      ctx.reply_privately("#{name}: back to MusicBrainz's answer.")
    else
      name = ctx.text.strip
      known = entry(name)
      next ctx.reply(answer(name, known)) if known && !stale?(known)

      queued = background do
        ctx.reply(answer(name, find(name)))
      rescue Gemdrop::Error => e
        ctx.reply_privately("MusicBrainz: #{e.message}")
      end
      raise Gemdrop::Error, "Busy right now; try again in a moment." unless queued
    end
  end

  def setup
    @queue = []
    @queued = {}
    @working = false
    @lock = Mutex.new
    every(2) { work_queue }
  end

  # --- for other plugins -------------------------------------------------------------------------

  # The two-letter code remembered for name, or nil (never waits).
  def country(name)
    known = entry(name)
    known && known["country"]
  end

  # A name for a code ("SE" -> "Sweden"); the code if it isn't listed.
  def label(code) = code ? "#{NAMES.fetch(code, code)} (#{code})" : "unknown"

  def country_name(code) = NAMES.fetch(code, code)

  # Finds these names in the background, one a second, unless known.
  def look_up(names)
    @lock.synchronize do
      Array(names).compact.map(&:strip).reject(&:empty?).uniq.each do |name|
        key = fold(name)
        next if @queued[key] || @queue.size >= QUEUE || name.match?(NOBODY)

        known = entry(name)
        next if known && !stale?(known)

        @queued[key] = true
        @queue << name
      end
    end
  end

  # --- remembering ---------------------------------------------------------------------------------

  def fold(name) = name.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip

  def entry(name) = shared_data["artists"]&.dig(fold(name))

  def remember(name, fields)
    shared_data.update do |data|
      list = (data["artists"] ||= {})
      old = list[fold(name)] || {}
      next if old["source"].to_s.start_with?("set by") && !fields["source"].to_s.start_with?("set by")

      list[fold(name)] = { "name" => name, "checked" => Time.now.utc.strftime("%F") }.merge(fields)
    end
  end

  def forget(name) = shared_data.update { |data| data["artists"]&.delete(fold(name)) }

  def stale?(known)
    return false if known["source"].to_s.start_with?("set by")

    days = known["country"] ? FOUND_DAYS : MISSING_DAYS
    Date.parse(known["checked"].to_s) < Date.today - days
  rescue Date::Error
    true
  end

  # One worker goes through the queue, as fast as MusicBrainz allows.
  def work_queue
    start = @lock.synchronize { @queue.any? && !@working && (@working = true) }
    return unless start

    started = background do
      while (name = @lock.synchronize { @queue.first })
        begin
          find(name)
        rescue Gemdrop::Error => e
          log.debug("MusicBrainz, #{name}: #{e.message}")
        ensure
          @lock.synchronize do
            @queue.delete(name)
            @queued.delete(fold(name))
          end
        end
      end
    ensure
      @lock.synchronize { @working = false }
    end
    @lock.synchronize { @working = false } unless started
  end

  # --- MusicBrainz -----------------------------------------------------------------------------------

  # Looks name up, remembers what was found (or that nothing was), and
  # returns the entry.
  def find(name)
    return { "name" => name, "country" => nil } if name.strip.match?(NOBODY)

    known = entry(name)
    return known if known && (!stale?(known) || known["source"].to_s.start_with?("set by"))

    best = choose(name, search(name))
    fields = if best
               { "name" => best["name"], "country" => best["country"] || best.dig("area", "iso-3166-1-codes", 0),
                 "mbid" => best["id"], "source" => "MusicBrainz" }
             else
               { "country" => nil, "source" => "MusicBrainz" }
             end
    remember(name, fields)
    entry(name)
  end

  def search(name)
    wait_turn
    query = URI.encode_www_form("query" => %(artist:"#{name.delete('"')}"), "fmt" => "json", "limit" => 10)
    response = http_get("#{API}?#{query}", accept: "application/json", types: /json/)
    raise Gemdrop::Error, "it answered #{response.status}" unless response.status == 200

    JSON.parse(response.body.to_s)["artists"] || []
  rescue JSON::ParserError
    raise Gemdrop::Error, "its answer wasn't JSON"
  end

  # The artist among MusicBrainz's that is this name: an exact match (case,
  # spaces and punctuation aside, or an alias), the one described as a C64
  # musician if there are several. nil if none or still unclear.
  def choose(name, artists)
    wanted = fold(name)
    same = artists.select do |artist|
      fold(artist["name"]) == wanted || Array(artist["aliases"]).any? { |a| fold(a["name"]) == wanted }
    end
    return nil if same.empty?

    c64 = same.select { |artist| c64?(artist) }
    return c64.first if c64.size == 1
    return c64.max_by { |artist| artist["score"].to_i } if c64.size > 1 && c64.map { |a| a["country"] }.uniq.size == 1
    return same.first if same.size == 1

    nil
  end

  def c64?(artist)
    words = [artist["disambiguation"], *Array(artist["tags"]).map { |tag| tag["name"] }].compact.join(" ")
    words.match?(C64)
  end

  # One request a second to MusicBrainz, for every network's instance.
  def wait_turn
    loop do
      wait = shared.synchronize do |data|
        gap = (data["next_request"] || 0) - now
        data["next_request"] = now + 1.1 if gap <= 0
        gap
      end
      return if wait <= 0

      sleep(wait)
    end
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def answer(name, known)
    code = known && known["country"]
    return "#{name}: not found on MusicBrainz (or it has no country there)." unless code

    source = known["source"].to_s.start_with?("set by") ? "set by an admin" :
               "MusicBrainz: https://musicbrainz.org/artist/#{known['mbid']}"
    "#{known['name'] || name}: #{label(code)} · #{source}"
  end
end
