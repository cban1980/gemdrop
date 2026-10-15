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

  def song_page(id, name, plays: 203, added: "2019-04-24 09:20:19", rating: "96.25%")
    html = <<~HTML
      <style>.x{}</style><div class="percent" style="float:left"><p>#{rating}</p><span></span></div>
      <div class="news-head">##{id}: #{CGI.escapeHTML(name)}</div><table><tr><td>Added to rotation:</td><td>#{added}</td></tr>
      <tr><td>Song last played:</td><td>2026-10-15 19:56:18</td></tr><tr><td>Song last requested:</td><td>2024-10-06 07:05:49</td></tr>
      <tr><td>Number of plays:</td><td>#{plays}</td></tr><tr><td>Requests:</td><td>12</td></tr><tr><td>Votes:</td><td>20</td></tr>
      <tr><td>Song length:</td><td>03:58</td></tr></table><a href='http://remix.kwed.org/remix/5989'>Download at Remix.Kwed.Org</a>
    HTML
    url = "#{SITE}/pages/song_info.php?song_id=#{id}"
    @http.route(url, Response.new(url: url, status: 200, content_type: "text/html", content_length: nil, body: html.b))
  end

  def logged = Dir.glob(File.join(@tmpdir, "data", "plugins-shared", "slayradio", "plays-*.jsonl"))
                  .flat_map { |f| File.readlines(f).map { |l| JSON.parse(l) } }

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
    file = Dir.glob(File.join(@tmpdir, "data", "plugins-shared", "slayradio", "*.jsonl")).first
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
    assert_match(/Couldn't read SLAY Radio's Recently Played: it answered 503/, @log.string)
    assert_empty logged
  end

  # --- now playing, last ---------------------------------------------------------------------

  def test_now_playing_with_the_songs_history
    start
    history(RECENT)
    song_page(5243, "Electronscape - Sanxion Loader")
    lines = say("!np")
    assert_equal ["SLAY Radio now: Electronscape – Sanxion Loader (03:58), started 1 min ago · #{SITE}/songinfo/5243",
                  "Played 203 times since 2019 · rated 96.25%"], lines
  end

  def test_a_live_show_and_a_song_that_has_ended
    start
    history([["SLAY Radio", "SLAY Radio Live", 1935, 55, "-1:-1"], *RECENT])
    assert_match(/\ASLAY Radio: a live show, on since \d\d:\d\d \(55 min ago\) · tune in: #{SITE}\z/, say("!np").first)
    history([["Electronscape", "Sanxion Loader", 5243, 30, "03:58"]])
    song_page(5243, "Electronscape - Sanxion Loader")
    plugin.instance_variable_get(:@cache).clear
    assert_match(/\ASLAY Radio last played: Electronscape – Sanxion Loader \(03:58\), 30 min ago/, say("!np").first)
  end

  def test_last_played
    start
    history(RECENT)
    lines = say("!slay last")
    assert_equal "SLAY Radio, last played: #{SITE}/#song_history", lines[0]
    assert_equal 4, lines.size
    assert_match(/\A\d\d:\d\d Electronscape – Sanxion Loader \(03:58\)\z/, lines[1])
  end

  # --- from the log -----------------------------------------------------------------------------

  def test_played_and_top_from_the_log
    start
    history(RECENT)
    poll
    history([["Electronscape", "Sanxion Loader", 5243, 0, "03:58"], ["Wobbler", "Sanxion (Get To Tha Choppa)", 5300, 4, "03:00"]])
    poll
    lines = say("!slay played sanxion")
    assert_match(/\ASLAY Radio played "sanxion" 3 times since \d{4}-\d\d-\d\d, 2 songs:\z/, lines[0])
    assert_match(/\AElectronscape – Sanxion Loader · 2 times, last today \d\d:\d\d · #{SITE}\/songinfo\/5243\z/, lines[1])
    assert_match(/Wobbler – Sanxion \(Get To Tha Choppa\) · once/, lines[2])
    assert_match(/hasn't been played since \d{4}-\d\d-\d\d, when this log began/, say("!slay played zzqx").first)

    lines = say("!slay top week")
    assert_match(/\ASLAY Radio, most played in the last week \(6 plays\): artists Electronscape 2, Wobbler 2, /, lines[0])
    assert_equal "1. Electronscape – Sanxion Loader · 2 times", lines[1]
    say("!slay top year")
    assert(@conn.lines.any? { |l| l.include?("TOP takes day, week, month or all") })
  end

  def test_info_by_number_or_by_name
    start
    history(RECENT)
    song_page(5243, "Electronscape - Sanxion Loader")
    expected = ["SLAY Radio #5243: Electronscape - Sanxion Loader · 203 plays since 2019-04-24 · last 2026-10-15 19:56 · " \
                "rated 96.25% (20 votes) · 12 requests · 03:58",
                "#{SITE}/songinfo/5243 · on RKO: http://remix.kwed.org/remix/5989"]
    assert_equal expected, say("!slay info #5243")
    assert_equal expected, say("!slay info sanxion loader"), "found among the recent plays"
    say("!slay info nothing like it")
    assert(@conn.lines.any? { |l| l.include?("no \"nothing like it\" in its recent plays") })
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
