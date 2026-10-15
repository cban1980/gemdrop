# SLAY Radio and C64 remixes, in one plugin: what SLAY Radio
# (slayradio.org) is playing, as a remix of a C64 tune; remixes on
# Remix.Kwed.Org (RKO); a log of everything the station plays; and where
# the musicians come from (MusicBrainz). Every answer is one line.
#
#   SLAY [NOW]                        the remix on air: the C64 tune it remixes, whose, its RKO page
#   SLAY OTHERS                       the station's other remixes of that tune
#   SLAY LAST                         the last few played
#   SLAY PLAYED <words>               when songs matching were played (this log)
#   SLAY TOP [day|week|month|all]     the most played songs and artists (this log)
#   SLAY INFO <words|#number>         a song's history on SLAY Radio
#   SLAY COUNTRIES [day|week|month|all]  where the artists played come from (this log)
#   SLAY REMIX                        RKO's remixes of the C64 tune on air
#   SLAY REMIX <words>                the best-rated remixes matching (title, arranger or composer)
#   SLAY REMIX NEW [words] | TOP [week|month|alltime] | RANDOM [words] | ID <number|link>
#   SLAY COUNTRY <artist>             where a musician comes from; SET/UNSET (bot admins)
#
# One command, SLAY (!slay), for all of it.
#
# No NP: in #SLAYRadio, [S], the station's own bot, answers !np.
#
# The station's Recently Played page lists the last 30 plays (about two
# hours), so the first network's instance reads it every few minutes
# (poll_seconds) and adds new plays to plays-<year>.jsonl in its data
# folder (data/plugins/<first network>/slayradio/); every network's
# instance reads that log (it is told where, through shared). The
# station's times are Swedish; the log keeps them in UTC as well.
#
# Only the sites' normal pages are read (and MusicBrainz's API, at most once
# a second for all networks), with the bot's own user agent, and kept for a
# while (docs/slayradio.md).
#
# Install: bin/gemdrop-docker plugin install contrib/plugins/slayradio.rb
require "cgi"
require "date"
require "json"
require "time"
require "uri"

class Slayradio < Gemdrop::Plugin
  description "SLAY Radio and C64 remixes: what is on as a remix, RKO, a play log, where musicians come from"
  help_group "Music"

  setting "poll_seconds", default: 180, type: :integer, min: 60, max: 1800,
                          desc: "how often slayradio.org's Recently Played page is read"
  setting "announce", default: [], type: :list,
                      desc: "channels where each new song is said (off by default)"
  setting "results", default: 3, type: :integer, min: 1, max: 5, channel: true,
                     desc: "songs or remixes in an answer, as many as fit in its one line"
  setting "title_length", default: 70, type: :integer, min: 20, max: 200, channel: true
  setting "per_channel_per_minute", default: 6, type: :integer, min: 1, max: 60, channel: true
  setting "cache_minutes", default: 10, type: :integer, min: 0, max: 1440,
                           desc: "how long a page of Remix.Kwed.Org is kept"

  SITE = "https://www.slayradio.org"
  HISTORY = "#{SITE}/pages/song_history.php"
  SONG = "#{SITE}/pages/song_info.php?song_id=%d"
  LIVE_ID = 1935 # "SLAY Radio - SLAY Radio Live": a live show, which lists no songs
  PERIODS = { "day" => 86_400, "week" => 7 * 86_400, "month" => 30 * 86_400, "all" => nil }.freeze
  PAGE_SECONDS = 60      # a fetched Recently Played page is kept this long
  SONG_SECONDS = 3600    # and a song's page this long
  MAX_LINE = 400         # bytes: what IRC's 512 leaves after the bot's own prefix and the target
  PLURALS = { "song" => "songs", "play" => "plays", "vote" => "votes", "request" => "requests", "remix" => "remixes",
              "country" => "countries", "other remix" => "other remixes", "download" => "downloads" }.freeze

  # One play, as the log keeps it.
  Play = Struct.new(:at, :local, :artist, :title, :song, :length, keyword_init: true) do
    def name = "#{artist} – #{title}"
    def live? = song == LIVE_ID || length.to_s.start_with?("-")
    def seconds = length.to_s.match?(/\A\d+:\d\d\z/) ? length.split(":").then { |m, s| (m.to_i * 60) + s.to_i } : nil
    def to_json(*) = to_h.compact.to_json(*)
  end

  # Remix.Kwed.Org (remix.kwed.org): searching, its lists and one remix.
  class Rko
    SITE = "https://remix.kwed.org"
    PER_PAGE = 50
    MAX_QUERY = 30 # RKO's search field takes 30 characters
    CHARTS = %w[week month alltime].freeze
    CACHE_SIZE = 100
    FALLBACK_PAGES = 3

    # One remix, as a row of RKO's tables shows it.
    Row = Struct.new(:id, :date, :title, :arranger, :composer, :rating, :size, :length, :downloads, :sid,
                     keyword_init: true)

    def initialize(plugin)
      @plugin = plugin
      @cache = {}
      @lock = Mutex.new
    end

    def search_url(words) = "#{SITE}/search/#{URI.encode_www_form_component(words)}"
    def remix_url(id) = "#{SITE}/remix/#{id}"

    # One page of a list: { rows:, pages: }. view: rating or date; chart:
    # week, month or alltime; search: words.
    def page(view: nil, chart: "", search: nil, number: 1)
      query = { "page" => number, "chart" => chart }
      query["view"] = view if view
      query["search"] = search if search
      parse_list(fetch("#{SITE}/?#{URI.encode_www_form(query)}"))
    end

    # RKO matches the words as one phrase, punctuation and all ("Ghosts'n
    # Goblins" is stored escaped, "Glyn R Brown" has no dot). So: the words
    # as typed; else without punctuation; else the longest word's results,
    # kept where every word is in the title, arranger or composer. Returns
    # rows (best first by view), the query that found them, and with count:
    # the total (at_least when there were more pages than were read).
    def find(words, view:, count: false)
      tried = []
      [words, Slayradio.normalize(words)].uniq.each do |query|
        next if query.empty? || tried.include?(query.downcase)

        tried << query.downcase
        first = page(view: view, search: query)
        next if first[:rows].empty?

        return { rows: first[:rows], query: query, pages: first[:pages],
                 total: count ? total(first, view: view, search: query) : nil }
      end
      narrowed(Slayradio.normalize(words).split, view, tried)
    end

    def narrowed(wanted, view, tried)
      key = wanted.max_by(&:length)
      none = { rows: [], query: nil, pages: 0, total: 0 }
      return none if wanted.size < 2 || key.length < 3 || tried.include?(key)

      first = page(view: view, search: key)
      rows = first[:rows].dup
      (2..[first[:pages], FALLBACK_PAGES].min).each { |n| rows.concat(page(view: view, search: key, number: n)[:rows]) }
      rows.select! { |row| all_words?(row, wanted) }
      { rows: rows, query: key, pages: 1, total: rows.size, at_least: first[:pages] > FALLBACK_PAGES && rows.any? }
    end

    def all_words?(row, wanted)
      hay = Slayradio.normalize([row.title, row.arranger, row.composer].compact.join(" "))
      tokens = hay.split
      wanted.all? { |word| word.length <= 2 ? tokens.include?(word) : hay.include?(word) }
    end

    # How many a search found: PER_PAGE a page, and what the last page has.
    def total(first, **list)
      return first[:rows].size if first[:pages] <= 1

      last = page(**list, number: first[:pages])
      (PER_PAGE * (first[:pages] - 1)) + last[:rows].size
    end

    def random_matching(words)
      found = find(words, view: "rating")
      return nil if found[:rows].empty?

      number = rand(1..found[:pages])
      rows = number == 1 ? found[:rows] : page(view: "rating", search: found[:query], number: number)[:rows]
      rows.sample || found[:rows].sample
    end

    # Remixes are numbered; a few numbers are gone, so a few tries.
    def random_any
      newest = page(view: "date")[:rows].map(&:id).max or return nil
      4.times do
        row = remix(rand(1..newest))
        return row if row
      end
      nil
    end

    def remix(id) = parse_list(fetch(remix_url(id)))[:rows].find { |row| row.id == id }

    def chart(period) = parse_chart(fetch("#{SITE}/?#{URI.encode_www_form('page' => 1, 'chart' => period, 'view' => 'date')}"))

    def fetch(url)
      ttl = @plugin.settings["cache_minutes"] * 60
      hit = @lock.synchronize { @cache[url] }
      return hit[0] if hit && hit[1] > Slayradio.now

      response = @plugin.http_get(url, accept: "text/html", types: /html/)
      raise Gemdrop::Error, "Remix.Kwed.Org answered #{response.status}; try again later." unless response.status == 200

      body = response.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      if ttl.positive?
        @lock.synchronize do
          @cache[url] = [body, Slayradio.now + ttl]
          @cache.delete(@cache.keys.first) while @cache.size > CACHE_SIZE
        end
      end
      body
    end

    # The remixes in a page of RKO's tables, and how many pages the list has.
    def parse_list(html)
      rows = html.scan(%r{<tr[^>]*>(.*?)</tr>}m).filter_map { |(row)| parse_row(row) }
      pages = html.scan(/[?&;]page=(\d+)/).flatten.map(&:to_i).max || 1
      { rows: rows, pages: [pages, 1].max }
    end

    # RKO's "What's popular?" box: rank, the title (the download link, with
    # size, length and downloads) and the arranger, the rating. Single quotes.
    def parse_chart(html)
      box = html[/Begin: Chart body(.*?)<\/tbody>/m, 1] or return []
      box.scan(%r{<tr[^>]*>(.*?)</tr>}m).filter_map do |(cells)|
        link = cells.match(%r{<a[^>]*title=['"]([^'"]*)['"][^>]*href=['"]/download\.php/(\d+)/[^'"]*['"][^>]*>(.*?)</a>(?:<br\s*/?>)?([^<]*)}m)
        next unless link

        size, length, downloads = link[1].split(" / ").map(&:strip)
        Row.new(id: link[2].to_i, title: Slayradio.text(link[3]), arranger: Slayradio.text(link[4]),
                rating: cells[/class=['"]vote['"][^>]*title=['"]([^'"]*)['"]/, 1]&.then { |r| CGI.unescapeHTML(r) },
                size: size.to_s.empty? ? nil : size.sub(/\s*Mb\z/i, " MB"), length: length&.sub(/\s*minutes?\z/, ""),
                downloads: downloads&.[](/\d+/)&.to_i)
      end
    end

    # Cells: date (with the permalink), title (the download link, with size,
    # length and downloads in its title), arranger, composer, icons (rating,
    # the original SID on DeepSID).
    def parse_row(html)
      id = html[%r{href="/remix/(\d+)"}, 1] or return nil
      cells = html.scan(%r{<td[^>]*>(.*?)</td>}m).flatten
      return nil if cells.size < 4

      info = html[/title="([^"]*)"[^>]*class="download"/, 1] || html[/class="download"[^>]*title="([^"]*)"/, 1]
      size, length, downloads = info.to_s.split(" / ").map(&:strip)
      Row.new(id: id.to_i, date: iso_date(Slayradio.text(cells[0])), title: Slayradio.text(cells[1]),
              arranger: Slayradio.text(cells[2]), composer: Slayradio.text(cells[3]).then { |c| c.empty? ? nil : c },
              rating: html[/class="vote"[^>]*title="([^"]*)"/, 1]&.then { |r| CGI.unescapeHTML(r) },
              size: size.to_s.empty? ? nil : size.sub(/\s*Mb\z/i, " MB"),
              length: length&.sub(/\s*minutes?\z/, ""),
              downloads: downloads&.[](/\d+/)&.to_i,
              sid: html[/class="sid"[^>]*href="([^"]+)"/, 1]&.then { |u| CGI.unescapeHTML(u) })
    end

    # RKO writes dates as dd/mm/yy.
    def iso_date(text)
      match = text.match(%r{\A(\d\d)/(\d\d)/(\d\d)\z}) or return nil
      "20#{match[3]}-#{match[2]}-#{match[1]}"
    end
  end

  # Where musicians come from, by MusicBrainz (musicbrainz.org), remembered
  # in the plugin's shared data. country(name) answers at once from what is
  # remembered; look_up(names) finds names in the background, one a second
  # for every network together, as MusicBrainz asks. A name shared by
  # several artists is settled by MusicBrainz's description and tags: the
  # one described as C64, SID, demoscene, remix, chiptune or game music.
  class Countries
    API = "https://musicbrainz.org/ws/2/artist/"
    FOUND_DAYS = 180   # a country found is asked again after this long
    MISSING_DAYS = 30  # and a name not found after this long
    QUEUE = 500        # names waiting to be looked up
    # Names that are no one in particular ("Anonymous" would find someone).
    NOBODY = /\A(anonymous|unknown|various( artists)?|n\/?a|none|traditional|trad|\?+|-+)\z/i
    C64 = /\b(c64|c-64|commodore|sid|demo ?scene|remix(?:er)?|chip ?tune|chip ?music|game music|video game|8-?bit|tracker|amiga|scener)\b/i

    # ISO 3166 codes as names, for the countries C64 musicians come from.
    NAMES = {
      "AR" => "Argentina", "AT" => "Austria", "AU" => "Australia", "BE" => "Belgium", "BG" => "Bulgaria",
      "BR" => "Brazil", "BY" => "Belarus", "CA" => "Canada", "CH" => "Switzerland", "CL" => "Chile", "CN" => "China",
      "CZ" => "Czechia", "DE" => "Germany", "DK" => "Denmark", "EE" => "Estonia", "ES" => "Spain", "FI" => "Finland",
      "FR" => "France", "GB" => "United Kingdom", "GR" => "Greece", "HR" => "Croatia", "HU" => "Hungary",
      "IE" => "Ireland", "IL" => "Israel", "IN" => "India", "IS" => "Iceland", "IT" => "Italy", "JP" => "Japan",
      "KR" => "South Korea", "LT" => "Lithuania", "LU" => "Luxembourg", "LV" => "Latvia", "MX" => "Mexico",
      "NL" => "Netherlands", "NO" => "Norway", "NZ" => "New Zealand", "PL" => "Poland", "PT" => "Portugal",
      "RO" => "Romania", "RS" => "Serbia", "RU" => "Russia", "SE" => "Sweden", "SI" => "Slovenia", "SK" => "Slovakia",
      "TR" => "Turkey", "UA" => "Ukraine", "US" => "United States", "ZA" => "South Africa"
    }.freeze

    def initialize(plugin)
      @plugin = plugin
      @queue = []
      @queued = {}
      @working = false
      @lock = Mutex.new
    end

    # The two-letter code remembered for name, or nil (never waits).
    def country(name)
      known = entry(name)
      known && known["country"]
    end

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

    def queue = @lock.synchronize { @queue.dup }

    def fold(name) = Slayradio.normalize(name)

    def entry(name) = @plugin.shared_data["artists"]&.dig(fold(name))

    def remember(name, fields)
      @plugin.shared_data.update do |data|
        list = (data["artists"] ||= {})
        old = list[fold(name)] || {}
        next if old["source"].to_s.start_with?("set by") && !fields["source"].to_s.start_with?("set by")

        list[fold(name)] = { "name" => name, "checked" => Time.now.utc.strftime("%F") }.merge(fields)
      end
    end

    def forget(name) = @plugin.shared_data.update { |data| data["artists"]&.delete(fold(name)) }

    def stale?(known)
      return false if known["source"].to_s.start_with?("set by")

      days = known["country"] ? FOUND_DAYS : MISSING_DAYS
      Date.parse(known["checked"].to_s) < Date.today - days
    rescue Date::Error
      true
    end

    # One worker goes through the queue, as fast as MusicBrainz allows.
    # (The plugin runs background blocks as itself, hence the local.)
    def work
      start = @lock.synchronize { @queue.any? && !@working && (@working = true) }
      return unless start

      me = self
      started = @plugin.background { me.drain }
      @lock.synchronize { @working = false } unless started
    end

    def drain
      while (name = @lock.synchronize { @queue.first })
        begin
          find(name)
        rescue Gemdrop::Error => e
          @plugin.log.debug("MusicBrainz, #{name}: #{e.message}")
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
      response = @plugin.http_get("#{API}?#{query}", accept: "application/json", types: /json/)
      raise Gemdrop::Error, "MusicBrainz answered #{response.status}" unless response.status == 200

      JSON.parse(response.body.to_s)["artists"] || []
    rescue JSON::ParserError
      raise Gemdrop::Error, "MusicBrainz's answer wasn't JSON"
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
        wait = @plugin.shared.synchronize do |data|
          gap = (data["next_request"] || 0) - Slayradio.now
          data["next_request"] = Slayradio.now + 1.1 if gap <= 0
          gap
        end
        return if wait <= 0

        sleep(wait)
      end
    end

    def answer(name, known)
      code = known && known["country"]
      return "#{name}: not found on MusicBrainz (or it has no country there)." unless code

      source = known["source"].to_s.start_with?("set by") ? "set by an admin" :
                 "MusicBrainz: https://musicbrainz.org/artist/#{known['mbid']}"
      "#{known['name'] || name}: #{label(code)} · #{source}"
    end
  end

  # --- commands ------------------------------------------------------------------------------------

  # Everything is a SLAY subcommand: one command, !slay, in #SLAYRadio.
  command "SLAY", usage: "SLAY [NOW] | OTHERS | LAST | PLAYED <words> | TOP [day|week|month|all] | INFO <words|#number> | " \
                         "COUNTRIES [period] | REMIX [words|NEW|TOP|RANDOM|ID ...] | COUNTRY <artist>",
                  help: "SLAY Radio and C64 remixes: what is on, remixes on Remix.Kwed.Org, what was played",
                  cooldown: 5,
                  details: "SLAY: the remix on air, the C64 tune it remixes and whose, its page on Remix.Kwed.Org.\n" \
                           "SLAY OTHERS: the station's other remixes of that tune.\n" \
                           "SLAY REMIX: Remix.Kwed.Org's remixes of the tune on air. SLAY REMIX <words>: search it.\n" \
                           "SLAY REMIX NEW [words] | TOP [week|month|alltime] | RANDOM [words] | ID <number|link>.\n" \
                           "SLAY LAST | PLAYED <words> | TOP [day|week|month|all] | INFO <words|#number>: what was played.\n" \
                           "SLAY COUNTRIES [day|week|month|all]: where the artists played come from.\n" \
                           "SLAY COUNTRY <artist>: where a musician comes from (bot admins: SET <artist> <code>, " \
                           "UNSET <artist>)." do |ctx, args|
    rest = args.drop(1)
    words = rest.join(" ")
    sub = args.first.to_s.upcase
    limit!(ctx) unless sub == "COUNTRY" && %w[SET UNSET].include?(rest.first.to_s.upcase)
    case sub
    when "", "NOW", "NP" then job(ctx) { now_playing(ctx) }
    when "OTHERS", "MORE" then job(ctx) { others(ctx) }
    when "LAST" then job(ctx) { last(ctx) }
    when "PLAYED"
      ctx.usage! if words.strip.empty?
      job(ctx) { played(ctx, words) }
    when "TOP"
      job(ctx) { top(ctx, period!(words)) }
    when "INFO"
      ctx.usage! if words.strip.empty?
      job(ctx) { info(ctx, words) }
    when "COUNTRIES" then job(ctx) { by_country(ctx, period!(words)) }
    when "REMIX", "REMIXES" then remix_command(ctx, rest)
    when "COUNTRY" then country_command(ctx, rest)
    else ctx.usage!
    end
  end

  # SLAY REMIX ...: Remix.Kwed.Org.
  def remix_command(ctx, args)
    words = args.drop(1).join(" ")
    case args.first.to_s.upcase
    when "" then job(ctx) { remixes_on_air(ctx) }
    when "NEW" then check_query!(words) && job(ctx) { newest(ctx, words) }
    when "RANDOM" then check_query!(words) && job(ctx) { random(ctx, words) }
    when "TOP"
      period = words.empty? ? "week" : words.downcase
      raise Gemdrop::Error, "SLAY REMIX TOP takes week, month or alltime." unless Rko::CHARTS.include?(period)

      job(ctx) { chart(ctx, period) }
    when "ID"
      id = remix_id(words) or raise Gemdrop::Error, "SLAY REMIX ID takes a remix's number or its remix.kwed.org/remix/... link."
      job(ctx) { one(ctx, id) }
    else
      all = args.join(" ")
      check_query!(all) && job(ctx) { search(ctx, all) }
    end
  end

  # SLAY COUNTRY ...: where musicians come from (SET and UNSET for bot admins).
  def country_command(ctx, args)
    raise Gemdrop::Error, "SLAY COUNTRY <artist>: where a musician comes from." if args.empty?

    case args.first.upcase
    when "SET"
      raise Gemdrop::Error, "Only bot admins can set countries." unless ctx.admin?

      code = args.last.to_s.upcase
      name = args[1..-2].join(" ")
      raise Gemdrop::Error, "SLAY COUNTRY SET <artist> <code>, e.g. SLAY COUNTRY SET Makke SE." if
        name.strip.empty? || !code.match?(/\A[A-Z]{2}\z/)

      @countries.remember(name, "country" => code, "source" => "set by #{ctx.account}")
      ctx.reply_privately("#{name}: #{@countries.label(code)}, as set by you.")
    when "UNSET"
      raise Gemdrop::Error, "Only bot admins can set countries." unless ctx.admin?

      name = args.drop(1).join(" ")
      @countries.forget(name)
      ctx.reply_privately("#{name}: back to MusicBrainz's answer.")
    else
      name = args.join(" ").strip
      known = @countries.entry(name)
      return ctx.reply(@countries.answer(name, known)) if known && !@countries.stale?(known)

      job(ctx) { ctx.reply(@countries.answer(name, @countries.find(name))) }
    end
  end

  def period!(words)
    period = words.empty? ? "week" : words.downcase
    raise Gemdrop::Error, "That takes day, week, month or all." unless PERIODS.key?(period)

    period
  end

  def setup
    @lock = Mutex.new
    @cache = {}
    @rko = Rko.new(self)
    @countries = Countries.new(self)
    @seen = recent_keys
    every(2) { @countries.work }
    return unless primary?

    after(5) { background { poll } }
    # The artists already logged, so COUNTRIES has their countries.
    after(10) { @countries.look_up(plays.last(1000).reject(&:live?).flat_map { |play| people(play.artist) }.uniq) }
    every(settings["poll_seconds"]) { background { poll } }
  end

  attr_reader :rko, :countries

  # --- shared helpers ----------------------------------------------------------------------------------

  def self.normalize(text) = text.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip
  def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def self.text(html)
    CGI.unescapeHTML(html.to_s.gsub(/<[^>]*>/, " ").gsub("&nbsp;", " ")).gsub(/[[:space:]]+/, " ").strip
  end

  def normalize(text) = self.class.normalize(text)
  def now = self.class.now
  def text(html) = self.class.text(html)

  # One line: the parts that must be there, then as many of the others as
  # fit, joined with " · ".
  def line(required, optional = [])
    text = required.compact.join(" · ")
    optional.compact.each do |part|
      longer = "#{text} · #{part}"
      break if longer.bytesize > MAX_LINE

      text = longer
    end
    text.bytesize > MAX_LINE ? "#{text.byteslice(0, MAX_LINE - 3).scrub('')}…" : text
  end

  def shown(ctx) = settings_for(ctx.channel)["results"]

  def limit!(ctx)
    return unless ctx.channel?
    return if rate_limit("channel:#{casefold(ctx.channel)}", limit: settings_for(ctx.channel)["per_channel_per_minute"], per: 60)

    raise Gemdrop::Error, "Easy, a few answers a minute here; try again shortly."
  end

  def job(ctx, &work)
    queued = background do
      work.call
    rescue Gemdrop::Error => e
      ctx.reply_privately(e.message)
    end
    raise Gemdrop::Error, "Busy right now; try again in a moment." unless queued

    true
  end

  def times(count) = count == 1 ? "once" : "#{count} times"
  def plural(count, word) = "#{count} #{count == 1 ? word : PLURALS.fetch(word)}"
  def cut(text, length) = text.length > length ? "#{text[0, length - 1].rstrip}…" : text

  # A name may be several ("Tim Forsyth & Jogeir Liljedahl", "G. R. Gallefoss, K. Røstøen").
  def people(names) = names.to_s.split(/\s*(?:&|,| and | vs\.? | feat\.? )\s*/i).reject(&:empty?)

  # Names with their countries' codes where known: "Jeroen Tel [NL]".
  def who(names)
    list = people(names)
    return names if list.empty?

    codes = list.map { |name| @countries.country(name) }
    return names if codes.none?

    list.zip(codes).map { |name, code| code ? "#{name} [#{code}]" : name }.join(" & ")
  end

  def minutes(seconds)
    minutes = (seconds / 60).floor
    return "#{[minutes, 0].max} min" if minutes < 60

    "#{minutes / 60} h #{minutes % 60} min"
  end

  def when_played(play)
    today = Time.now.utc.strftime("%F")
    play.at.start_with?(today) ? "today #{play.local[11, 5]}" : play.local[0, 16]
  end

  # --- the station: what is on --------------------------------------------------------------------------

  # What is on, as a remix: of which C64 tune and by whom, with its
  # Remix.Kwed.Org page, rating and downloads, and how many other remixes of
  # the tune the station has.
  def now_playing(ctx)
    air = on_air or return ctx.reply("SLAY Radio: nothing on its Recently Played list right now.")
    current, over, ago = air
    if current.live?
      return ctx.reply("SLAY Radio: a live show, on since #{current.local[11, 5]} (#{ago} ago) · tune in: #{SITE}")
    end

    stats = song(current.song) || {}
    remix = stats[:rko_id] && rko_remix(stats[:rko_id])
    @countries.look_up(people(current.artist) + people(remix&.composer))
    head = "SLAY Radio #{over ? 'last played' : 'now'}: #{who(current.artist)} – #{current.title}" \
           "#{" (#{current.length})" if current.seconds}, #{over ? "#{ago} ago" : "started #{ago} ago"}"
    ctx.reply(line([head, original(stats, remix), stats[:rko] || "#{SITE}/songinfo/#{current.song}"].compact,
                   [remix && ["RKO: #{remix.rating}", remix.downloads && plural(remix.downloads, 'download')].compact.join(", "),
                    stats[:others]&.any? && "#{plural(stats[:others].size, 'other remix')} of it on SLAY Radio: !slay others",
                    stats[:sid] && "SID: #{stats[:sid]}",
                    stats[:plays] && stats[:added] && "played #{times(stats[:plays])} on SLAY since #{stats[:added][0, 4]}",
                    stats[:rating] && "rated #{stats[:rating]}"]))
  end

  # The other remixes of the tune on air, as the station lists them (best
  # rated first), with their song numbers for SLAY INFO.
  def others(ctx)
    air = on_air or return ctx.reply("SLAY Radio: nothing on its Recently Played list right now.")
    current = air.first
    return ctx.reply("SLAY Radio: a live show is on; its songs aren't listed.") if current.live?

    stats = song(current.song) || {}
    list = stats[:others] || []
    tune = tune_name(stats) || current.title
    return ctx.reply("SLAY Radio: no other remixes of #{tune} on the station.") if list.empty?

    by = composer(stats, nil)
    first, *rest = list.map { |other| "#{other[:name]} #{other[:rating]} ##{other[:song]}" }
    ctx.reply(line(["SLAY Radio has #{plural(list.size, 'other remix')} of #{tune}#{" (#{by})" if by}: #{first}"], rest))
  end

  # The C64 tune behind what is on air, as { tune:, composer:, song:, name: },
  # or nil (a live show, or nothing known).
  def tune_on_air
    current = on_air&.first
    return nil if current.nil? || current.live?

    stats = song(current.song) || {}
    tune = tune_name(stats) or return nil
    { tune: tune, composer: composer(stats, stats[:rko_id] && rko_remix(stats[:rko_id])), song: current.song,
      name: current.name }
  end

  # The newest play, whether it is over, and how long ago it started.
  def on_air
    current = history.first or return nil
    started = Time.iso8601(current.at)
    over = current.seconds && Time.now > started + current.seconds + 60
    [current, over, minutes(Time.now - started)]
  end

  # "a remix of Rob Hubbard's Sanxion (subtune 2)", from the remix on RKO and
  # the original SID's path.
  def original(stats, remix)
    tune = tune_name(stats)
    by = composer(stats, remix)
    return nil unless tune || by

    "a remix of #{by ? "#{who(by)}'s " : ''}#{tune || 'a C64 tune'}#{" (subtune #{stats[:subtune]})" if stats[:subtune].to_i > 1}"
  end

  # The original's name from its SID file: "Sanxion.sid" -> "Sanxion".
  def tune_name(stats) = stats[:sid_path] && File.basename(stats[:sid_path], ".sid").tr("_", " ")

  # The composer: as RKO names them, else from HVSC's folder
  # ("MUSICIANS/H/Hubbard_Rob" -> "Rob Hubbard").
  def composer(stats, remix)
    return remix.composer if remix&.composer

    folder = stats[:sid_path].to_s[%r{\AMUSICIANS/[^/]+/([^/]+)/}, 1] or return nil
    last, first = folder.split("_", 2)
    first ? "#{first.tr('_', ' ')} #{last}" : last
  end

  def rko_remix(id)
    @rko.remix(id)
  rescue Gemdrop::Error
    nil
  end

  # --- the station: what was played -----------------------------------------------------------------------

  def last(ctx)
    list = history.reject(&:live?).first(shown(ctx))
    return ctx.reply("SLAY Radio: nothing on its Recently Played list right now.") if list.empty?

    first, *rest = list.map { |play| "#{play.local[11, 5]} #{play.name}#{" (#{play.length})" if play.seconds}" }
    ctx.reply(line(["SLAY Radio, last played: #{first}"], rest))
  end

  def played(ctx, words)
    wanted = normalize(words).split
    found = plays.reverse.select { |play| (wanted - normalize(play.name).split).empty? || normalize(play.name).include?(normalize(words)) }
    since = logged_since&.then { |at| at[0, 10] }
    return ctx.reply("SLAY Radio: \"#{words}\" hasn't been played#{" since #{since}, when this log began" if since}.") if
      found.empty?

    songs = found.group_by(&:song).sort_by { |_, list| [-list.size, list.first.name.downcase] }
    entries = songs.first(shown(ctx)).map do |_, list|
      latest = list.first
      "#{latest.name} #{times(list.size)}, last #{when_played(latest)} ##{latest.song}"
    end
    ctx.reply(line(["SLAY Radio played \"#{words}\" #{times(found.size)} since #{since}: #{entries.first}"], entries.drop(1)))
  end

  def top(ctx, period)
    list, label = period_plays(period)
    return ctx.reply("SLAY Radio: nothing logged in #{label} yet.") if list.empty?

    songs = list.group_by(&:song).sort_by { |_, plays| [-plays.size, plays.first.name.downcase] }.first(shown(ctx))
    artists = list.group_by(&:artist).sort_by { |artist, plays| [-plays.size, artist.downcase] }.first(3)
    head = "SLAY Radio, most played in #{label} (#{plural(list.size, 'play')}): " +
           artists.map { |artist, plays| "#{artist} #{plays.size}" }.join(", ")
    ctx.reply(line([head], songs.each_with_index.map { |(_, plays), i| "#{i + 1}. #{plays.first.name} #{times(plays.size)}" }))
  end

  def info(ctx, words)
    id = words[/\A\s*#?(\d+)\s*\z/, 1]&.to_i
    unless id
      wanted = normalize(words).split
      match = (history + plays.reverse).find { |play| !play.live? && (wanted - normalize(play.name).split).empty? }
      return ctx.reply_privately("SLAY Radio: no \"#{words}\" in its recent plays or this log; try its number (SLAY INFO #5243).") unless match

      id = match.song
    end
    stats = song(id) or return ctx.reply_privately("SLAY Radio has no song #{id}.")
    remix = stats[:rko_id] && rko_remix(stats[:rko_id])
    ctx.reply(line(["SLAY Radio ##{id}: #{stats[:name]}", original(stats, remix),
                    stats[:plays] && "#{plural(stats[:plays], 'play')}#{" since #{stats[:added][0, 10]}" if stats[:added]}",
                    "#{SITE}/songinfo/#{id}"],
                   [stats[:last_played] && "last #{stats[:last_played][0, 16]}",
                    stats[:rating] && "rated #{stats[:rating]}#{" (#{plural(stats[:votes], 'vote')})" if stats[:votes]}",
                    stats[:requests] && plural(stats[:requests], "request"), stats[:length],
                    stats[:rko] && "RKO: #{stats[:rko]}"]))
  end

  def by_country(ctx, period)
    list, label = period_plays(period)
    return ctx.reply("SLAY Radio: nothing logged in #{label} yet.") if list.empty?

    @countries.look_up(list.flat_map { |play| people(play.artist) }.uniq)
    counts = Hash.new(0)
    unknown = 0
    list.each do |play|
      codes = people(play.artist).filter_map { |name| @countries.country(name) }.uniq
      unknown += 1 if codes.empty?
      codes.each { |code| counts[code] += 1 }
    end
    ranked = counts.sort_by { |code, n| [-n, code] }
    head = "SLAY Radio, #{label}: #{plural(list.size, 'play')} by artists from #{plural(ranked.size, 'country')}" \
           "#{" (#{plural(unknown, 'play')} by artists with no known country)" if unknown.positive?}"
    ctx.reply(line([head], ranked.map { |code, n| "#{@countries.country_name(code)} #{n}" }))
  end

  def period_plays(period)
    seconds = PERIODS[period]
    list = plays(since: seconds && (Time.now - seconds)).reject(&:live?)
    [list, period == "all" ? "since #{logged_since.to_s[0, 10]}" : "the last #{period}"]
  end

  # --- remixes (Remix.Kwed.Org) ----------------------------------------------------------------------------

  # RKO's remixes of the tune on air: its name from the station's page for
  # the song (the original SID's file).
  def remixes_on_air(ctx)
    on = tune_on_air
    return ctx.reply("SLAY Radio: no C64 tune known for what's on now (a live show, or not on RKO).") unless on

    search(ctx, on[:tune], label: "#{on[:tune]}#{" by #{on[:composer]}" if on[:composer]} (on SLAY Radio now: #{on[:name]})")
  end

  def search(ctx, words, label: nil)
    found = @rko.find(words, view: "rating", count: true)
    return ctx.reply("RKO: no remixes of \"#{words}\". Fewer or other words may find some.") if found[:rows].empty?

    total = found[:total]
    head = "RKO: #{'at least ' if found[:at_least]}#{plural(total, 'remix')} of #{label || "\"#{words}\""}"
    head += " (#{@rko.search_url(found[:query])})" if total > 1 || found[:at_least]
    answer(ctx, head, found[:rows], first: total > 1 ? "best" : nil)
  end

  def newest(ctx, words)
    return answer(ctx, "RKO, newest", @rko.page(view: "date")[:rows], dates: true) if words.empty?

    found = @rko.find(words, view: "date")
    return ctx.reply("RKO: no remixes of \"#{words}\".") if found[:rows].empty?

    answer(ctx, "RKO, newest of \"#{words}\" (#{@rko.search_url(found[:query])})", found[:rows], dates: true)
  end

  def chart(ctx, period)
    rows = @rko.chart(period)
    return ctx.reply("RKO: nothing popular #{period == 'alltime' ? 'of all time' : "this #{period}"} right now.") if rows.empty?

    answer(ctx, "RKO, most popular #{period == 'alltime' ? 'of all time' : "this #{period}"}", rows, ranked: true)
  end

  def random(ctx, words)
    row = words.empty? ? @rko.random_any : @rko.random_matching(words)
    return ctx.reply("RKO: no remixes of \"#{words}\".") unless row

    detail(ctx, row, head: words.empty? ? "RKO, at random:" : "RKO, at random for \"#{words}\":")
  end

  def one(ctx, id)
    row = @rko.remix(id) or return ctx.reply_privately("Remix.Kwed.Org has no remix #{id}.")
    detail(ctx, row)
  end

  def remix_id(text)
    (text[%r{remix\.kwed\.org/remix/(\d+)}i, 1] || text[/\A\s*#?(\d+)\s*\z/, 1])&.to_i
  end

  def check_query!(words)
    raise Gemdrop::Error, "Search for at most #{Rko::MAX_QUERY} characters (RKO's limit)." if words.length > Rko::MAX_QUERY

    true
  end

  # What was found, the first remix in full and the next ones short (their
  # number works with REMIX ID), as many as fit and results allows.
  def answer(ctx, head, rows, first: nil, dates: false, ranked: false)
    opts = settings_for(ctx.channel)
    list = rows.first(opts["results"])
    @countries.look_up(list.flat_map { |row| people(row.arranger) + people(row.composer) })
    top = summary(list.first, opts, date: dates)
    top = "1. #{top}" if ranked
    rest = list.drop(1).each_with_index.map do |row, i|
      "#{"#{i + 2}. " if ranked}#{cut(row.title, opts['title_length'])} – #{row.arranger}" \
        "#{" #{row.date}" if dates && row.date} ##{row.id}"
    end
    ctx.reply(line([first ? "#{head} · #{first}: #{top}" : "#{head}: #{top}"], rest))
  end

  def summary(row, opts, date: false)
    parts = ["#{cut(row.title, opts['title_length'])} – #{who(row.arranger)}#{" (#{who(row.composer)})" if row.composer}"]
    parts << row.date if date && row.date
    parts << row.rating if row.rating
    parts << row.length if row.length
    parts << @rko.remix_url(row.id)
    parts.join(", ")
  end

  # One line: what it is and where to hear it, then the details and its
  # original SID as they fit.
  def detail(ctx, row, head: nil)
    opts = settings_for(ctx.channel)
    @countries.look_up(people(row.arranger) + people(row.composer))
    name = "#{"#{head} " if head}#{cut(row.title, opts['title_length'])} – #{who(row.arranger)}" \
           "#{", original by #{who(row.composer)}" if row.composer}"
    ctx.reply(line([name, @rko.remix_url(row.id)],
                   [row.date, row.length, row.rating, row.downloads && plural(row.downloads, 'download'), row.size,
                    row.sid && "SID: #{row.sid}"]))
  end

  # --- the station's log ----------------------------------------------------------------------------------

  # Reads the Recently Played page and adds what is new, oldest first.
  def poll
    plays = history(fresh: true)
    new = plays.reverse.reject { |play| @seen.include?(key(play)) }
    return if new.empty?

    new.each do |play|
      write(play)
      @seen << key(play)
    end
    @seen = @seen.last(200)
    @countries.look_up(new.reject(&:live?).flat_map { |play| people(play.artist) })
    announce(new.last)
  rescue Gemdrop::Error => e
    log.warn("Couldn't read SLAY Radio's Recently Played: #{e.message}")
  end

  def key(play) = "#{play.at}|#{play.song}"

  def write(play)
    path = File.join(log_dir, "plays-#{play.at[0, 4]}.jsonl")
    File.open(path, File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW, 0o600) { |f| f.puts(play.to_json) }
  end

  def announce(play)
    return if play.live?

    settings["announce"].each do |channel|
      say(channel, "SLAY Radio: #{play.name}#{" (#{play.length})" if play.seconds} · #{SITE}/songinfo/#{play.song}") if
        in_channel?(channel)
    end
  end

  # Every logged play, oldest first (from since, a Time, if given).
  def plays(since: nil)
    dir = log_dir or return []
    files = Dir.glob(File.join(dir, "plays-*.jsonl")).sort
    files.select! { |f| f[/plays-(\d{4})/, 1].to_i >= since.utc.year } if since
    cutoff = since&.utc&.iso8601
    files.flat_map do |file|
      File.foreach(file).filter_map do |line|
        data = JSON.parse(line)
        next if cutoff && data["at"] < cutoff

        Play.new(**data.transform_keys(&:to_sym).slice(*Play.members))
      rescue JSON::ParserError, ArgumentError
        nil
      end
    end
  end

  def recent_keys = plays.last(200).map { |play| key(play) }

  # The log's folder: the first network's instance keeps it in its own data
  # folder and tells the others, through shared (one for all networks).
  def log_dir
    shared["log_dir"] = data_dir if primary? && shared["log_dir"] != data_dir
    shared["log_dir"]
  end

  def logged_since = plays.first&.at

  # --- slayradio.org ---------------------------------------------------------------------------------------

  # The Recently Played page, newest first.
  def history(fresh: false)
    parse_history(fetch(HISTORY, fresh ? 0 : PAGE_SECONDS))
  end

  def parse_history(html)
    body = html[%r{id=['"]song-history-body['"][^>]*>(.*?)</tbody>}m, 1] || html
    body.scan(%r{<tr[^>]*>(.*?)</tr>}m).filter_map do |(row)|
      song = row[%r{/songinfo/(\d+)}, 1] or next
      cells = row.scan(%r{<td[^>]*>(.*?)</td>}m).flatten.map { |cell| text(cell) }
      next if cells.size < 4

      local = cells[2][/\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\z/] or next
      Play.new(at: stockholm_to_utc(local).iso8601, local: local, artist: cells[0].sub(/\s*-\z/, ""), title: cells[1],
               song: song.to_i, length: cells[3])
    end
  end

  # A song's page: its name, its history on the station, its remix on RKO,
  # the original SID and the station's other remixes of the same subtune.
  def song(id)
    html = fetch(format(SONG, id), SONG_SECONDS)
    plain = text(html.gsub(%r{<(script|style)[^>]*>.*?</\1>}m, " "))
    name = plain[/##{id}: (.+?) Added to rotation/, 1] or return nil
    { name: name, added: plain[/Added to rotation: (\S+ \S+)/, 1], last_played: plain[/Song last played: (\S+ \S+)/, 1],
      plays: plain[/Number of plays: (\d+)/, 1]&.to_i, requests: plain[/Requests: (\d+)/, 1]&.to_i,
      votes: plain[/Votes: (\d+)/, 1]&.to_i, length: plain[/Song length: (\d+:\d\d)/, 1],
      rating: html[%r{class="percent"[^>]*>\s*<p>([\d.]+%)</p>}m, 1],
      rko: html[%r{href=['"](https?://remix\.kwed\.org/[^'"]+)['"]}i, 1]&.sub(/\Ahttp:/, "https:"),
      rko_id: html[%r{remix\.kwed\.org/remix/(\d+)}i, 1]&.to_i,
      **original_sid(html), others: other_remixes(html) }
  end

  # The original SID, from the page's DeepSID link: its HVSC path and subtune.
  def original_sid(html)
    link = html[%r{href=['"](https://deepsid\.chordian\.net/\?file=[^'"]+)['"]}, 1] or return {}
    link = CGI.unescapeHTML(link)
    query = URI.decode_www_form(URI(link).query.to_s).to_h
    { sid: link, sid_path: query["file"].to_s.delete_prefix("/"), subtune: query["subtune"]&.to_i }
  rescue URI::Error, ArgumentError
    {}
  end

  # "OTHER REMIXES OF THE SAME SUBTUNE": SLAY's rating, song number, name.
  def other_remixes(html)
    block = html.split(/OTHER REMIXES OF THE SAME SUBTUNE/i, 2)[1] or return []
    block.scan(%r{<p[^>]*>\s*([\d.]+%)\s*</p>.*?href=['"]/songinfo/(\d+)['"][^>]*>\s*(.*?)\s*</a>}m)
         .map { |rating, song, name| { rating: rating, song: song.to_i, name: text(name).sub(" - ", " – ") } }
  end

  def fetch(url, seconds)
    hit = @lock.synchronize { @cache[url] }
    return hit[0] if seconds.positive? && hit && hit[1] > now

    response = http_get(url, accept: "text/html", types: /html/)
    raise Gemdrop::Error, "slayradio.org answered #{response.status}; try again later." unless response.status == 200

    body = response.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    @lock.synchronize do
      @cache[url] = [body, now + [seconds, PAGE_SECONDS].max]
      @cache.delete(@cache.keys.first) while @cache.size > 200
    end
    body
  end

  # The station's times are Swedish: CET, or CEST from the last Sunday of
  # March to the last Sunday of October (01:00 UTC both), as everywhere in
  # the EU.
  def stockholm_to_utc(local)
    year, month, day, hour, min, sec = local.scan(/\d+/).map(&:to_i)
    summer = Time.utc(year, month, day, hour, min, sec) - 7200
    summer.between?(last_sunday(year, 3), last_sunday(year, 10) - 1) ? summer : summer + 3600
  end

  def last_sunday(year, month)
    last = Time.utc(year, month + 1, 1) - 86_400
    Time.utc(last.year, last.month, last.day - last.wday, 1)
  end
end
