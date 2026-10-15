require "test_helper"
require "cgi"

# The remix plugin (contrib/plugins/remix.rb): searching Remix.Kwed.Org
# and answering in a few lines, against pages built like RKO's.
class RemixPluginTest < Minitest::Test
  include StoreHelper

  Response = Gemdrop::SafeHttp::Response
  SITE = "https://remix.kwed.org"

  # Canned pages by URL prefix; records what was fetched.
  class FakeHttp
    attr_reader :fetched

    def initialize = (@routes = {}) && (@fetched = [])

    def route(prefix, response) = @routes[prefix] = response

    def get(url, **)
      @fetched << url
      _prefix, response = @routes.select { |prefix, _| url.start_with?(prefix) }.max_by { |prefix, _| prefix.length }
      raise Gemdrop::SafeHttp::Refused, "no route for #{url}" unless response

      response
    end
  end

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    File.write(File.join(@plugins_dir, "remix.rb"),
               File.read(File.expand_path("../contrib/plugins/remix.rb", __dir__)), perm: 0o600)
    @http = FakeHttp.new
  end

  def start(settings = "")
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML + settings.gsub(/^/, "    "), perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      channels: ["#chan"]
      require_secure_users: false
      plugins:
        remix:
          prefix: "!"
    YAML
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), connection: @conn, store: @store, hasher: TEST_HASHER,
                                                       http: @http, plugin_pool: InlinePool.new, logger: Logger.new(nil))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":Gemdrop!bot@host JOIN #chan")
    @conn.clear
  end

  def plugin = @bot.send(:plugin_manager).plugin("remix")

  # What the bot says in #chan for a line someone says there (from a new
  # host each time: the command's cooldown is per host).
  def say(text, nick: "alice")
    @said = (@said || 0) + 1
    @conn.clear
    @bot.handle(":#{nick}!#{nick}@h#{@said}.host PRIVMSG #chan :#{text}")
    @conn.lines.map { |line| line.sub(/\APRIVMSG #chan :/, "") }
  end

  # --- pages like RKO's ---------------------------------------------------------------

  def row(id, title, arranger, composer = "Rob Hubbard", rating: "Outstanding", date: "17/05/18",
          info: "9.0 Mb / 3:26 minutes / 16124 downloads", sid: "/MUSICIANS/H/Hubbard_Rob/Commando.sid")
    <<~HTML
      <tr id="row#{id}">
        <td><a class="date" href="/remix/#{id}" title="Permalink">#{date}</a></td>
        <td><a rel="noindex,nofollow" title="#{info}" href="/download.php/#{id}/x.mp3" class="download">#{CGI.escapeHTML(title)}</a></td>
        <td><a rel="noindex,nofollow" class="artistEmail" href="#row#{id}" onclick="ArrangerMail('1');">#{CGI.escapeHTML(arranger)}</a></td>
        <td>#{CGI.escapeHTML(composer)}</td>
        <td class="icons">#{%(<img class="vote" data-id="#{id}" src="/s.svg" alt="Rating" title="#{rating}">) if rating}
          #{%(<a rel="noindex,nofollow" class="sid" target="_blank" href="https://deepsid.chordian.net/?file=#{sid}&amp;subtune=2"><img></a>) if sid}</td>
      </tr>
    HTML
  end

  def list(rows, pages: 1)
    links = (2..pages).map { |n| %(<a rel="noindex,nofollow" href="?chart=&amp;view=date&amp;page=#{n}">#{n}</a>) }.join(" ")
    html = <<~HTML
      <table><thead><tr><th><a href="?page=1&amp;chart=&amp;view=date-asc&amp;search=">Date</a></th></tr></thead>
      <tbody>#{rows.join}</tbody></table>
      #{"Page: <b>1</b> #{links}" if pages > 1}
      <p>Get C64 remixes and SIDs automatically</p>
    HTML
    Response.new(url: SITE, status: 200, content_type: "text/html; charset=utf-8", content_length: nil, body: html.b)
  end

  def rows(count, from: 1000) = (0...count).map { |i| row(from + i, "Commando #{i}", "Arranger #{i}") }

  def search_page(words, response, view: "rating", number: 1)
    @http.route("#{SITE}/?#{URI.encode_www_form('page' => number, 'chart' => '', 'view' => view, 'search' => words)}",
                response)
  end

  # --- searching ------------------------------------------------------------------------

  def test_search_gives_the_best_rated_in_four_lines
    start
    search_page("commando", list([row(5840, "Commando High Score", "FastLoaders"),
                                  row(4289, "Commando (Sound of SceneSat Edit)", "Firestorm", rating: "Very Good"),
                                  row(4000, "Ghosts'n Commando", "Jeroen Tel"),
                                  row(3999, "Commando 2004", "Mahoney")]))
    lines = say("!remix commando")
    assert_equal 4, lines.size
    assert_equal %(RKO: 4 remixes of "commando", best rated: #{SITE}/search/commando), lines[0]
    assert_equal "1. Commando High Score – FastLoaders (Rob Hubbard) · Outstanding · 3:26 · #{SITE}/remix/5840", lines[1]
    assert_match(/\A2\. Commando \(Sound of SceneSat Edit\) – Firestorm \(Rob Hubbard\) · Very Good/, lines[2])
    assert_match(/\A3\. Ghosts'n Commando – Jeroen Tel/, lines[3], "HTML entities decoded")
  end

  def test_the_count_spans_pages_and_more_is_linked
    start
    search_page("commando", list(rows(50), pages: 3))
    search_page("commando", list(rows(16, from: 2000), pages: 3), number: 3)
    assert_equal %(RKO: 116 remixes of "commando", best rated: #{SITE}/search/commando), say("!remix commando").first
  end

  def test_one_match_and_none
    start
    search_page("sanxion", list([row(1, "Sanxion Loader", "Someone", "Rob Hubbard")]))
    lines = say("!remix sanxion")
    assert_equal %(RKO: 1 remix of "sanxion"), lines.first, "no link when everything is shown"
    search_page("zzqx", list([]))
    assert_equal [%(RKO: no remixes of "zzqx". Fewer or other words may find some.)], say("!remix zzqx")
  end

  def test_words_with_spaces_and_numbers_are_searched
    start
    search_page("jeroen tel", list([row(7, "The Galway Effect", "Jeroen Tel")]))
    assert_match(/The Galway Effect/, say("!remix jeroen tel")[1])
    search_page("1942", list([row(8, "1942 Remix", "Someone", "Mark Cooksey")]))
    assert_match(/1942 Remix/, say("!remix 1942")[1], "a number is a search: 1942 is a game")
  end

  def test_punctuation_is_dropped_when_the_phrase_finds_nothing
    start
    search_page("glyn r. brown", list([]))
    search_page("glyn r brown", list([row(6907, "Mr Danko's Opus", "Glyn R Brown", "Johannes Bjerregaard")]))
    lines = say("!remix glyn r. brown")
    assert_equal %(RKO: 1 remix of "glyn r. brown"), lines[0]
    assert_match(/Mr Danko's Opus – Glyn R Brown/, lines[1])
  end

  def test_otherwise_the_longest_word_narrowed_to_all_the_words
    start
    search_page("ghosts'n goblins", list([]))
    search_page("ghosts n goblins", list([]))
    search_page("goblins", list([row(7404, "Ghosts'n Goblins (tsr remix)", "tsr", "Mark Cooksey"),
                                 row(7000, "Goblins Revenge", "Someone", "Ghost Writer"),
                                 row(6000, "Ghosts 'n Goblins Medley", "Jeroen Tel", "Mark Cooksey")], pages: 4))
    search_page("goblins", list([]), number: 2)
    search_page("goblins", list([row(5000, "Ghostsn Goblins", "X")]), number: 3)
    lines = say("!remix ghosts'n goblins")
    assert_equal %(RKO: at least 2 remixes of "ghosts'n goblins", best rated: #{SITE}/search/goblins), lines[0],
                 "two of the pages read have every word (\"n\" only as a word of its own); there were more pages"
    assert_match(/\A1\. Ghosts'n Goblins \(tsr remix\)/, lines[1])
    assert_match(/\A2\. Ghosts 'n Goblins Medley/, lines[2])
    refute_includes @http.fetched, "#{SITE}/?page=4&chart=&view=rating&search=goblins", "at most 3 pages"
  end

  def test_titles_are_cut_and_lines_stay_short
    start
    search_page("long", list([row(9, "A #{'very ' * 60}long title", "Arranger #{'x' * 40}")]))
    line = say("!remix long")[1]
    assert_includes line, "…"
    assert_operator line.bytesize, :<, 400
  end

  def test_too_long_a_search_is_refused
    start
    say("!remix #{'a' * 31}")
    assert(@conn.lines.any? { |l| l.include?("at most 30 characters") }, @conn.lines.inspect)
    assert_empty @http.fetched
  end

  # --- new, top, random, one -----------------------------------------------------------

  def test_new_lists_the_newest_with_dates
    start
    @http.route("#{SITE}/?page=1&chart=&view=date", list([row(7404, "Ghosts'n Goblins (tsr remix)", "tsr", "Mark Cooksey",
                                                              date: "14/10/26", rating: "Very Good")]))
    lines = say("!remix new")
    assert_equal "RKO: the newest remixes: #{SITE}", lines[0]
    assert_equal "1. Ghosts'n Goblins (tsr remix) – tsr (Mark Cooksey) · 2026-10-14 · Very Good · 3:26 · #{SITE}/remix/7404",
                 lines[1]
  end

  def popular(entries)
    rows = entries.each_with_index.map do |(id, title, arranger), i|
      "<tr>\n<td>#{i + 1}</td>\n<td><a title='9.2 Mb / 4:00 minutes / 6503 downloads' href='/download.php/#{id}/x.mp3'>" \
        "#{CGI.escapeHTML(title)}</a><br>#{arranger}</td>\n<td><img class='vote' data-id='#{id}' src='/s.svg' " \
        "alt='Outstanding' title='Outstanding'></td>\n</tr>"
    end
    html = "<table><tbody>#{row(1, 'Main list', 'X')}</tbody></table><h2>What's popular?</h2><table><tbody>" \
           "<!-- *** Begin: Chart body ***-->\n#{rows.join("\n")}\n</tbody></table>"
    Response.new(url: SITE, status: 200, content_type: "text/html", content_length: nil, body: html.b)
  end

  def test_top_charts
    start
    @http.route("#{SITE}/?page=1&chart=month&view=date", popular([[6907, "Mr Danko's Opus", "Glyn R Brown"],
                                                                   [6616, "Parallax Mini EP", "Tim Forsyth"]]))
    lines = say("!remix top month")
    assert_equal ["RKO: the most popular this month: #{SITE}/?chart=month",
                  "1. Mr Danko's Opus – Glyn R Brown · Outstanding · 4:00 · #{SITE}/remix/6907",
                  "2. Parallax Mini EP – Tim Forsyth · Outstanding · 4:00 · #{SITE}/remix/6616"], lines,
                 "the popular box, not the main list"
    @http.route("#{SITE}/?page=1&chart=week&view=date", popular([[1, "This Week", "X"]]))
    assert_equal "RKO: the most popular this week: #{SITE}/?chart=week", say("!remix top").first
    say("!remix top year")
    assert(@conn.lines.any? { |l| l.include?("TOP takes week, month or alltime") && !l.include?("Remix.Kwed.Org") },
           "a mistake in the command, not the site")
  end

  def test_one_remix_in_detail_by_link_or_number
    start
    @http.route("#{SITE}/remix/7404", list([row(7404, "Ghosts'n Goblins (tsr remix)", "tsr", "Mark Cooksey",
                                                 date: "14/10/26", rating: "Very Good",
                                                 info: "10.8 Mb / 4:41 minutes / 179 downloads",
                                                 sid: "/MUSICIANS/C/Cooksey_Mark/Ghosts_n_Goblins.sid")]))
    lines = say("!remix id https://remix.kwed.org/remix/7404")
    assert_equal ["Ghosts'n Goblins (tsr remix) – tsr, original by Mark Cooksey · out 2026-10-14 · 4:41 · 10.8 MB · " \
                  "179 downloads · Very Good",
                  "Listen: #{SITE}/remix/7404 · SID: https://deepsid.chordian.net/?file=/MUSICIANS/C/Cooksey_Mark/" \
                  "Ghosts_n_Goblins.sid&subtune=2"], lines
    assert_equal lines, say("!remix id 7404")
    @http.route("#{SITE}/remix/99999", list([]))
    say("!remix id 99999")
    assert_equal ["NOTICE alice :Remix.Kwed.Org has no remix 99999."], @conn.lines
    say("!remix id commando")
    assert(@conn.lines.any? { |l| l.include?("ID takes a remix's number") })
  end

  def test_random_from_a_search_or_from_everything
    start
    search_page("galway", list([row(3, "Wizball", "Someone", "Martin Galway")]))
    assert_match(/\ARKO, at random for "galway": Wizball – Someone, original by Martin Galway/, say("!remix random galway").first)
    @http.route("#{SITE}/?page=1&chart=&view=date", list([row(5, "Newest", "X")]))
    (1..5).each { |id| @http.route("#{SITE}/remix/#{id}", list([row(id, "Remix #{id}", "X")])) }
    assert_match(/\ARKO, at random: Remix [1-5] – X/, say("!remix random").first)
  end

  # --- being a good guest ----------------------------------------------------------------

  def test_pages_are_cached
    start
    search_page("commando", list([row(1, "Commando", "X")]))
    say("!remix commando")
    say("!remix commando")
    assert_equal 1, @http.fetched.size
  end

  def test_a_failing_site_is_told_privately
    start
    search_page("commando", Response.new(url: SITE, status: 503, content_type: "text/html", content_length: nil, body: ""))
    say("!remix commando")
    assert_equal ["NOTICE alice :Remix.Kwed.Org: it answered 503; try again later."], @conn.lines
  end

  def test_a_few_answers_a_minute_per_channel
    start("per_channel_per_minute: 2")
    search_page("a", list([row(1, "A", "X")]))
    say("!remix a", nick: "one")
    say("!remix a", nick: "two")
    say("!remix a", nick: "three")
    assert(@conn.lines.any? { |l| l.include?("a few remixes a minute") }, @conn.lines.inspect)
  end
end
