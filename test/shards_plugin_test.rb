require "test_helper"
require "base64"
require "json"
require "openssl"

# The shards plugin (contrib/plugins/shards.rb): the hub side of Gemshard.
# Shards link over IRC notices, with signed hellos and an
# encrypted session (the plugin's Protocol, a copy of Gemshard's); they get
# the channels' state, and the hub ops shards whose nick and user@host match.
class ShardsPluginTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @plugins_dir = install_plugins(File.join(@tmpdir, "plugins"), "shards", "chanserv")
    accounts = Gemdrop::Accounts.new(@store, TEST_HASHER)
    accounts.register("root", "s3cret-admin")
    accounts.register("alice", "password123")
    channels = Gemdrop::Channels.new(@store, network: "EFnet")
    channels.register("#chan", "alice", channel_key: "sesame")
    channels.add_mask("#chan", "*!*bob@bob.example", "op", added_by: "root")
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML, perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      network: EFnet
      admins: [root]
      require_secure_users: false
      data_file: #{File.join(@tmpdir, 'data', 'gemdrop.json')}
      plugins_dir: #{@plugins_dir}
      plugins:
        shards:
          irc_state_seconds: 10
    YAML
    @conn = FakeConnection.new
    @now = 0
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), connection: @conn, store: @store, hasher: TEST_HASHER,
                                                         clock: -> { @now }, logger: Logger.new(@log = StringIO.new))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":Gemdrop!bot@hub.example JOIN #chan")
    @bot.handle(":server 353 Gemdrop = #chan :@Gemdrop alice")
    @shard_key = OpenSSL::PKey.generate_key("ED25519")
    plugin.send(:shared)["sessions"] = [] # links outlive a reload, so they'd outlive a test too
  end

  def plugin = @bot.send(:plugin_manager).plugin("shards")
  def proto = plugin.class::Protocol

  def ask(text, nick: "root", host: "root.example")
    @now += 5
    @conn.clear
    @bot.handle(":#{nick}!#{nick}@#{host} PRIVMSG Gemdrop :#{text}")
    @conn.lines.grep(/\ANOTICE #{nick} :/).map { |l| l.split(" :", 2).last }
  end

  def add_shard(key = @shard_key, name: "slay")
    ask("IDENTIFY s3cret-admin")
    ask("SHARD ADD #{name} #{proto.fingerprint(key)}")
  end

  def hello(key = @shard_key, network: "EFnet") = proto.start(key, "hello", "name" => "slay", "network" => network)

  # The shard's side over IRC: its notices go in, the hub's come out.
  def irc_link(key = @shard_key, nick: "Shard1", userhost: "shard@shard.example", network: "EFnet")
    mine, text = hello(key, network: network)
    @conn.clear
    proto.irc_lines("h", text).each { |line| @bot.handle(":#{nick}!#{userhost} NOTICE Gemdrop :#{line}") }
    tag, payload = irc_from_hub(nick)
    return nil unless tag == "h"

    welcome, hub = proto.verify_signed(payload)
    raise "not for my hello" unless welcome["to"] == proto.b64(mine[:nonce])

    proto.session(mine, welcome, key, hub, shard: true)
  end

  def irc_from_hub(nick)
    assembler = proto::Assembler.new
    result = nil
    @conn.lines.grep(/\ANOTICE #{nick} :GS1 /).each { |l| result = assembler.feed("Gemdrop", l.split(" :", 2).last) || result }
    result
  end

  def test_admins_add_list_and_remove_shards
    ask("IDENTIFY s3cret-admin")
    info, code = ask("SHARD INFO")
    assert_match(/\AFor a shard's host \(bin\/gemshard-docker setup <name>\): network: EFnet, hub_gecos: Gemdrop IRC bot, hub_nick: Gemdrop, hub_fingerprint: SHA256:\S+\z/, info)
    details = JSON.parse(Base64.urlsafe_decode64(code[/gemshard1:(\S+)\z/, 1]))
    assert_equal({ "n" => "EFnet", "g" => "Gemdrop IRC bot", "h" => "Gemdrop", "f" => plugin.send(:hub_fingerprint) }, details)
    assert_match(/isn't a fingerprint/, ask("SHARD ADD slay nonsense").first)
    assert_equal ["Shard slay may link for EFnet now."], ask("SHARD ADD slay #{proto.fingerprint(@shard_key)}")
    assert_match(/key is shard slay's already/, ask("SHARD ADD other #{proto.fingerprint(@shard_key)}").first)
    assert_match(/\Aslay \(EFnet\): not linked; key SHA256:/, ask("SHARD LIST").first)
    assert_equal ["Removed shard slay; it is unlinked."], ask("SHARD DEL slay")
    assert_match(/No shards yet/, ask("SHARD LIST").first)
  end

  def test_the_state_is_the_hubs_truth_and_nothing_secret
    @bot.handle(":alice!alice@alice.example JOIN #chan")
    ask("IDENTIFY password123", nick: "alice", host: "alice.example")
    state = plugin.send(:snapshot)
    assert_equal({ "nick" => "Gemdrop", "userhost" => "bot@hub.example", "gecos" => "Gemdrop IRC bot" }, state["hub"])
    assert_equal ["root"], state["admins"]
    chan = state["channels"].find { |c| c["name"] == "#chan" }
    assert_equal "sesame", chan["key"]
    assert_equal({ "alice" => "owner" }, chan["access"])
    assert_equal [["*!*bob@bob.example", "op"]], chan["masks"]
    assert_includes state["sessions"], { "nick" => "alice", "userhost" => "alice@alice.example", "account" => "alice" }
    refute_match(/password|scrypt|pepper/i, JSON.generate(state), "no password hashes or secrets")
  end

  def test_a_shard_reports_its_server_and_gets_the_state_once
    add_shard
    session = irc_link
    sealed = session.seal("t" => "status", "nick" => "Thief", "userhost" => "x@thief.example", "server" => "irc.two")
    proto.irc_lines(session.id, sealed).each { |l| @bot.handle(":Shard1!shard@shard.example NOTICE Gemdrop :#{l}") }
    @conn.clear
    plugin.send(:tick)
    state = session.open(irc_from_hub("Shard1").last)
    assert_equal "state", state["t"]
    assert_equal ["#chan"], state["channels"].map { |c| c["name"] }
    assert_equal [{ "name" => "slay", "nick" => "Shard1", "userhost" => "shard@shard.example", "server" => "irc.two" }],
                 state["bots"], "nick and user@host from its lines, not from what it says"
    @conn.clear
    plugin.send(:tick)
    assert_empty @conn.lines.grep(/NOTICE Shard1/), "unchanged: not sent again"
  end

  def test_unknown_keys_wrong_networks_and_replayed_hellos_are_refused
    assert_nil irc_link(OpenSSL::PKey.generate_key("ED25519"))
    assert_match(/unknown key/, @log.string)
    add_shard
    assert_nil irc_link(network: "IRCnet")
    assert_match(/shard slay is for EFnet/, @log.string)

    _mine, text = hello
    lines = proto.irc_lines("h", text)
    2.times { lines.each { |l| @bot.handle(":Shard1!shard@shard.example NOTICE Gemdrop :#{l}") } }
    assert_match(/a hello seen before/, @log.string, "a hello is only taken once")
  end

  def test_an_old_hello_is_refused
    add_shard
    message = { "t" => "hello", "v" => 1, "id" => proto.b64(proto.raw_public(@shard_key)),
                "eph" => proto.b64(proto.raw_public(OpenSSL::PKey.generate_key("X25519"))),
                "nonce" => proto.b64("n" * 16), "at" => Time.now.to_i - 3600, "network" => "EFnet" }
    proto.irc_lines("h", proto.signed(@shard_key, message)).each do |l|
      @bot.handle(":Shard1!shard@shard.example NOTICE Gemdrop :#{l}")
    end
    assert_match(/a hello from another time/, @log.string)
  end

  def test_a_shard_links_over_irc
    add_shard
    session = irc_link
    assert session, @log.string
    assert_match(/Shard slay linked as Shard1/, @log.string)
    @conn.clear
    plugin.send(:tick)
    tag, payload = irc_from_hub("Shard1")
    assert_equal session.id, tag
    state = session.open(payload)
    assert_equal [{ "name" => "slay", "nick" => "Shard1", "userhost" => "shard@shard.example" }], state["bots"],
                 "over IRC the hub knows who the shard is from its lines"
    assert(@conn.lines.grep(/\ANOTICE Shard1 :GS1 /).all? { |l| l.bytesize < 400 })

    @bot.handle(":alice!alice@alice.example JOIN #chan") # a change...
    @conn.clear
    plugin.send(:tick)
    assert_empty @conn.lines.grep(/NOTICE Shard1/), "...waits for irc_state_seconds over IRC"
  end

  def test_irc_lines_must_come_from_the_shard_and_be_genuine
    add_shard
    session = irc_link
    sealed = session.seal("t" => "status", "server" => "irc.two")
    proto.irc_lines(session.id, sealed).each { |l| @bot.handle(":Shard1!shard@thief.example NOTICE Gemdrop :#{l}") }
    assert_nil plugin.send(:sessions).first[:server], "the right session, the wrong user@host"
    bad = proto.unb64(sealed)
    bad.setbyte(10, bad.getbyte(10) ^ 1)
    proto.irc_lines(session.id, proto.b64(bad)).each { |l| @bot.handle(":Shard1!shard@shard.example NOTICE Gemdrop :#{l}") }
    assert_nil plugin.send(:sessions).first[:server], "tampered"
    proto.irc_lines(session.id, sealed).each { |l| @bot.handle(":Shard1!shard@shard.example NOTICE Gemdrop :#{l}") }
    assert_equal "irc.two", plugin.send(:sessions).first[:server]
  end

  def test_a_shard_that_changes_nick_stays_linked
    add_shard
    session = irc_link
    @bot.handle(":Shard1!shard@shard.example NICK :Shard1_")
    sealed = session.seal("t" => "status", "server" => "irc.three")
    proto.irc_lines(session.id, sealed).each { |l| @bot.handle(":Shard1_!shard@shard.example NOTICE Gemdrop :#{l}") }
    assert_equal "irc.three", plugin.send(:sessions).first[:server]
    assert_equal "Shard1_", plugin.send(:shard_bots).first["nick"]
  end

  def test_the_hub_ops_shards_whose_host_matches
    add_shard
    irc_link
    @bot.handle(":Shard1!shard@thief.example JOIN #chan")
    @conn.clear
    plugin.send(:tick)
    assert_empty @conn.lines.grep(/MODE #chan \+o/), "a nick thief gets nothing"
    @bot.handle(":Shard1!shard@thief.example PART #chan")
    @bot.handle(":Shard1!shard@shard.example JOIN #chan")
    @conn.clear
    plugin.send(:tick)
    assert_includes @conn.lines, "MODE #chan +o Shard1"
  end
end
