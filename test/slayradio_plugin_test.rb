require "test_helper"
require "cgi"

# The SLAY Radio plugin (contrib/plugins/slayradio.rb): logging what
# slayradio.org's Recently Played page lists, and answering about it.
class SlayradioPluginTest < Minitest::Test
  include StoreHelper

  Response = Gemdrop::SafeHttp::Response
  SITE = "https://www.slayradio.org"
  HISTORY = "#{SITE}/pages/song_history.php"

  class FakeHttp
    attr_reader :fetched

    def initialize = (@routes = {}) && (@fetched = [])
    def route(url, response) = @routes[url] = response

    def get(url, **)
      @fetched << url
      @routes.fetch(url) { raise Gemdrop::SafeHttp::Refused, "no route for #{url}" }
    end
  end

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    File.write(File.join(@plugins_dir, "slayradio.rb"),
               File.read(File.expand_path("../contrib/plugins/slayradio.rb", __dir__)), perm: 0o600)
    @http = FakeHttp.new
  end

  def start(settings = "")
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML + settings.gsub(/^/, "    "), perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      channels: ["#slayradio"]
      require_secure_users: false
      data_file: #{File.join(@tmpdir, 'data', 'gemdrop.json')}
      plugins:
        slayradio:
          prefix: "!"
    YAML
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), connection: @conn, store: @store, hasher: TEST_HASHER,
                                                       http: @http, plugin_pool: InlinePool.new,
                                                       logger: Logger.new(@log = StringIO.new))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":Gemdrop!bot@host JOIN #slayradio")
    @conn.clear
  end

  def plugin = @bot.send(:plugin_manager).plugin("slayradio")

  # A poll, as its timer runs it: http_get only works in background jobs.
  def poll
    Thread.current[:gemdrop_background] = true
    plugin.send(:poll)
  ensure
    Thread.current[:gemdrop_background] = nil
  end

  def say(text, nick: "alice")
    @said = (@said || 0) + 1
    @conn.clear
    @bot.handle(":#{nick}!#{nick}@h#{@said}.host PRIVMSG #slayradio :#{text}")
    @conn.lines.map { |line| line.sub(/\APRIVMSG #slayradio :/, "") }
  end

  # --- pages like slayradio.org's -----------------------------------------------------------

  # The station's (Swedish) time for a UTC time.
  def local(utc)
    summer = utc + 7200
    (plugin.send(:stockholm_to_utc, summer.strftime("%F %T")) == utc ? summer : utc + 3600).strftime("%F %T")
  end

  # plays: [[artist, title, song id, minutes ago, length], ...], newest first.
  def history(plays)
    rows = plays.map do |artist, title, id, ago, length|
      at = local(Time.at(Time.now.to_i - (ago * 60)).utc)
      "<tr> <td align='right'><a class='r64shout memberlink' href='/songinfo/#{id}'>#{CGI.escapeHTML(artist)}</a> &nbsp; -</td> " \
        "<td align='left'><a class='r64shout memberlink' href='/songinfo/#{id}'>#{CGI.escapeHTML(title)}</a></td> " \
        "<td nowrap>#{at}</td> <td>#{length}</td> </tr>"
    end
    html = "<script type=\"application/ld+json\">{}</script><h1>Song History</h1><table><tbody id=\"song-history-body\">" \
           "#{rows.join("\n")}<tr><td>\" + when[0] + \" \" + when[1] + \"</td></tr></tbody></table>"
    @http.route(HISTORY, Response.new(url: HISTORY, status: 200, content_type: "text/html", content_length: nil, body: html.b))
  end

  # A song's page; sid: the original's HVSC path; others: [[song id, "Artist - Title", rating], ...].
  def song_page(id, name, plays: 203, added: "2019-04-24 09:20:19", rating: "96.25%", sid: nil, subtune: 1, others: [])
    deepsid = sid && %(<a href="https://deepsid.chordian.net/?file=#{URI.encode_www_form_component(sid)}&subtune=#{subtune}">SID</a>)
    more = others.map do |song, title, percent|
      %(<div class="percent"><p style="margin-top:-5px;">#{percent}</p><span></span></div><img onclick="r64(1)">) +
        %(<a class='r64shout memberlink' href='/songinfo/#{song}'>\n #{CGI.escapeHTML(title)} </a><br>)
    end
    html = <<~HTML
      <style>.x{}</style><div class="percent" style="float:left"><p>#{rating}</p><span></span></div>
      <div class="news-head">##{id}: #{CGI.escapeHTML(name)}</div><table><tr><td>Added to rotation:</td><td>#{added}</td></tr>
      <tr><td>Song last played:</td><td>2026-10-15 19:56:18</td></tr><tr><td>Song last requested:</td><td>2024-10-06 07:05:49</td></tr>
      <tr><td>Number of plays:</td><td>#{plays}</td></tr><tr><td>Requests:</td><td>12</td></tr><tr><td>Votes:</td><td>20</td></tr>
      <tr><td>Song length:</td><td>03:58</td></tr></table><a href='http://remix.kwed.org/remix/5989'>Download at Remix.Kwed.Org</a>
      #{deepsid}
      #{"<strong>OTHER REMIXES OF THE SAME SUBTUNE</strong><br><div id=\"more-remixes\">#{more.join("\n")}</div>" if others.any?}
    HTML
    url = "#{SITE}/pages/song_info.php?song_id=#{id}"
    @http.route(url, Response.new(url: url, status: 200, content_type: "text/html", content_length: nil, body: html.b))
  end

  def logged = Dir.glob(File.join(plugin.data_dir, "plays-*.jsonl")).flat_map { |f| File.readlines(f).map { |l| JSON.parse(l) } }

  RECENT = [["Electronscape", "Sanxion Loader", 5243, 1, "03:58"], ["Wobbler", "Dominator (Analogue Re-looped)", 5046, 6, "04:32"],
            ["Johan Andersson", "The Human Race", 5111, 9, "03:34"], ["Philip Bak", "Ace II", 5106, 14, "05:19"]].freeze

  # --- the log -------------------------------------------------------------------------------

  def test_new_plays_are_logged_once_oldest_first_in_utc
    start
    history(RECENT)
    poll
    poll
    assert_equal ["Ace II", "The Human Race", "Dominator (Analogue Re-looped)", "Sanxion Loader"], logged.map { |p| p["title"] }
    first = logged.last
    assert_equal "Electronscape", first["artist"], "no &nbsp; or dash in the artist"
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, first["at"])
    assert_equal 5243, first["song"]
    file = Dir.glob(File.join(plugin.data_dir, "*.jsonl")).first
    assert_equal 0o600, File.stat(file).mode & 0o777

    history([["New Artist", "New Song", 9999, 0, "02:00"], *RECENT])
    poll
    assert_equal ["New Song"], logged.map { |p| p["title"] } - RECENT.map { |r| r[1] }, "only what is new"
  end

  def test_the_log_survives_a_reload
    start
    history(RECENT)
    poll
    plugin.send(:setup) # as a reload sets the plugin up again
    poll
    assert_equal 4, logged.size, "the plugin remembers what it logged"
  end

  def test_announces_new_songs_where_asked
    start("announce: [\"#slayradio\"]")
    history(RECENT)
    @conn.clear
    poll
    assert_equal ["PRIVMSG #slayradio :SLAY Radio: Electronscape – Sanxion Loader (03:58) · #{SITE}/songinfo/5243"], @conn.lines,
                 "the newest only, not a backlog"
  end

  def test_a_failing_site_is_a_warning
    start
    @http.route(HISTORY, Response.new(url: HISTORY, status: 503, content_type: "text/html", content_length: nil, body: ""))
    poll
    assert_match(/Couldn't read SLAY Radio's Recently Played: slayradio.org answered 503/, @log.string)
    assert_empty logged
  end

  # --- now playing, last ---------------------------------------------------------------------

  SANXION_OTHERS = [[6255, "JB Xplodingfist - Sanxion Full Throttle", "100%"],
                    [4922, "Wobbler - Sanxion (Get To Tha Choppa Remix)", "99.01%"]].freeze

  def test_on_air_as_a_remix_of_a_c64_tune
    start
    history(RECENT)
    song_page(5243, "Electronscape - Sanxion Loader", sid: "MUSICIANS/H/Hubbard_Rob/Sanxion.sid", others: SANXION_OTHERS)
    assert_equal ["SLAY Radio now: Electronscape – Sanxion Loader (03:58), started 1 min ago · a remix of Rob Hubbard's " \
                  "Sanxion · https://remix.kwed.org/remix/5989 · 2 other remixes of it on SLAY Radio: !slay others · " \
                  "SID: https://deepsid.chordian.net/?file=MUSICIANS%2FH%2FHubbard_Rob%2FSanxion.sid&subtune=1 · " \
                  "played 203 times on SLAY since 2019 · rated 96.25%"], say("!slay"),
                 "one line: the composer from HVSC's folder (no remix plugin here), the RKO page"
    assert_equal say("!slay"), say("!slay now")
  end

  def test_the_stations_other_remixes_of_the_tune
    start
    history(RECENT)
    song_page(5243, "Electronscape - Sanxion Loader", sid: "MUSICIANS/H/Hubbard_Rob/Sanxion.sid", others: SANXION_OTHERS)
    assert_equal ["SLAY Radio has 2 other remixes of Sanxion (Rob Hubbard): JB Xplodingfist – Sanxion Full Throttle 100% #6255 · " \
                  "Wobbler – Sanxion (Get To Tha Choppa Remix) 99.01% #4922"], say("!slay others")
    song_page(5243, "Electronscape - Sanxion Loader")
    plugin.instance_variable_get(:@cache).clear
    assert_equal ["SLAY Radio: no other remixes of Sanxion Loader on the station."], say("!slay others")
  end

  def test_no_np_command_s_answers_that
    start
    history(RECENT)
    assert_empty say("!np"), "[S], the station's bot, answers !np in #SLAYRadio"
  end

  def test_remix_follows_what_is_on_air
    start
    history(RECENT)
    song_page(5243, "Electronscape - Sanxion Loader", sid: "MUSICIANS/H/Hubbard_Rob/Sanxion.sid")
    rko_row = "<tr><td><a class=\"date\" href=\"/remix/5989\">24/04/19</a></td>" \
              "<td><a title=\"9 Mb / 3:58 minutes / 1000 downloads\" href=\"/download.php/5989/x.mp3\" class=\"download\">" \
              "Sanxion Loader</a></td><td><a class=\"artistEmail\">Electronscape</a></td><td>Rob Hubbard</td>" \
              "<td class=\"icons\"><img class=\"vote\" title=\"Outstanding\"></td></tr>"
    rko = Response.new(url: "x", status: 200, content_type: "text/html", content_length: nil, body: "<table>#{rko_row}</table>")
    @http.route("https://remix.kwed.org/remix/5989", rko)
    @http.route("https://remix.kwed.org/?page=1&chart=&view=rating&search=Sanxion", rko)
    @conn.clear
    @bot.handle(":alice!alice@remix.host PRIVMSG #slayradio :!remix")
    line = @conn.lines.map { |l| l.sub(/\APRIVMSG #slayradio :/, "") }.first
    assert_equal "RKO: 1 remix of Sanxion by Rob Hubbard (on SLAY Radio now: Electronscape – Sanxion Loader): Sanxion Loader – " \
                 "Electronscape (Rob Hubbard), Outstanding, 3:58, https://remix.kwed.org/remix/5989", line
  end

  def test_a_live_show_and_a_song_that_has_ended
    start
    history([["SLAY Radio", "SLAY Radio Live", 1935, 55, "-1:-1"], *RECENT])
    assert_match(/\ASLAY Radio: a live show, on since \d\d:\d\d \(55 min ago\) · tune in: #{SITE}\z/, say("!slay").first)
    history([["Electronscape", "Sanxion Loader", 5243, 30, "03:58"]])
    song_page(5243, "Electronscape - Sanxion Loader")
    plugin.instance_variable_get(:@cache).clear
    assert_match(/\ASLAY Radio last played: Electronscape – Sanxion Loader \(03:58\), 30 min ago/, say("!slay").first)
  end

  def test_last_played
    start
    history(RECENT)
    lines = say("!slay last")
    assert_equal 1, lines.size
    assert_match(/\ASLAY Radio, last played: \d\d:\d\d Electronscape – Sanxion Loader \(03:58\) · \d\d:\d\d Wobbler – /, lines[0])
    assert_equal 3, lines[0].scan(/\d\d:\d\d [A-Z]/).size, "results (3) of them"
  end

  # --- from the log -----------------------------------------------------------------------------

  def test_played_and_top_from_the_log
    start
    history(RECENT)
    poll
    history([["Electronscape", "Sanxion Loader", 5243, 0, "03:58"], ["Wobbler", "Sanxion (Get To Tha Choppa)", 5300, 4, "03:00"]])
    poll
    lines = say("!slay played sanxion")
    assert_equal 1, lines.size
    assert_match(Regexp.new(/\ASLAY Radio played "sanxion" 3 times since \d{4}-\d\d-\d\d: Electronscape – Sanxion Loader 2 times, /.source + 
                 /last today \d\d:\d\d #5243 · Wobbler – Sanxion \(Get To Tha Choppa\) once, last today \d\d:\d\d #5300\z/.source), lines[0])
    assert_match(/hasn't been played since \d{4}-\d\d-\d\d, when this log began/, say("!slay played zzqx").first)

    lines = say("!slay top week")
    assert_equal 1, lines.size
    assert_match(Regexp.new(/\ASLAY Radio, most played in the last week \(6 plays\): Electronscape 2, Wobbler 2, \S.* · /.source + 
                 /1\. Electronscape – Sanxion Loader 2 times · 2\. /.source), lines[0])
    say("!slay top year")
    assert(@conn.lines.any? { |l| l.include?("TOP takes day, week, month or all") })
  end

  def test_info_by_number_or_by_name
    start
    history(RECENT)
    song_page(5243, "Electronscape - Sanxion Loader")
    expected = ["SLAY Radio #5243: Electronscape - Sanxion Loader · 203 plays since 2019-04-24 · #{SITE}/songinfo/5243 · " \
                "last 2026-10-15 19:56 · rated 96.25% (20 votes) · 12 requests · 03:58 · RKO: https://remix.kwed.org/remix/5989"]
    assert_equal expected, say("!slay info #5243")
    assert_equal expected, say("!slay info sanxion loader"), "found among the recent plays"
    say("!slay info nothing like it")
    assert(@conn.lines.any? { |l| l.include?("no \"nothing like it\" in its recent plays") })
  end

  # --- countries (with the artists plugin) -----------------------------------------------------------

  def test_countries_of_the_artists_played
    start
    places = plugin.countries
    { "Electronscape" => "SE", "Wobbler" => "SE", "Philip Bak" => "DK", "Tim Forsyth" => "GB" }.each do |name, code|
      places.remember(name, "country" => code, "source" => "set by test")
    end
    history([["Tim Forsyth & Wobbler", "Together", 7000, 0, "03:00"], *RECENT])
    poll
    assert_equal ["SLAY Radio, the last week: 5 plays by artists from 3 countries (1 play by artists with no known country) · " \
                  "Sweden 3 · Denmark 1 · United Kingdom 1"], say("!slay countries"),
                 "a play by two artists counts for both their countries; Johan Andersson isn't known"
    song_page(7000, "Tim Forsyth & Wobbler - Together")
    plugin.instance_variable_get(:@cache).clear
    assert_match(/\ASLAY Radio now: Tim Forsyth \[GB\] & Wobbler \[SE\] – Together \(03:00\)/, say("!slay").first)
  end

  # --- the station's time -----------------------------------------------------------------------

  def test_swedish_time_to_utc_through_the_year
    start
    convert = ->(local) { plugin.send(:stockholm_to_utc, local).strftime("%F %T") }
    assert_equal "2026-01-15 19:00:13", convert["2026-01-15 20:00:13"], "winter: CET"
    assert_equal "2026-10-15 18:00:13", convert["2026-10-15 20:00:13"], "summer: CEST"
    assert_equal "2026-03-29 01:30:00", convert["2026-03-29 03:30:00"], "just after the spring change"
    assert_equal "2026-10-25 02:30:00", convert["2026-10-25 03:30:00"], "just after the autumn change"
  end
end
