require "test_helper"

# The slayradio plugin's countries (contrib/plugins/slayradio.rb): countries of C64
# musicians from MusicBrainz, chosen among namesakes, remembered, set by
# hand, and asked for by other plugins.
class SlayradioCountriesTest < Minitest::Test
  include StoreHelper

  Response = Gemdrop::SafeHttp::Response
  API = "https://musicbrainz.org/ws/2/artist/"

  class FakeHttp
    attr_reader :fetched

    def initialize = (@routes = {}) && (@fetched = [])
    def route(name, artists) = @routes[name.downcase] = artists

    def get(url, **)
      raise Gemdrop::SafeHttp::Refused, "not MusicBrainz" unless url.start_with?(API)

      @fetched << url
      name = URI.decode_www_form(URI(url).query).to_h["query"][/artist:"(.*)"/, 1].downcase
      body = JSON.generate("artists" => @routes.fetch(name, []))
      Response.new(url: url, status: 200, content_type: "application/json", content_length: nil, body: body)
    end
  end

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    File.write(File.join(@plugins_dir, "slayradio.rb"),
               File.read(File.expand_path("../contrib/plugins/slayradio.rb", __dir__)), perm: 0o600)
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("root", "password123")
    @http = FakeHttp.new
    @http.route("Jeroen Tel", [{ "id" => "j1", "name" => "Jeroen Tel", "score" => 100, "country" => "NL" }])
    @http.route("Wobbler", [{ "id" => "w1", "name" => "Wobbler", "score" => 100, "country" => "NO",
                              "disambiguation" => "symphonic prog, Norway" },
                            { "id" => "w2", "name" => "Wobbler", "score" => 99, "country" => "SE",
                              "disambiguation" => "C64, alias of Markus Norsted" }])
    @http.route("Johan Andersson", [{ "id" => "a1", "name" => "Johan Andersson", "score" => 100, "country" => "FI",
                                      "disambiguation" => "trombone" },
                                    { "id" => "a2", "name" => "Johan Andersson", "score" => 99, "country" => "SE",
                                      "tags" => [{ "name" => "chiptune" }] }])
    @http.route("Twins", [{ "id" => "t1", "name" => "Twins", "score" => 100, "country" => "US" },
                          { "id" => "t2", "name" => "Twins", "score" => 99, "country" => "DE" }])
    @http.route("Makke", [{ "id" => "m1", "name" => "Makke", "score" => 100, "disambiguation" => "C64 remixer" }])
  end

  def start
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML, perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      admins: [root]
      channels: ["#chan"]
      require_secure_users: false
      data_file: #{File.join(@tmpdir, 'data', 'gemdrop.json')}
      plugins:
        slayradio:
          prefix: "!"
    YAML
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), connection: @conn, store: @store, hasher: TEST_HASHER,
                                                       http: @http, plugin_pool: InlinePool.new, logger: Logger.new(nil))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":Gemdrop!bot@host JOIN #chan")
    plugin.shared["next_request"] = 0
  end

  def plugin = @bot.send(:plugin_manager).plugin("slayradio")
  def places = plugin.countries

  def say(text, nick: "alice", host: nil)
    @said = (@said || 0) + 1
    @conn.clear
    @bot.handle(":#{nick}!#{nick}@#{host || "h#{@said}.host"} PRIVMSG #chan :#{text}")
    @conn.lines.map { |line| line.sub(/\APRIVMSG #chan :/, "") }
  end

  # Finds names as the background worker does (http_get only works there).
  def find(name)
    Thread.current[:gemdrop_background] = true
    places.find(name)
  ensure
    Thread.current[:gemdrop_background] = nil
  end

  def test_an_artists_country_by_their_proper_name
    start
    assert_equal ["Jeroen Tel: Netherlands (NL) · MusicBrainz: https://musicbrainz.org/artist/j1"], say("!country jeroen tel")
    assert_equal "NL", places.country("Jeroen  TEL"), "case, spaces and punctuation don't matter"
    say("!country jeroen tel")
    assert_equal 1, @http.fetched.size, "remembered"
  end

  def test_the_c64_one_among_namesakes
    start
    assert_equal "SE", find("Wobbler")["country"], "the C64 remixer, not the prog band"
    assert_equal "SE", find("Johan Andersson")["country"], "by its tags too"
    assert_nil find("Twins")["country"], "two namesakes and nothing to tell them apart: unknown, not a guess"
    assert_nil find("Makke")["country"], "found, but MusicBrainz has no country"
    assert_nil find("Nobody At All")["country"]
    assert_match(/not found on MusicBrainz/, say("!country nobody at all").first)
  end

  def test_admins_set_a_country_by_hand_and_it_sticks
    start
    say("!country set Makke SE", nick: "root")
    assert_match(/only bot admins/i, @conn.lines.join, "not identified yet")
    host = "root.host"
    @bot.handle(":root!root@#{host} PRIVMSG Gemdrop :IDENTIFY password123")
    say("!country set Makke SE", nick: "root", host: host)
    assert_equal "SE", places.country("makke")
    assert_equal ["Makke: Sweden (SE) · set by an admin"], say("!country makke")
    find("Makke")
    assert_equal "SE", places.country("makke"), "MusicBrainz doesn't overwrite what an admin set"
    @bot.handle(":root!root@root2.host PRIVMSG Gemdrop :IDENTIFY password123") # (COUNTRY's cooldown is per host)
    say("!country unset Makke", nick: "root", host: "root2.host")
    assert_nil places.country("makke")
  end

  def test_other_plugins_get_answers_at_once_and_lookups_later
    start
    assert_nil places.country("Jeroen Tel"), "nothing known yet, and nothing waits"
    places.look_up(["Jeroen Tel", "Wobbler", "jeroen tel", "", nil])
    assert_equal ["Jeroen Tel", "Wobbler"], places.queue, "each name once"
    places.work
    deadline = Time.now + 3 # (the plugin's own timer may be the one working through it)
    sleep 0.05 until places.queue.empty? || Time.now > deadline
    assert_equal "NL", places.country("Jeroen Tel")
    assert_equal "SE", places.country("Wobbler")
    places.look_up(["Jeroen Tel"])
    assert_empty places.queue, "known names aren't looked up again"
  end

  def test_one_request_a_second_for_every_network
    start
    plugin.shared["next_request"] = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    find("Jeroen Tel")
    find("Wobbler")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 1.0
  end

  def test_old_answers_are_asked_again
    start
    find("Jeroen Tel")
    plugin.shared_data.update { |data| data["artists"]["jeroen tel"]["checked"] = (Date.today - 200).to_s }
    places.look_up(["Jeroen Tel"])
    assert_equal ["Jeroen Tel"], places.queue
  end
end
