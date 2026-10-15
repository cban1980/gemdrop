require "test_helper"

# Channels with a key (+k) and mode locks: joining with keys from the
# config, the registration or what the bot saw; chanserv's CHANKEY and
# MLOCK, and keeping locked modes set.
class ChannelKeysTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @plugins_dir = install_plugins(File.join(@tmpdir, "plugins"), "chanserv")
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("root", "password123")
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
    @log = StringIO.new
  end

  def config(channels = '["#home"]')
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML, perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      admins: [root]
      channels: #{channels}
      require_secure_users: false
    YAML
    path
  end

  def start(channels = '["#home"]')
    path = config(channels)
    @now = 0
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), config_path: path, connection: @conn, store: @store,
                                                         hasher: TEST_HASHER, clock: -> { @now }, logger: Logger.new(@log))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":server 376 Gemdrop :End of MOTD")
  end

  def say(nick, text)
    @now += 31
    @conn.clear
    @bot.handle(":#{nick}!#{nick}@#{nick}.host PRIVMSG Gemdrop :#{text}")
    @conn.lines.grep(/\ANOTICE #{nick} :/).map { |l| l.split(" :", 2).last }
  end

  def joins = @conn.lines.grep(/\AJOIN /)
  def plugin = @bot.send(:plugin_manager).plugin("chanserv")
  def registry = Gemdrop::Channels.new(@store)

  # --- keys ---------------------------------------------------------------------------------

  def test_configured_channels_can_have_keys
    @conn = nil
    start('["#home", "#secret hunter2"]')
    assert_includes @conn.lines, "JOIN #secret hunter2"
    assert_includes @conn.lines, "JOIN #home"
  end

  def test_keys_make_the_config_private_and_are_checked
    path = config('["#secret hunter2"]')
    File.chmod(0o644, path)
    assert_raises(Gemdrop::ConfigError) { Gemdrop::Config.load(path) }.then { |e| assert_match(/chmod 600/, e.message) }

    path = config('["#secret a,b"]')
    File.chmod(0o600, path)
    assert_raises(Gemdrop::ConfigError) { Gemdrop::Config.load(path) }.then { |e| assert_match(/key for #secret/, e.message) }
  end

  def test_keys_never_reach_the_logs
    start('["#secret hunter2"]')
    assert_equal "JOIN #secret [key]", @bot.send(:redact, "JOIN #secret hunter2")
    assert_equal ":a!b@c PRIVMSG Gemdrop :CHANKEY #c [redacted]", @bot.send(:redact, ":a!b@c PRIVMSG Gemdrop :CHANKEY #c pw")
    assert_equal ":a!b@c PRIVMSG Gemdrop :CHANREGISTER #c alice [redacted]",
                 @bot.send(:redact, ":a!b@c PRIVMSG Gemdrop :CHANREGISTER #c alice pw")
    assert_equal ":a!b@c PRIVMSG Gemdrop :MLOCK #c [redacted]", @bot.send(:redact, ":a!b@c PRIVMSG Gemdrop :MLOCK #c +k pw")
    assert_equal "MODE #c -k+k [redacted]", @bot.send(:redact, "MODE #c -k+k old new")
    assert_equal ":x!y@z MODE #c +mk [redacted]", @bot.send(:redact, ":x!y@z MODE #c +mk pw")
    assert_equal "MODE #c +o alice", @bot.send(:redact, "MODE #c +o alice"), "other modes stay readable"
    seen = []
    plugin.define_singleton_method(:wants_event?) { |_| true }
    @bot.send(:plugin_manager).instance_variable_get(:@loaded)["chanserv"].plugin.class.on(:outgoing) { |e| seen << e.text }
    @bot.send(:send_raw, "JOIN #secret hunter2")
    assert_includes seen, "JOIN #secret [key]", "plugins (the eventlog) don't see it either"
  end

  def test_registered_channels_join_with_their_key
    start
    say("root", "IDENTIFY password123")
    assert_equal ["#vault registered with owner alice."], say("root", "CHANREGISTER #vault alice s3cret")
    assert_includes joins, "JOIN #vault s3cret"
  end

  def test_chankey_by_the_owner
    start
    registry.register("#vault", "alice")
    say("alice", "IDENTIFY password123")
    assert_equal ["I join #vault with that key from now on."], say("alice", "CHANKEY #vault newkey")
    assert_includes joins, "JOIN #vault newkey", "joins right away"
    assert_equal ["#vault has no key now."], say("alice", "CHANKEY #vault -")
    assert_nil registry.channel_key("#vault")
    assert_equal ["You must IDENTIFY first."], say("bob", "CHANKEY #vault x")
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("bob", "password123")
    say("bob", "IDENTIFY password123")
    assert_equal ["You need owner access on #vault for that."], say("bob", "CHANKEY #vault x")
  end

  def test_the_bot_learns_a_changed_key
    start('["#home"]')
    @bot.handle(":Gemdrop!bot@host JOIN #home")
    @bot.handle(":alice!a@a.host MODE #home +k fresh")
    assert_equal "JOIN #home fresh", @bot.send(:join_line, "#home")
    @bot.handle(":alice!a@a.host MODE #home -k fresh")
    assert_equal "JOIN #home", @bot.send(:join_line, "#home")
    @bot.handle(":server 324 Gemdrop #home +ntk fromserver")
    assert_equal "JOIN #home fromserver", @bot.send(:join_line, "#home"), "the server's answer to MODE #home"
  end

  # --- mode locks ---------------------------------------------------------------------------------

  def locked_channel(lock)
    start
    registry.register("#club", "alice")
    @bot.handle(":Gemdrop!bot@host JOIN #club")
    @bot.handle(":server 353 Gemdrop = #club :@Gemdrop alice")
    @bot.handle(":server 324 Gemdrop #club +nt")
    say("alice", "IDENTIFY password123")
    say("alice", "MLOCK #club #{lock}")
  end

  def test_mlock_is_checked_and_shown_without_the_key
    start
    registry.register("#club", "alice")
    say("alice", "IDENTIFY password123")
    assert_equal ["Modes look like +nt-i (with values for k and l)."], say("alice", "MLOCK #club nt")
    assert_equal ["+b is a list or status mode; it can't be locked."], say("alice", "MLOCK #club +b")
    assert_equal ["+l needs a number."], say("alice", "MLOCK #club +l many")
    assert_equal ["+k needs a value."], say("alice", "MLOCK #club +k")
    assert_equal ["This server has no channel mode Q."], say("alice", "MLOCK #club +Q")
    assert_equal ["#club is locked to +ntk-i *; I need op there to keep it."], say("alice", "MLOCK #club +ntk-i hunter2")
    assert_equal ["#club is locked to +ntk-i *."], say("alice", "MLOCK #club")
    assert_equal "hunter2", registry.channel_key("#club"), "a locked key is also the key to join with"
    assert_equal ["#club has no mode lock now."], say("alice", "MLOCK #club -")
    say("bob", "IDENTIFY nope")
    assert_equal ["You must IDENTIFY first."], say("bob", "MLOCK #club +m")
  end

  def test_locked_modes_are_set_back
    locked_channel("+ntm-i")
    assert_includes @conn.lines, "MODE #club +m", "set as soon as it is locked"
    @bot.handle(":Gemdrop!bot@host MODE #club +m")
    @conn.clear
    @bot.handle(":mallory!m@m.host MODE #club -n+i")
    assert_equal ["MODE #club +n-i"], @conn.lines.grep(/\AMODE /)
    @conn.clear
    @bot.handle(":Gemdrop!bot@host MODE #club +n-i")
    assert_empty @conn.lines.grep(/\AMODE /), "its own changes are left alone"
  end

  def test_a_changed_key_is_replaced
    locked_channel("+k right")
    @bot.handle(":Gemdrop!bot@host MODE #club +k right")
    @conn.clear
    @bot.handle(":mallory!m@m.host MODE #club -k+k right wrong")
    assert_equal ["MODE #club -k+k wrong right"], @conn.lines.grep(/\AMODE /)
    assert_match(/Mode lock on #club: set -k \* \+k \*/, @log.string)
    refute_includes @log.string, "right"
  end

  def test_no_enforcing_without_op_and_no_mode_wars
    locked_channel("+m")
    @bot.handle(":Gemdrop!bot@host MODE #club +m")
    @bot.handle(":mallory!m@m.host MODE #club -o Gemdrop")
    @conn.clear
    @bot.handle(":mallory!m@m.host MODE #club -m")
    assert_empty @conn.lines.grep(/\AMODE /), "no op: nothing to do"

    @bot.handle(":chanserv!s@services MODE #club +o Gemdrop")
    assert_equal ["MODE #club +m", "MODE #club +o alice"], @conn.lines.grep(/\AMODE /),
                 "getting op checks the lock, and gives the members their modes"
    @bot.handle(":Gemdrop!bot@host MODE #club +m")
    10.times do
      @bot.handle(":otherbot!o@o.host MODE #club -m")
      @bot.handle(":Gemdrop!bot@host MODE #club +m")
    end
    assert_operator @conn.lines.grep(/\AMODE #club \+m/).size, :<=, 6
    assert_match(/Not enforcing the mode lock on #club for now/, @log.string)
  end
end
