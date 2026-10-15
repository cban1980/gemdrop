# SLAY Radio: logs what SLAY Radio (slayradio.org) plays, from its
# Recently Played page, and answers what is playing, what was played and
# how often, and a song's history on the station.
#
#   SLAY [NOW]                        the remix on air: which C64 tune it remixes, by whom, its RKO page
#   SLAY OTHERS                       the station's other remixes of that tune
#   SLAY LAST                         the last few played
#   SLAY PLAYED <words>               when songs matching were played (this log)
#   SLAY TOP [day|week|month|all]     the most played songs and artists (this log)
#   SLAY INFO <words|#number>         a song's history on SLAY Radio: plays, rating, requests
#   SLAY COUNTRIES [day|week|month|all]  where the artists played come from (this log)
#
# Countries come from the artists plugin (MusicBrainz), when it is loaded:
# each new play's artist is looked up as it is logged.
#
# The page lists the last 30 plays (about two hours), so it is read every
# few minutes (poll_seconds), by the first network's instance only; new
# plays are added to plays-<year>.jsonl in that instance's data folder
# (data/plugins/<first network>/slayradio/), which every network's
# instance reads (it tells them where, in shared). Its times are Swedish, the
# station's; the log keeps them in UTC as well.
#
# Install: bin/gemdrop-docker plugin install contrib/plugins/slayradio.rb
require "cgi"
require "json"
require "time"
require "uri"

class Slayradio < Gemdrop::Plugin
  description "Logs what SLAY Radio plays, and answers what is and was playing"
  help_group "Music"

  setting "poll_seconds", default: 180, type: :integer, min: 60, max: 1800,
                          desc: "how often slayradio.org's Recently Played page is read"
  setting "announce", default: [], type: :list,
                      desc: "channels where each new song is said (off by default)"
  setting "results", default: 3, type: :integer, min: 1, max: 5, channel: true,
                     desc: "songs in an answer, as many as fit in its one line"
  setting "per_channel_per_minute", default: 6, type: :integer, min: 1, max: 60, channel: true

  SITE = "https://www.slayradio.org"
  HISTORY = "#{SITE}/pages/song_history.php"
  SONG = "#{SITE}/pages/song_info.php?song_id=%d"
  LIVE_ID = 1935 # "SLAY Radio - SLAY Radio Live": a live show, which lists no songs
  PERIODS = { "day" => 86_400, "week" => 7 * 86_400, "month" => 30 * 86_400, "all" => nil }.freeze
  PAGE_SECONDS = 60      # a fetched Recently Played page is kept this long
  SONG_SECONDS = 3600    # and a song's page this long

  # One play, as the log keeps it.
  Play = Struct.new(:at, :local, :artist, :title, :song, :length, keyword_init: true) do
    def name = "#{artist} – #{title}"
    def live? = song == LIVE_ID || length.to_s.start_with?("-")
    def seconds = length.to_s.match?(/\A\d+:\d\d\z/) ? length.split(":").then { |m, s| (m.to_i * 60) + s.to_i } : nil
    def to_json(*) = to_h.compact.to_json(*)
  end

  # (No NP: [S], SLAY Radio's own bot in #SLAYRadio, answers !np.)
  command "SLAY", usage: "SLAY [NOW] | OTHERS | LAST | PLAYED <words> | TOP [day|week|month|all] | " \
                         "INFO <words|#number> | COUNTRIES [day|week|month|all]",
                  help: "the remix SLAY Radio is playing, the C64 tune behind it, and what it played", cooldown: 5,
                  details: "SLAY: what is on, which C64 tune it remixes and by whom, its rating and downloads on " \
                           "Remix.Kwed.Org, and how many other remixes of the tune the station has.\n" \
                           "SLAY OTHERS: those other remixes, best rated first.\n" \
                           "SLAY LAST: the last few played. SLAY PLAYED <words>: when matching songs were played.\n" \
                           "SLAY TOP [day|week|month|all]: the most played songs and artists.\n" \
                           "SLAY INFO <words|#number>: a song's plays, rating and requests on SLAY Radio.\n" \
                           "SLAY COUNTRIES [day|week|month|all]: where the artists played come from.\n" \
                           "PLAYED and TOP use the bot's own log, which starts when the plugin was installed." do |ctx, args|
    limit!(ctx)
    words = args.drop(1).join(" ")
    case args.first.to_s.upcase
    when "", "NOW", "NP" then job(ctx) { now_playing(ctx) }
    when "OTHERS", "MORE" then job(ctx) { others(ctx) }
    when "LAST" then job(ctx) { last(ctx) }
    when "PLAYED"
      ctx.usage! if words.strip.empty?
      job(ctx) { played(ctx, words) }
    when "TOP"
      period = words.empty? ? "week" : words.downcase
      raise Gemdrop::Error, "TOP takes day, week, month or all." unless PERIODS.key?(period)

      job(ctx) { top(ctx, period) }
    when "INFO"
      ctx.usage! if words.strip.empty?
      job(ctx) { info(ctx, words) }
    when "COUNTRIES", "COUNTRY"
      period = words.empty? ? "week" : words.downcase
      raise Gemdrop::Error, "COUNTRIES takes day, week, month or all." unless PERIODS.key?(period)

      job(ctx) { countries(ctx, period) }
    else ctx.usage!
    end
  end

  def setup
    @lock = Mutex.new
    @cache = {}
    @seen = recent_keys
    return unless primary?

    after(5) { background { poll } }
    # The artists already logged, so COUNTRIES has their countries.
    after(10) { artists&.look_up(plays.last(1000).reject(&:live?).flat_map { |play| people(play.artist) }.uniq) }
    every(settings["poll_seconds"]) { background { poll } }
  end

  # --- the log -----------------------------------------------------------------------------

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
    artists&.look_up(new.reject(&:live?).flat_map { |play| people(play.artist) })
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

  # --- the answers ---------------------------------------------------------------------------

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
    remix = stats[:rko_id] && rko(stats[:rko_id])
    artists&.look_up(people(current.artist) + people(remix&.composer))
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

    first, *rest = list.map { |other| "#{other[:name]} #{other[:rating]} ##{other[:song]}" }
    ctx.reply(line(["SLAY Radio has #{plural(list.size, 'other remix')} of #{tune}#{" (#{composer(stats, nil)})" if composer(stats, nil)}: " \
                    "#{first}"], rest))
  end

  # For other plugins (remix): the C64 tune behind what is on air, as
  # { tune:, composer:, song:, name: }, or nil (a live show, nothing known).
  # Fetches, so only from background jobs.
  def tune_on_air
    current = on_air&.first
    return nil if current.nil? || current.live?

    stats = song(current.song) || {}
    tune = tune_name(stats) or return nil
    { tune: tune, composer: composer(stats, stats[:rko_id] && rko(stats[:rko_id])), song: current.song, name: current.name }
  end

  # The newest play, whether it is over, and how long ago it started.
  def on_air
    current = history.first or return nil
    started = Time.iso8601(current.at)
    over = current.seconds && Time.now > started + current.seconds + 60
    [current, over, minutes(Time.now - started)]
  end

  # "a remix of Rob Hubbard's Sanxion (subtune 1)", from the remix on RKO and
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

  # A remix on Remix.Kwed.Org, through the remix plugin (and its cache).
  def rko(id)
    plugin("remix")&.remix(id)
  rescue Gemdrop::Error
    nil
  end

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
    seconds = PERIODS[period]
    list = plays(since: seconds && (Time.now - seconds)).reject(&:live?)
    label = period == "all" ? "since #{logged_since.to_s[0, 10]}" : "the last #{period}"
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
    remix = stats[:rko_id] && rko(stats[:rko_id])
    ctx.reply(line(["SLAY Radio ##{id}: #{stats[:name]}", original(stats, remix),
                    stats[:plays] && "#{plural(stats[:plays], 'play')}#{" since #{stats[:added][0, 10]}" if stats[:added]}",
                    "#{SITE}/songinfo/#{id}"],
                   [stats[:last_played] && "last #{stats[:last_played][0, 16]}",
                    stats[:rating] && "rated #{stats[:rating]}#{" (#{plural(stats[:votes], 'vote')})" if stats[:votes]}",
                    stats[:requests] && plural(stats[:requests], "request"), stats[:length],
                    stats[:rko] && "RKO: #{stats[:rko]}"]))
  end

  def countries(ctx, period)
    places = artists or return ctx.reply_privately("Countries need the artists plugin.")
    seconds = PERIODS[period]
    list = plays(since: seconds && (Time.now - seconds)).reject(&:live?)
    label = period == "all" ? "since #{logged_since.to_s[0, 10]}" : "the last #{period}"
    return ctx.reply("SLAY Radio: nothing logged in #{label} yet.") if list.empty?

    places.look_up(list.flat_map { |play| people(play.artist) }.uniq)
    counts = Hash.new(0)
    unknown = 0
    list.each do |play|
      codes = people(play.artist).filter_map { |name| places.country(name) }.uniq
      unknown += 1 if codes.empty?
      codes.each { |code| counts[code] += 1 }
    end
    ranked = counts.sort_by { |code, n| [-n, code] }
    head = "SLAY Radio, #{label}: #{plural(list.size, 'play')} by artists from #{plural(ranked.size, 'country')}" \
           "#{" (#{plural(unknown, 'play')} by artists with no known country)" if unknown.positive?}"
    ctx.reply(line([head], ranked.map { |code, n| "#{places.country_name(code)} #{n}" }))
  end

  # The artists plugin, which knows (from MusicBrainz) where artists come from.
  def artists = plugin("artists")

  # A play's artist may be several ("Tim Forsyth & Jogeir Liljedahl").
  def people(names) = names.to_s.split(/\s*(?:&|,| and | vs\.? | feat\.? )\s*/i).reject(&:empty?)

  # Artists, with their countries' codes where known: "Wobbler [SE]".
  def who(names)
    return names unless artists

    list = people(names)
    codes = list.map { |name| artists.country(name) }
    return names if codes.none?

    list.zip(codes).map { |name, code| code ? "#{name} [#{code}]" : name }.join(" & ")
  end

  MAX_LINE = 400 # bytes: what IRC's 512 leaves after the bot's own prefix and the target

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

  # --- helpers ---------------------------------------------------------------------------------

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
      ctx.reply_privately("slayradio.org: #{e.message}")
    end
    raise Gemdrop::Error, "Busy right now; try again in a moment." unless queued
  end

  def normalize(text) = text.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip

  def times(count) = count == 1 ? "once" : "#{count} times"

  PLURALS = { "song" => "songs", "play" => "plays", "vote" => "votes", "request" => "requests",
              "country" => "countries", "other remix" => "other remixes", "download" => "downloads" }.freeze

  def plural(count, word) = "#{count} #{count == 1 ? word : PLURALS.fetch(word)}"

  def minutes(seconds)
    minutes = (seconds / 60).floor
    return "#{[minutes, 0].max} min" if minutes < 60

    "#{minutes / 60} h #{minutes % 60} min"
  end

  def when_played(play)
    today = Time.now.utc.strftime("%F")
    play.at.start_with?(today) ? "today #{play.local[11, 5]}" : play.local[0, 16]
  end

  # --- slayradio.org ------------------------------------------------------------------------------

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

  # A song's page: its name and its history on the station.
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
    raise Gemdrop::Error, "it answered #{response.status}; try again later." unless response.status == 200

    body = response.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    @lock.synchronize do
      @cache[url] = [body, now + [seconds, PAGE_SECONDS].max]
      @cache.delete(@cache.keys.first) while @cache.size > 200
    end
    body
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def text(html) = CGI.unescapeHTML(html.to_s.gsub(/<[^>]*>/, " ").gsub("&nbsp;", " ")).gsub(/[[:space:]]+/, " ").strip

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
