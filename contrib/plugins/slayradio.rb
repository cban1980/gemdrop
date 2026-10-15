# SLAY Radio: logs what SLAY Radio (slayradio.org) plays, from its
# Recently Played page, and answers what is playing, what was played and
# how often, and a song's history on the station.
#
#   NP                                what is playing now
#   SLAY LAST                         the last few played
#   SLAY PLAYED <words>               when songs matching were played (this log)
#   SLAY TOP [day|week|month|all]     the most played songs and artists (this log)
#   SLAY INFO <words|#number>         a song's history on SLAY Radio: plays, rating, requests
#
# The page lists the last 30 plays (about two hours), so it is read every
# few minutes (poll_seconds), by the first network's instance only; new
# plays are added to data/plugins-shared/slayradio/plays-<year>.jsonl,
# which every network's instance reads. Its times are Swedish, the
# station's; the log keeps them in UTC as well.
#
# Install: bin/gemdrop-docker plugin install contrib/plugins/slayradio.rb
require "cgi"
require "json"
require "time"

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

  command "NP", usage: "NP", help: "what SLAY Radio is playing now", cooldown: 5 do |ctx, _args|
    limit!(ctx)
    job(ctx) { now_playing(ctx) }
  end

  command "SLAY", usage: "SLAY LAST | PLAYED <words> | TOP [day|week|month|all] | INFO <words|#number>",
                  help: "what SLAY Radio played, and a song's history there", cooldown: 5,
                  details: "SLAY LAST: the last few played. SLAY PLAYED <words>: when matching songs were played.\n" \
                           "SLAY TOP [day|week|month|all]: the most played songs and artists.\n" \
                           "SLAY INFO <words|#number>: a song's plays, rating and requests on SLAY Radio.\n" \
                           "PLAYED and TOP use the bot's own log, which starts when the plugin was installed." do |ctx, args|
    ctx.usage! if args.empty?
    limit!(ctx)
    words = args.drop(1).join(" ")
    case args.first.upcase
    when "LAST", "NP" then job(ctx) { args.first.casecmp?("NP") ? now_playing(ctx) : last(ctx) }
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
    else ctx.usage!
    end
  end

  def setup
    @lock = Mutex.new
    @cache = {}
    @seen = recent_keys
    return unless primary?

    after(5) { background { poll } }
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
    announce(new.last)
  rescue Gemdrop::Error => e
    log.warn("Couldn't read SLAY Radio's Recently Played: #{e.message}")
  end

  def key(play) = "#{play.at}|#{play.song}"

  def write(play)
    path = File.join(shared_dir, "plays-#{play.at[0, 4]}.jsonl")
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
    files = Dir.glob(File.join(shared_dir, "plays-*.jsonl")).sort
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

  def logged_since = plays.first&.at

  # --- the answers ---------------------------------------------------------------------------

  def now_playing(ctx)
    current = history.first or return ctx.reply("SLAY Radio: nothing on its Recently Played list right now.")
    started = Time.iso8601(current.at)
    ago = minutes(Time.now - started)
    if current.live?
      return ctx.reply("SLAY Radio: a live show, on since #{current.local[11, 5]} (#{ago} ago) · tune in: #{SITE}")
    end

    over = current.seconds && Time.now > started + current.seconds + 60
    stats = song(current.song) rescue nil # rubocop:disable Style/RescueModifier
    ctx.reply(line(["SLAY Radio #{over ? 'last played' : 'now'}: #{current.name}#{" (#{current.length})" if current.seconds}, " \
                    "#{over ? "#{ago} ago" : "started #{ago} ago"}", "#{SITE}/songinfo/#{current.song}"],
                   [stats&.dig(:plays) && stats[:added] && "played #{times(stats[:plays])} since #{stats[:added][0, 4]}",
                    stats&.dig(:rating) && "rated #{stats[:rating]}"]))
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
    ctx.reply(line(["SLAY Radio ##{id}: #{stats[:name]}",
                    stats[:plays] && "#{plural(stats[:plays], 'play')}#{" since #{stats[:added][0, 10]}" if stats[:added]}",
                    "#{SITE}/songinfo/#{id}"],
                   [stats[:last_played] && "last #{stats[:last_played][0, 16]}",
                    stats[:rating] && "rated #{stats[:rating]}#{" (#{plural(stats[:votes], 'vote')})" if stats[:votes]}",
                    stats[:requests] && plural(stats[:requests], "request"), stats[:length],
                    stats[:rko] && "RKO: #{stats[:rko]}"]))
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

  PLURALS = { "song" => "songs", "play" => "plays", "vote" => "votes", "request" => "requests" }.freeze

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
      rko: html[%r{href=['"](https?://remix\.kwed\.org/[^'"]+)['"]}i, 1] }
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
