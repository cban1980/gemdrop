require "minitest/autorun"
require "open3"
require "tmpdir"

# A stand-in for WeeChat's API, enough for contrib/weechat/gemdrop.rb.
module Weechat
  WEECHAT_RC_OK = 0
  WEECHAT_HOOK_SIGNAL_STRING = "string".freeze
  WEECHAT_LIST_POS_SORT = "sort".freeze

  class << self
    attr_accessor :options, :secure, :sent, :printed, :commands, :timers, :servers, :channels, :buffers, :current,
                  :nicks, :completions, :config, :data_dir, :screen, :keybinds

    def reset!
      @options = {}
      @secure = {}
      @sent = []      # irc_input_send strings
      @printed = []   # [buffer, tags, text]
      @commands = []
      @timers = []
      @servers = { "IRCnet" => { connected: true, nick: "zphinx" } }
      @channels = { "IRCnet" => ["#linux.se"] }
      @nicks = {}     # "server,#chan,nick" => true
      @buffers = { "0xserver" => { "localvar_server" => "IRCnet", "localvar_type" => "server", "name" => "server.IRCnet" },
                   "0xchan" => { "localvar_server" => "IRCnet", "localvar_type" => "channel",
                                 "localvar_channel" => "#linux.se", "name" => "IRCnet.#linux.se" },
                   "0xquery" => { "localvar_server" => "IRCnet", "localvar_type" => "private",
                                  "localvar_channel" => "Linuks", "name" => "IRCnet.Linuks" } }
      @current = "0xchan"
      @completions = []
      @screen = {}     # y => text, of the free buffer
      @keybinds = {}
      @config = { "weechat.bar.status.items" => "buffer_name,lag" }
    end

    # Like WeeChat, strings come back as raw bytes (ASCII-8BIT), not UTF-8.
    def config_get_plugin(name) = @options.fetch(name, GemdropScript::OPTIONS.dig(name, 0)).to_s.b
    def config_set_plugin(name, value) = @options[name] = value
    def config_is_set_plugin(name) = @options.key?(name) ? 1 : 0

    def string_eval_expression(expr, *)
      expr[/\A\$\{sec\.data\.(\w+)\}\z/] ? @secure[Regexp.last_match(1)].to_s : expr
    end

    def command(_buffer, text)
      @commands << text
      if (m = text.match(%r{\A/mute /secure set (\S+) (.*)\z})) then @secure[m[1]] = m[2]
      elsif (m = text.match(%r{\A/mute /secure del (\S+)\z})) then @secure.delete(m[1])
      end
    end

    def hook_signal_send(_signal, _type, data) = @sent << data
    def hook_hsignal_send(*) = nil
    def hook_timer(ms, _align, _max, _callback, data) = @timers << [ms, data]
    def info_get(name, server)
      case name
      when "irc_nick" then @servers.dig(server, :nick).to_s
      when "weechat_data_dir" then @data_dir.to_s
      else ""
      end
    end

    # Infolists are arrays of hashes here.
    def infolist_get(name, _pointer, args)
      items =
        case name
        when "irc_server"
          @servers.select { |n, _| args.empty? || n == args }
                  .map { |n, s| { "name" => n, "is_connected" => s[:connected] ? 1 : 0 } }
        when "irc_channel" then @channels.fetch(args, []).map { |c| { "name" => c, "type" => 0 } }
        when "irc_nick" # "server,#chan,nick": that nick; "server,#chan": everyone there
          if args.count(",") == 1 then @nicks.keys.select { |k| k.start_with?("#{args},") }.map { |k| { "name" => k.split(",").last } }
          else @nicks[args] ? [{ "name" => args.split(",").last }] : []
          end
        else []
        end
      { items: items, at: -1 }
    end

    def infolist_next(list)
      list[:at] += 1
      list[:at] < list[:items].size ? 1 : 0
    end

    def infolist_string(list, field) = list[:items][list[:at]][field].to_s.b
    def infolist_integer(list, field) = list[:items][list[:at]][field].to_i
    def infolist_free(_list) = nil

    def buffer_search(plugin, name)
      return "0x#{name}" if plugin == "ruby" && @buffers.key?("0x#{name}")

      @buffers.find { |_, b| b["name"] == name }&.first.to_s
    end

    def buffer_new(name, *)
      @buffers["0x#{name}"] = { "name" => name, "plugin" => "ruby" }
      "0x#{name}"
    end

    def buffer_close(buffer) = @buffers.delete(buffer)
    def buffer_clear(_buffer) = @screen.clear
    def print_y(_buffer, y, text) = @screen[y] = text
    def key_bind(_context, keys) = @keybinds.merge!(keys)
    def key_unbind(_context, key) = @keybinds.delete(key)
    def window_search_with_buffer(_buffer) = ""
    def window_get_integer(*) = 100
    def string_remove_color(text, _replacement) = text.b

    def buffer_set(buffer, property, value) = (@buffers[buffer] ||= {})[property] = value
    def buffer_get_string(buffer, property) = @buffers.fetch(buffer, {})[property].to_s.b
    def current_buffer = @current
    def window_get_pointer(window, property) = property == "buffer" ? @windows.to_h[window].to_s : ""
    attr_accessor :windows

    def print_date_tags(buffer, _date, tags, text) = @printed << [buffer, tags, text]
    def color(_name) = ""
    def prefix(_name) = "=!=\t"
    def bar_item_update(_name) = nil
    def completion_list_add(_completion, word, *) = @completions << word
    def config_get(name) = name
    def config_string(option) = @config[option]
    def config_option_set(option, value, _run) = @config[option] = value
  end
end

load File.expand_path("../contrib/weechat/gemdrop.rb", __dir__)

# The WeeChat script (contrib/weechat/gemdrop.rb), against the stand-in API.
class WeechatScriptTest < Minitest::Test
  G = GemdropScript

  def setup
    Weechat.reset!
    G.reset!
    GemdropUI.reset!
    Weechat.options["bots"] = "IRCnet=Linuks"
    Weechat.data_dir = @tmpdir = Dir.mktmpdir("gemdrop-weechat")
  end

  def teardown = FileUtils.remove_entry(@tmpdir)

  # What the script and the bot said, as plain lines of its window's log.
  def lines = GemdropUI.log.map { |entry| "#{entry.plain_prefix}\t#{entry.plain}" }

  # What reached IRC (the PRIVMSGs to the bot, and USERHOSTs).
  # (Without the CATALOG requests the window makes in the background.)
  def irc = Weechat.sent.map { |s| s.split(";;", 3).last.sub(%r{\A/quote -server \S+ }, "") }.reject { |l| l.end_with?(":CATALOG") }

  def bot_says(text, from: "Linuks!Linuks@bot.example")
    G.notice_in("IRCnet", ":#{from} NOTICE zphinx :#{text}")
  end

  def online!(host = "Linuks@bot.example")
    G.check_bot("IRCnet")
    G.userhost_answered("IRCnet", ":fake.server 302 zphinx :Linuks=+#{host}", "")
  end

  # --- masking --------------------------------------------------------------------------------

  def test_passwords_and_keys_are_masked_in_commands
    assert_equal "IDENTIFY ********", G.mask_command("IDENTIFY hunter22")
    assert_equal "IDENTIFY zphinx ********", G.mask_command("IDENTIFY zphinx hunter22")
    assert_equal "identify zphinx ********", G.mask_command("identify zphinx hunter22")
    assert_equal "PASSWORD ******** ********", G.mask_command("PASSWORD old new")
    assert_equal "REGISTER ********", G.mask_command("REGISTER pw")
    assert_equal "CHANKEY #c ********", G.mask_command("CHANKEY #c sesame")
    assert_equal "CHANKEY #c -", G.mask_command("CHANKEY #c -")
    assert_equal "CHANREGISTER #c bob ********", G.mask_command("CHANREGISTER #c bob sesame")
    assert_equal "CHANREGISTER #c bob", G.mask_command("CHANREGISTER #c bob")
    assert_equal "PLUGIN SET ai api_key ********", G.mask_command("PLUGIN SET ai api_key sk-123")
    assert_equal "PLUGIN SET ai #c token ********", G.mask_command("PLUGIN SET ai #c token abc")
    assert_equal "PLUGIN SET ai #c chat on", G.mask_command("PLUGIN SET ai #c chat on")
    assert_equal "WHOAMI", G.mask_command("WHOAMI")
  end

  def test_what_you_type_is_masked
    assert_equal "/msg Linuks IDENTIFY zphinx ********", G.mask_input("/msg Linuks IDENTIFY zphinx pw", false)
    assert_equal "/msg -server IRCnet Linuks REGISTER ********", G.mask_input("/msg -server IRCnet Linuks REGISTER pw", false)
    assert_equal "/quote PRIVMSG Linuks :IDENTIFY ********", G.mask_input("/quote PRIVMSG Linuks :IDENTIFY pw", false)
    assert_equal "/gd secret set IRCnet ******", G.mask_input("/gd secret set IRCnet sesame", false)
    assert_equal "/gd secret set ******", G.mask_input("/gd secret set sesame", false)
    assert_equal "/gemdrop register ******", G.mask_input("/gemdrop register sesame", false)
    assert_equal "/gd password ******", G.mask_input("/gd password sesame", false)
    assert_equal "/gd chankey #c ******", G.mask_input("/gd chankey #c sesame", false)
    assert_equal "/gd send IDENTIFY ********", G.mask_input("/gd send IDENTIFY sesame", false)
    assert_equal "/gd summary 3", G.mask_input("/gd summary 3", false)
    assert_equal "IDENTIFY zphinx ********", G.mask_input("IDENTIFY zphinx sesame", true), "in the gemdrop buffer"
    assert_equal "@EFnet IDENTIFY ********", G.mask_input("@EFnet IDENTIFY sesame", true)
    assert_equal "IDENTIFY sesame", G.mask_input("IDENTIFY sesame", false), "elsewhere it is just chat"
  end

  def test_printed_lines_to_the_bot_are_masked
    assert_equal "zphinx\tIDENTIFY ********", G.mask_printed("0xquery", "zphinx\tIDENTIFY sesame")
    assert_equal "--\tMsg(zphinx) -> Linuks: IDENTIFY ********", G.mask_printed("0xserver", "--\tMsg(zphinx) -> Linuks: IDENTIFY sesame")
    assert_equal "zphinx\tmy password is great", G.mask_printed("0xchan", "zphinx\tmy password is great"),
                 "your channel lines are left alone"
  end

  # --- options --------------------------------------------------------------------------------

  def test_per_server_options
    Weechat.options["bots"] = "IRCnet=Linuks, *=Gemdrop"
    assert_equal "Linuks", G.bot_nick("ircnet")
    assert_equal "Gemdrop", G.bot_nick("EFnet")
    assert_equal "zphinx", G.account("IRCnet"), "your nick by default"
    Weechat.options["accounts"] = "IRCnet=andreas"
    assert_equal "andreas", G.account("IRCnet")
    Weechat.options["autoup"] = "IRCnet/#linux.se,EFnet/#gunnit"
    assert G.channel_listed?("autoup", "ircnet", "#Linux.se")
    refute G.channel_listed?("autoup", "IRCnet", "#gunnit")
  end

  def test_irc_lines_are_parsed
    assert_equal({ nick: "a", userhost: "u@h", command: "PRIVMSG", params: ["#c", "hi there"] },
                 G.parse("@time=x :a!u@h PRIVMSG #c :hi there"))
    assert_equal ["#c", "victim", "bye"], G.parse(":op!u@h KICK #c victim :bye")[:params]
    assert_equal ["#c"], G.parse(":a!u@h JOIN #c")[:params]
    assert_equal ["#c"], G.parse(":a!u@h JOIN :#c")[:params]
    assert_nil G.parse("garbage")
  end

  # --- talking to the bot -------------------------------------------------------------------------

  def test_commands_go_quietly_and_are_echoed_masked
    G.send_bot("IRCnet", "IDENTIFY zphinx sesame")
    assert_equal ["PRIVMSG Linuks :IDENTIFY zphinx sesame"], irc
    assert(lines.any? { |l| l.include?("IDENTIFY zphinx ********") })
    refute(lines.any? { |l| l.include?("sesame") })
  end

  def test_commands_are_paced_like_the_bot_wants
    10.times { |i| G.send_bot("IRCnet", "WHOAMI #{i}") }
    assert_equal 6, irc.size, "6 per 31 s"
    arrivals = G.state[:sent_at]["ircnet"]
    assert_equal [2.5] * 5, arrivals.each_cons(2).map { |a, b| (b - a).round(1) },
                 "WeeChat sends them ~2 s apart, so they reach the bot later"
    assert_equal [[31_000, "flush|IRCnet"]], Weechat.timers.map { |ms, data| [ms.round(-3), data] }
    assert(lines.any? { |l| l.include?("Holding commands for Linuks for 31s") })
    arrivals.map! { |at| at - 50 } # time passes
    G.timer("flush|IRCnet")
    assert_equal 10, irc.size
  end

  def test_account_commands_are_never_sent_again
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    G.send_bot("IRCnet", "LOGOUT")
    bot_says("You must IDENTIFY first.")
    online!
    bot_says("You are now identified as zphinx.")
    refute(lines.any? { |l| l.include?("Sending again") })
    assert_equal 1, irc.count("PRIVMSG Linuks :LOGOUT")
  end

  def test_nothing_goes_to_a_server_without_a_bot_or_connection
    Weechat.options["bots"] = "EFnet=Linuks"
    refute G.send_bot("IRCnet", "WHOAMI")
    Weechat.options["bots"] = "IRCnet=Linuks"
    Weechat.servers["IRCnet"][:connected] = false
    refute G.send_bot("IRCnet", "WHOAMI")
    assert_empty irc
  end

  # --- logging in and trust ---------------------------------------------------------------------

  def test_identify_pins_the_host_then_only_sends_to_it
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    G.identify("IRCnet")
    assert_equal ["USERHOST Linuks"], irc
    G.userhost_answered("IRCnet", ":fake.server 302 zphinx :Linuks=+~Linuks@bot.example", "")
    assert_equal "IRCnet=~Linuks@bot.example", Weechat.options["hostmasks"]
    assert_equal "PRIVMSG Linuks :IDENTIFY zphinx sesame", irc.last

    Weechat.sent.clear
    G.identify("IRCnet")
    G.userhost_answered("IRCnet", ":fake.server 302 zphinx :Linuks=+~Linuks@evil.example", "")
    assert_equal ["USERHOST Linuks"], irc, "no password for another host"
    assert(lines.last.include?("NOT logging in"))
  end

  def test_automatic_logins_wait_for_a_pinned_host
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    G.identify("IRCnet", quiet: true)
    G.userhost_answered("IRCnet", ":fake.server 302 zphinx :Linuks=+Linuks@whoever.example", "")
    assert_equal ["USERHOST Linuks"], irc
    assert_nil Weechat.options["hostmasks"]
    assert_match(/isn't pinned yet/, lines.last)
  end

  def test_wildcard_hostmasks
    assert G.host_matches?("*@home.archflux.net", "~Linuks@home.archflux.net")
    assert G.host_matches?("Linuks@home.archflux.net", "~Linuks@home.archflux.net"), "ident ~ ignored"
    refute G.host_matches?("*@home.archflux.net", "Linuks@evil.example")
    assert G.host_matches?("*", "anything@anywhere")
  end

  def test_an_offline_bot_gets_nothing
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    G.identify("IRCnet")
    G.userhost_answered("IRCnet", ":fake.server 302 zphinx :", "")
    assert_equal ["USERHOST Linuks"], irc
    assert_match(/not on IRCnet right now/, lines.last)
    assert_equal false, G.state[:online]["ircnet"]
  end

  def test_the_bot_asking_for_a_login_logs_in_and_retries
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    G.send_bot("IRCnet", "ACCESS #linux.se LIST")
    bot_says("You must IDENTIFY first.")
    G.userhost_answered("IRCnet", ":fake.server 302 zphinx :Linuks=+Linuks@bot.example", "")
    assert_equal "PRIVMSG Linuks :IDENTIFY zphinx sesame", irc.last
    bot_says("You are now identified as zphinx.")
    assert_equal "PRIVMSG Linuks :ACCESS #linux.se LIST", irc.last
    assert_equal "zphinx", G.state[:identified]["ircnet"]
  end

  def test_whoami_doesnt_set_off_automations
    Weechat.options["autorun"] = "IRCnet=UP #linux.se"
    bot_says("You are identified as zphinx.")
    assert_empty irc
    bot_says("You are now identified as zphinx.")
    assert_equal ["PRIVMSG Linuks :UP #linux.se"], irc
  end

  def test_autoup_after_logging_in_and_on_join
    Weechat.options["autoup"] = "IRCnet/#linux.se"
    bot_says("You are now identified as zphinx.")
    assert_equal ["PRIVMSG Linuks :UP #linux.se"], irc
    G.irc_event("IRCnet", "join", ":zphinx!z@h JOIN #linux.se")
    assert_equal [2000, "up|IRCnet|#linux.se"], Weechat.timers.last
  end

  def test_password_change_updates_the_kept_one
    Weechat.secure["gemdrop_ircnet"] = "old-pass"
    G.command("0xserver", "password new-pass")
    assert_equal "PRIVMSG Linuks :PASSWORD old-pass new-pass", irc.last
    assert_equal "old-pass", Weechat.secure["gemdrop_ircnet"], "not before the bot confirms"
    bot_says("Password changed.")
    assert_equal "new-pass", Weechat.secure["gemdrop_ircnet"]
  end

  def test_secrets
    G.command("0xserver", "secret set sesame")
    assert_equal "sesame", Weechat.secure["gemdrop_ircnet"]
    G.command("0xserver", "secret set IRCnet other")
    assert_equal "other", Weechat.secure["gemdrop_ircnet"]
    G.command("0xserver", "secret list")
    assert(lines.any? { |l| l.include?("IRCnet: kept (gemdrop_ircnet)") })
    refute(lines.any? { |l| l.include?("other") || l.include?("sesame") })
    G.command("0xserver", "secret del")
    assert_nil Weechat.secure["gemdrop_ircnet"]
  end

  # --- what the bot says --------------------------------------------------------------------------

  def test_bot_notices_go_to_the_gemdrop_buffer
    assert_equal "", bot_says("You are identified as zphinx.")
    assert_equal :bot, GemdropUI.log.last.kind
    assert Weechat.buffers.key?("0xgemdrop"), "the window, for the hotlist"
    assert_equal "2", Weechat.buffers["0xgemdrop"]["hotlist"]
    raw = ":alice!a@h NOTICE zphinx :hi"
    assert_equal raw, G.notice_in("IRCnet", raw), "others' notices stay"
    ctcp = ":Linuks!Linuks@bot.example NOTICE zphinx :\x01VERSION Gemdrop\x01"
    assert_equal ctcp, G.notice_in("IRCnet", ctcp)
    Weechat.options["capture"] = "off"
    raw = ":Linuks!Linuks@bot.example NOTICE zphinx :hello"
    assert_equal raw, G.notice_in("IRCnet", raw)
  end

  def test_an_impostors_notices_are_flagged_and_ignored
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    bot_says("You are now identified as zphinx.", from: "Linuks!x@evil.example")
    assert_match(/not from the trusted host/, lines.last)
    assert_equal "3", Weechat.buffers["0xgemdrop"]["hotlist"], "a highlight"
    assert_nil G.state[:identified]["ircnet"]
  end

  def test_settings_and_plugin_views
    G.send_view("IRCnet", "PLUGIN SETTINGS ai")
    bot_says("ai: chat = true (saved with PLUGIN SET)")
    assert_match(/\Achat {20} true \[saved\]\z/, GemdropUI.log.last.text, "shown as a table")
    assert_equal [{ name: "chat", value: "true", saved: true }], G.state[:plugin_settings]["ircnet"]["ai"]
    G.send_view("IRCnet", "PLUGIN LIST")
    bot_says("ai: loaded, commands AI, AISUMMARY (private messages). Talks")
    assert_match(/\Aai {11}loaded, commands AI/, GemdropUI.log.last.text)
    assert_equal "loaded", G.state[:plugin_list]["ircnet"].last[:state]
    assert_includes G.state[:plugins], "ai"
    assert_includes G.state[:commands], "AISUMMARY"
    assert_includes G.state[:settings]["ai"], "chat"
    bot_says("Channel commands: UP · !kick · MLOCK")
    assert_includes G.state[:commands], "KICK"
    assert_includes G.state[:commands], "MLOCK"
  end

  # --- events ------------------------------------------------------------------------------------

  def test_watchdog
    online!
    G.irc_event("IRCnet", "quit", ":Linuks!Linuks@bot.example QUIT :Ping timeout")
    assert_match(/Linuks quit IRCnet: Ping timeout/, lines.last)
    assert_equal :alert, GemdropUI.log.last.kind
    assert_equal "3", Weechat.buffers["0xgemdrop"]["hotlist"]
    G.irc_event("IRCnet", "join", ":Linuks!Linuks@bot.example JOIN #linux.se")
    assert_match(/Linuks is back on IRCnet/, lines.last)
    assert_equal [4000, "botback|IRCnet"], Weechat.timers.last
    G.irc_event("IRCnet", "kick", ":op!o@h KICK #linux.se Linuks :out")
    assert_match(/kicked from #linux.se on IRCnet by op: out/, lines.last)
  end

  def test_the_bot_coming_back_checks_the_login
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    G.timer("botback|IRCnet")
    assert_equal "PRIVMSG Linuks :WHOAMI", irc.last
    bot_says("You are not identified.")
    online!
    assert_equal "PRIVMSG Linuks :IDENTIFY zphinx sesame", irc.last
  end

  def test_autosummary_on_rejoin_is_spread_out
    Weechat.options["autosummary"] = "IRCnet/#linux.se,IRCnet/#other"
    G.irc_event("IRCnet", "join", ":zphinx!z@h JOIN #linux.se")
    G.irc_event("IRCnet", "join", ":zphinx!z@h JOIN #other")
    assert_equal [[6000, "summary|IRCnet|#linux.se"], [26_000, "summary|IRCnet|#other"]],
                 Weechat.timers.select { |_, data| data.start_with?("summary") }
    G.timer("summary|IRCnet|#linux.se")
    assert_equal "PRIVMSG Linuks :AISUMMARY #linux.se", irc.last
  end

  # --- /gemdrop ------------------------------------------------------------------------------------

  def test_channel_commands_use_the_current_channel
    G.command("0xchan", "kick bob be nice")
    G.command("0xchan", "summary 3")
    G.command("0xchan", "agent on")
    G.command("0xchan", "up #other")
    G.command("0xchan", "access")
    G.command("0xchan", "set ai #linux.se chat on")
    assert_equal ["PRIVMSG Linuks :KICK #linux.se bob be nice", "PRIVMSG Linuks :AISUMMARY #linux.se 3",
                  "PRIVMSG Linuks :AIAGENT #linux.se on", "PRIVMSG Linuks :UP #other",
                  "PRIVMSG Linuks :ACCESS #linux.se LIST", "PRIVMSG Linuks :PLUGIN SET ai #linux.se chat on"], irc
  end

  def test_another_server_with_at
    Weechat.servers["EFnet"] = { connected: true, nick: "zphinx" }
    Weechat.options["bots"] = "IRCnet=Linuks,EFnet=Linuks"
    G.command("0xchan", "whoami @EFnet")
    G.command("0xchan", "@EFnet logout")
    assert_equal ["EFnet;;1;;/quote -server EFnet PRIVMSG Linuks :WHOAMI",
                  "EFnet;;1;;/quote -server EFnet PRIVMSG Linuks :LOGOUT"], Weechat.sent
  end

  def test_the_buffer_takes_bot_commands
    G.command("0xchan", "")
    G.input("WHOAMI")
    assert_equal "PRIVMSG Linuks :WHOAMI", irc.last
    G.input("@nowhere WHOAMI")
    assert_match(/No server called nowhere/, lines.last)
  end

  def test_status_bar_setup
    G.command("0xchan", "setup")
    assert_equal "buffer_name,lag,gemdrop", Weechat.config["weechat.bar.status.items"]
    G.command("0xchan", "setup")
    assert_equal "buffer_name,lag,gemdrop", Weechat.config["weechat.bar.status.items"]
  end

  def test_completion_and_bar_item
    G.complete("gemdrop_plugins", nil)
    assert_includes Weechat.completions, "ai"
    online!
    bot_says("You are identified as zphinx.")
    assert_equal "gd:Linuks online, ✓ zphinx", G.bar_item("0xchan")
  end

  # WeeChat calls the bar item with (data, item, window).
  def test_the_bar_item_callback_takes_a_window
    online!
    bot_says("You are identified as zphinx.")
    Weechat.windows = { "0xwin" => "0xchan" }
    assert_equal "gd:Linuks online, ✓ zphinx", gemdrop_bar_item_cb("", "gemdrop", "0xwin")
    Weechat.current = "0xchan"
    assert_equal "gd:Linuks online, ✓ zphinx", gemdrop_bar_item_cb("", "gemdrop", ""), "a root bar: the current buffer"
    Weechat.windows = { "0xwin" => "0xserver" }
    assert_equal "gd:Linuks online, ✓ zphinx", gemdrop_bar_item_cb("", "gemdrop", "0xwin")
  end

  # --- key logins ------------------------------------------------------------------------------

  def trusted_with_key!
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    G.ensure_key
  end

  def challenge_text(account = "zphinx") = "gemdrop-auth:IRCnet:#{account}:#{'ab' * 16}:1760000000"

  def test_the_key_is_made_for_gemdrop_and_encrypted
    G.command("0xserver", "key create")
    path = File.join(@tmpdir, "gemdrop", "key.pem")
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
    assert_includes File.read(path), "ENCRYPTED PRIVATE KEY"
    assert_equal 64, Weechat.secure["gemdrop_key"].length, "its passphrase is in /secure"
    assert(lines.any? { |l| l.match?(/Made your Gemdrop key: SHA256:\S+/) })
    assert(lines.any? { |l| l.match?(/Public key: ssh-ed25519 \S+ gemdrop-weechat@/) })
    refute G.ensure_key, "made once"
  end

  def test_key_add_gives_the_bot_the_public_key
    G.command("0xserver", "key add laptop")
    assert_match(/\APRIVMSG Linuks :KEY ADD ssh-ed25519 [A-Za-z0-9+\/=]{60,} laptop\z/, irc.last)
    bot_says("Added SHA256:abc (laptop). Log in with AUTH from now on.")
    assert_equal "IRCnet", Weechat.options["key_logins"]
  end

  def test_a_key_login_signs_the_challenge
    trusted_with_key!
    Weechat.options["key_logins"] = "IRCnet"
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    G.identify("IRCnet")
    online!
    assert_equal "PRIVMSG Linuks :AUTH zphinx", irc.last, "the key, not the password"
    bot_says("Challenge: #{challenge_text} (sign it with ssh-keygen -Y sign -n gemdrop and send AUTH <signature> within 60s)")
    signature = irc.last[/\APRIVMSG Linuks :AUTH (\S+)\z/, 1]
    assert signature
    assert(lines.any? { |l| l.include?("AUTH <signature by SHA256:") })
    refute(irc.any? { |l| l.include?("sesame") })

    if system("command -v ssh-keygen >/dev/null 2>&1")
      allowed = File.join(@tmpdir, "allowed")
      File.write(allowed, "zphinx #{G.public_line}\n")
      sig_file = File.join(@tmpdir, "sig")
      File.write(sig_file, "-----BEGIN SSH SIGNATURE-----\n#{signature.scan(/.{1,70}/).join("\n")}\n-----END SSH SIGNATURE-----\n")
      out, status = Open3.capture2e("ssh-keygen", "-Y", "verify", "-f", allowed, "-I", "zphinx", "-n", "gemdrop",
                                    "-s", sig_file, stdin_data: challenge_text)
      assert status.success?, "ssh-keygen accepts it: #{out}"
    end
    bot_says("You are now identified as zphinx.")
    assert_equal "zphinx", G.state[:identified]["ircnet"]
  end

  def test_only_our_challenges_from_the_trusted_bot_are_signed
    trusted_with_key!
    G.identify("IRCnet", method: :key)
    online!
    bot_says("Challenge: #{challenge_text('someoneelse')} (sign it)")
    assert_equal "PRIVMSG Linuks :AUTH zphinx", irc.last, "not signed"
    assert_match(/isn't for zphinx: not signed/, lines.last)

    G.identify("IRCnet", method: :key)
    online!
    bot_says("Challenge: #{challenge_text} (sign it)", from: "Linuks!x@evil.example")
    assert_equal "PRIVMSG Linuks :AUTH zphinx", irc.last, "an impostor's challenge isn't signed"
    bot_says("Challenge: #{challenge_text} (sign it)")
    assert_match(/\APRIVMSG Linuks :AUTH \S{100,}\z/, irc.last)
  end

  def test_unasked_challenges_are_ignored
    trusted_with_key!
    bot_says("Challenge: #{challenge_text} (sign it)")
    assert_empty irc
  end

  def test_a_failed_key_login_falls_back_to_the_password
    trusted_with_key!
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    Weechat.options["key_logins"] = "IRCnet"
    G.identify("IRCnet")
    online!
    bot_says("Key login failed: that isn't a signature of the challenge by one of the account's keys.")
    online!
    assert_equal "PRIVMSG Linuks :IDENTIFY zphinx sesame", irc.last
    assert_equal "", Weechat.options["key_logins"]
  end

  def test_a_key_only_account_switches_to_the_key
    trusted_with_key!
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    bot_says("zphinx only takes key logins: AUTH (see HELP AUTH).")
    online!
    assert_equal "PRIVMSG Linuks :AUTH zphinx", irc.last
  end

  def test_choosing_how_to_log_in
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    assert_equal :password, G.login_method("IRCnet")
    G.ensure_key
    assert_equal :password, G.login_method("IRCnet"), "a key the bot may not know"
    Weechat.options["key_logins"] = "IRCnet"
    assert_equal :key, G.login_method("IRCnet")
    Weechat.options["login"] = "password"
    assert_equal :password, G.login_method("IRCnet")
    Weechat.secure.delete("gemdrop_ircnet")
    assert_nil G.login_method("IRCnet")
    Weechat.options["login"] = "auto"
    Weechat.options["key_logins"] = ""
    assert_equal :key, G.login_method("IRCnet"), "no password: the key"
    assert_equal :key, G.login_method("IRCnet", :key)
  end

  # --- logging in by itself ---------------------------------------------------------------------

  def with_password!
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
  end

  def test_connecting_logs_in_after_the_delay
    with_password!
    Weechat.options["identify_delay"] = "8"
    G.connected("IRCnet")
    assert_equal [8000, "connected|IRCnet"], Weechat.timers.last
    G.timer("connected|IRCnet")
    online!
    assert_equal "PRIVMSG Linuks :IDENTIFY zphinx sesame", irc.last
  end

  def test_each_occasion_can_be_turned_off
    with_password!
    Weechat.options["identify_on_connect"] = "off"
    G.timer("connected|IRCnet")
    online!
    assert_equal "PRIVMSG Linuks :WHOAMI", irc.last, "only a check"
    bot_says("You are not identified.")
    assert_equal "PRIVMSG Linuks :WHOAMI", irc.last, "and no login"

    Weechat.options["identify_on_request"] = "off"
    bot_says("You must IDENTIFY first.")
    assert_equal "PRIVMSG Linuks :WHOAMI", irc.last

    Weechat.options["identify_on_bot"] = "off"
    G.irc_event("IRCnet", "join", ":zphinx!z@h JOIN #linux.se")
    refute(Weechat.timers.any? { |_, data| data.start_with?("seen") })
  end

  def test_the_master_switch
    with_password!
    Weechat.options["autoidentify"] = "off"
    refute G.auto?(:connect)
    refute G.auto?(:bot)
    Weechat.options["autoidentify"] = "on"
    assert G.auto?(:connect)
  end

  def test_joining_a_channel_with_the_bot_logs_in
    with_password!
    online!
    Weechat.sent.clear
    G.irc_event("IRCnet", "join", ":zphinx!z@h JOIN #linux.se")
    assert_equal [3000, "seen|IRCnet|#linux.se"], Weechat.timers.last
    G.timer("seen|IRCnet|#linux.se")
    assert_empty irc, "the bot isn't in it"
    Weechat.nicks["IRCnet,#linux.se,Linuks"] = true
    G.timer("seen|IRCnet|#linux.se")
    assert_equal ["PRIVMSG Linuks :WHOAMI"], irc
    bot_says("You are not identified.")
    online!
    assert_equal "PRIVMSG Linuks :IDENTIFY zphinx sesame", irc.last
  end

  def test_the_periodic_check_logs_in_when_logged_out
    with_password!
    G.timer("check")
    G.userhost_answered("IRCnet", ":fake.server 302 zphinx :Linuks=+Linuks@bot.example", "")
    assert_equal "PRIVMSG Linuks :WHOAMI", irc.last
    bot_says("You are identified as zphinx.")
    Weechat.sent.clear
    G.timer("check")
    G.userhost_answered("IRCnet", ":fake.server 302 zphinx :Linuks=+Linuks@bot.example", "")
    assert_equal ["USERHOST Linuks"], irc, "logged in: just the check"
  end

  def test_the_bot_getting_its_nick_back
    with_password!
    G.irc_event("IRCnet", "nick", ":Linuks_!Linuks@bot.example NICK :Linuks")
    assert_match(/Linuks is back on IRCnet \(got its nick back\)/, lines.last)
    assert_equal [3000, "botback|IRCnet"], Weechat.timers.last
    assert_equal "Linuks@bot.example", G.state[:bot_host]["ircnet"]
  end

  # --- the dashboard ------------------------------------------------------------------------------

  UI = "0xgemdrop"

  def screen = Weechat.screen.sort.map(&:last)
  def ui(*words) = GemdropUI.command(UI, words)
  def selected_line = screen.find { |l| l.start_with?("❯") }

  def select_line(text)
    GemdropUI.move(-10_000)
    50.times do
      GemdropUI.render
      return if selected_line.to_s.include?(text)

      GemdropUI.move(1)
    end
    flunk "no line with #{text.inspect}: #{screen.join("\n")}"
  end

  def test_gd_opens_the_dashboard
    G.command("0xchan", "")
    buf = Weechat.buffers[UI]
    assert_equal "free", buf["type"]
    assert_equal "/gd ui down", buf["key_bind_down"]
    assert_equal "/gd ui tab 3", buf["key_bind_meta-3"]
    assert_equal "/gd ui key i", buf["key_bind_i"]
    assert_equal "/gd ui click ${_chat_line_y} ${_chat_line_x}", Weechat.keybinds["@chat(ruby.gemdrop):button1*"]
    assert_match(/Gemdrop .*IRCnet/, screen[0])
    assert_match(/ 1 Status .* 2 Commands .* 3 Channels .* 4 Keys .* 5 Settings .* 6 Log /, screen[1])
    refute_match(/Bot/, screen[1], "the Bot tab is for bot admins")
    G.command("0xchan", "log")
    assert_equal "log", GemdropUI.tab, "/gd log: the same window, on its log"
    assert_equal ["0xgemdrop"], Weechat.buffers.keys.grep(/gemdrop/), "one window"
  end

  def test_status_tab_logs_in
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    G.command("0xchan", "")
    assert_match(/IRCnet/, selected_line)
    assert(screen.any? { |l| l.include?("logs in with: password") })
    ui("enter")
    online!
    assert_equal "PRIVMSG Linuks :IDENTIFY zphinx sesame", irc.last
    ui("key", "w")
    assert_equal "PRIVMSG Linuks :WHOAMI", irc.last
    bot_says("You are now identified as zphinx.")
    assert(screen.any? { |l| l.include?("✓ logged in as zphinx") }, "redrawn as things change")
    assert(screen.any? { |l| l.include?("You are now identified as zphinx.") }, "the latest lines, at the bottom")
    assert(screen.any? { |l| l.include?("→ Linuks: WHOAMI") }, "and what you sent")
  end

  def test_settings_toggle_cycle_and_edit
    G.command("0xchan", "")
    ui("tab", "settings")
    select_line("identify_on_load")
    ui("enter")
    assert_equal "off", Weechat.options["identify_on_load"]
    assert_match(/identify_on_load +off \*/, selected_line, "marked as changed")
    ui("key", "d")
    assert_equal "on", Weechat.options["identify_on_load"]

    select_line("login ")
    ui("enter")
    assert_equal "key", Weechat.options["login"]
    ui("enter")
    assert_equal "password", Weechat.options["login"]

    select_line("identify_delay")
    ui("enter")
    assert_equal "5", Weechat.buffers[UI]["input"], "the value, to edit in place"
    assert_match(/identify_delay:/, Weechat.buffers[UI]["input_prompt"])
    Weechat.buffers[UI]["input"] = "9"
    ui("enter")
    assert_equal "9", Weechat.options["identify_delay"]
    assert_equal "", Weechat.buffers[UI]["input"]
    assert_equal "", Weechat.buffers[UI]["input_prompt"]
    assert(screen.any? { |l| l.include?("seconds after connecting") }, "the selected setting's description")
  end

  def test_moving_away_cancels_a_field
    G.command("0xchan", "")
    ui("tab", "settings")
    select_line("identify_delay")
    ui("enter")
    assert_equal "5", Weechat.buffers[UI]["input"]
    Weechat.buffers[UI]["input"] = "77"
    ui("down")
    refute GemdropUI.ui[:edit]
    assert_equal "", Weechat.buffers[UI]["input"]
    assert_equal "", Weechat.buffers[UI]["input_prompt"]
    assert_equal "5", G.option("identify_delay"), "nothing changed"
  end

  def test_letters_type_when_the_input_has_text
    G.command("0xchan", "")
    Weechat.buffers[UI]["input"] = "/gd sta"
    ui("key", "i")
    assert_equal "/input insert i", Weechat.commands.last
    assert_empty irc
  end

  def test_keys_tab_lists_and_deletes_bot_keys
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    online!
    bot_says("You are now identified as zphinx.")
    G.ensure_key
    G.command("0xchan", "")
    ui("tab", "keys")
    assert_equal "PRIVMSG Linuks :KEY LIST", irc.last, "fetched when the tab opens"
    bot_says("1. #{G.key_text} gemdrop-weechat@home, added 2026-10-12, last used 2026-10-12")
    bot_says("2. SHA256:abcdefghijk laptop, added 2026-10-01, never used")
    bot_says("Password logins to zphinx: allowed.")
    assert(screen.any? { |l| l.include?("(this one)") })
    assert(screen.any? { |l| l.include?("Password logins: allowed") })
    select_line("SHA256:abcdefghijk")
    ui("key", "d")
    refute_equal "PRIVMSG Linuks :KEY DEL 2", irc.last, "asks first"
    assert(screen.any? { |l| l.include?("Press again to confirm") })
    ui("key", "d")
    assert_equal "PRIVMSG Linuks :KEY DEL 2", irc.last
    bot_says("Removed SHA256:abcdefghijk (laptop).")
    assert_equal "PRIVMSG Linuks :KEY LIST", irc.last, "and fetched again"
  end

  def test_keys_tab_without_a_key_makes_one
    G.command("0xchan", "")
    ui("tab", "keys")
    assert_match(/none yet/, selected_line)
    ui("enter")
    assert G.key_exists?
    assert_match(/SHA256:/, selected_line)
  end

  def test_channels_tab_toggles_automations
    Weechat.nicks["IRCnet,#linux.se,Linuks"] = true
    G.command("0xchan", "")
    ui("tab", "channels")
    assert_match(/#linux\.se +✓ +- +\[ \] +\[ \]/, selected_line)
    ui("key", "u")
    assert_equal "IRCnet/#linux.se", Weechat.options["autoup"]
    ui("key", "s")
    assert_equal "IRCnet/#linux.se", Weechat.options["autosummary"]
    assert_match(/\[x\] +\[x\]/, selected_line)
    ui("key", "u")
    assert_equal "", Weechat.options["autoup"]
    ui("key", "S")
    assert_equal "PRIVMSG Linuks :AISUMMARY #linux.se", irc.last
  end

  def test_tabs_by_keys_and_mouse
    G.command("0xchan", "")
    ui("next")
    assert_equal "commands", GemdropUI.tab
    ui("prev")
    assert_equal "status", GemdropUI.tab
    tabs = screen[1]
    ui("click", "1", (tabs.index("3 Channels") + 1).to_s)
    assert_equal "channels", GemdropUI.tab
  end

  def test_q_closes_and_shutdown_unbinds_the_mouse
    G.command("0xchan", "")
    ui("key", "q")
    refute Weechat.buffers.key?(UI)
    gemdrop_shutdown_cb
    assert_empty Weechat.keybinds
  end

  # --- one window: log, typing, the bot tab -------------------------------------------------------

  def test_everything_is_in_one_window
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    G.command("0xchan", "")
    ui("enter") # log in from the status tab
    online!
    bot_says("You are now identified as zphinx.")
    assert_equal ["0xgemdrop"], Weechat.buffers.keys.grep(/gemdrop/), "no second window"
    assert(screen.any? { |l| l.include?("You are now identified as zphinx.") }, "the result shows where you are")
  end

  def test_typing_sends_to_the_bot
    G.command("0xchan", "")
    Weechat.buffers[UI]["input"] = "HELP access"
    ui("enter")
    assert_equal "PRIVMSG Linuks :HELP access", irc.last
    Weechat.buffers[UI]["input"] = "/gd status"
    ui("enter")
    assert_equal "/gd status", Weechat.commands.last, "commands still run"
  end

  def test_the_log_tab_scrolls_and_keeps_history
    G.command("0xchan", "")
    60.times { |i| G.note("line #{i}") }
    ui("tab", "log")
    assert(screen.any? { |l| l.include?("line 59") })
    ui("pgup")
    refute(screen.any? { |l| l.include?("line 59") }, "scrolled back")
    assert(screen.any? { |l| l.include?("newer lines below") })
    ui("last")
    assert(screen.any? { |l| l.include?("line 59") })

    history = File.join(@tmpdir, "gemdrop", "history.log")
    assert_equal 0o600, File.stat(history).mode & 0o777
    GemdropUI.reset!
    GemdropUI.load_history
    assert_equal "line 59", GemdropUI.log.last.plain, "read back after a restart"
  end

  def test_the_bot_tab_lists_plugins_and_edits_settings
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    online!
    bot_says("You are now identified as zphinx.")
    catalog!("@me zphinx admin")
    G.command("0xchan", "")
    ui("tab", "bot")
    assert_equal "PRIVMSG Linuks :PLUGIN LIST", irc.last
    bot_says("ai: loaded, commands AI, AIFORGET (private messages). Talks with people")
    bot_says("help: loaded, commands HELP, LIST, MORE (private messages). Layered help")
    select_line("ai ")
    ui("enter")
    assert_equal "PRIVMSG Linuks :PLUGIN SETTINGS ai", irc.last
    bot_says("ai: chat = false")
    bot_says("ai: max_reply_lines = 3 (saved with PLUGIN SET)")
    select_line("chat")
    ui("enter")
    assert_equal "PRIVMSG Linuks :PLUGIN SET ai chat true", irc.last, "a boolean toggles"
    select_line("max_reply_lines")
    assert_match(/\(set here\)/, selected_line)
    ui("enter")
    assert_equal "3", Weechat.buffers[UI]["input"], "anything else is edited"
    ui("key", "x")
    assert_equal "/input insert x", Weechat.commands.last, "while editing, letters type"
    Weechat.buffers[UI]["input"] = "4"
    ui("enter")
    assert_equal "PRIVMSG Linuks :PLUGIN SET ai max_reply_lines 4", irc.last
    ui("key", "x")
    ui("key", "x")
    assert_equal "PRIVMSG Linuks :PLUGIN UNSET ai max_reply_lines", irc.last
    G.state[:sent_at].clear # (time passes: the pacing allows more)
    bot_says("ai: max_reply_lines is back to config.yml's value (or the default) on IRCnet")
    assert_equal "PRIVMSG Linuks :PLUGIN SETTINGS ai", irc.last, "and fetched again"
  end

  def test_networks_in_settings
    Weechat.secure["gemdrop_ircnet"] = "sesame"
    Weechat.options["hostmasks"] = "IRCnet=*@bot.example"
    G.command("0xchan", "")
    ui("tab", "settings")
    select_line("IRCnet password")
    assert_match(/kept/, selected_line)
    ui("enter")
    assert_match(/IRCnet password:/, Weechat.buffers[UI]["input_prompt"])
    assert_equal "*****", gemdrop_mask_cb("", "input_text_display", UI, "hello"), "hidden as you type"
    Weechat.buffers[UI]["input"] = "new-secret"
    ui("enter")
    assert_equal "new-secret", Weechat.secure["gemdrop_ircnet"]
    refute(lines.any? { |l| l.include?("new-secret") })
    ui("key", "x")
    assert Weechat.secure["gemdrop_ircnet"], "asks first"
    ui("key", "x")
    assert_nil Weechat.secure["gemdrop_ircnet"]
    select_line("IRCnet bot host")
    ui("key", "x")
    ui("key", "x")
    assert_equal "", Weechat.options["hostmasks"]
  end

  # --- commands at your access level, as forms ------------------------------------------------------

  def catalog!(*lines)
    lines.each { |line| bot_says(line) }
    count = lines.count { |l| l.start_with?("@cmd ") }
    bot_says("@end #{count}")
  end

  OP_CATALOG = [
    "@me zphinx user", "@level #linux.se op",
    "@cmd WHOAMI|Account|anyone|*|show who you are identified as|WHOAMI",
    "@cmd KICK|Channel|op|#linux.se|kick someone|KICK [#chan] <nick> [reason]",
    "@cmd MLOCK|Channel|owner|#other|lock modes|MLOCK <#chan> [<modes> [params]|-]",
    "@cmd KEY|Account|identified|*|your SSH keys for AUTH|KEY ADD <ssh-ed25519 key> [comment] | LIST | DEL <which>",
    "@cmd TOPIC|Channel|op|#linux.se|set the topic|TOPIC [#chan] <text>",
    "@cmd CATALOG|Help|anyone|*|for programs|CATALOG"
  ].freeze

  def test_the_catalog_is_kept_out_of_the_log
    catalog!(*OP_CATALOG)
    refute(lines.any? { |l| l.include?("@cmd") })
    cat = G.state[:catalog]["ircnet"]
    assert_equal "user", cat[:role]
    assert_equal({ "#linux.se" => "op" }, cat[:levels])
    assert_equal "#linux.se", cat[:commands].find { |c| c[:name] == "KICK" }[:where]
    assert cat[:complete]
  end

  def test_several_commands_share_a_catalog_line
    bot_says("@me zphinx user")
    bot_says("@cmd WHOAMI|Account|anyone|*|who you are|WHOAMI @cmd KEY|Account|identified|*|keys|KEY ADD <k> | LIST")
    assert_equal %w[WHOAMI KEY], G.catalog_for("IRCnet")[:commands].map { |c| c[:name] }
    assert_equal "KEY ADD <k> | LIST", G.catalog_for("IRCnet")[:commands].last[:usage]
    refute G.catalog_for("IRCnet")[:complete], "shown while it arrives"
    bot_says("@end 2")
    assert G.catalog_for("IRCnet")[:complete]
  end

  def test_logging_in_and_out_fetches_the_catalog
    bot_says("You are now identified as zphinx.")
    assert_includes Weechat.sent.last, ":CATALOG"
    Weechat.sent.clear
    G.instance_variable_set(:@catalog_asked, nil)
    bot_says("You are now logged out.")
    assert_includes Weechat.sent.last, ":CATALOG", "a guest's view now"
  end

  def test_the_commands_tab_shows_what_you_may_do
    catalog!(*OP_CATALOG)
    G.command("0xchan", "")
    ui("tab", "commands")
    assert(screen.any? { |l| l.include?("op in #linux.se") }, "your access")
    assert(screen.any? { |l| l.match?(/KICK +kick someone \(#linux\.se\)/) }, "op commands, and where")
    refute(screen.any? { |l| l.include?("CATALOG ") }, "the window's own")
    select_line("WHOAMI")
    ui("enter")
    assert(screen.any? { |l| l.include?("▶ Send") })
    select_line("Send")
    ui("enter")
    assert_equal "PRIVMSG Linuks :WHOAMI", irc.last
    refute GemdropUI.ui[:form], "closed once sent"
  end

  def test_a_form_with_pickers_and_text
    Weechat.nicks["IRCnet,#linux.se,bob"] = true
    catalog!(*OP_CATALOG)
    G.command("0xchan", "")
    ui("tab", "commands")
    select_line("KICK")
    ui("enter")
    select_line("Send")
    ui("enter")
    assert_empty irc, "nothing sent while the nick is missing"
    select_line("Channel")
    ui("enter")
    assert(screen.any? { |l| l.include?("Choose: Channel") })
    select_line("#linux.se")
    ui("enter")
    select_line("Nick")
    ui("enter")
    select_line("bob")
    ui("enter")
    select_line("Reason")
    ui("enter")
    assert_match(/reason:/, Weechat.buffers[UI]["input_prompt"])
    Weechat.buffers[UI]["input"] = "be nice"
    ui("enter")
    assert(screen.any? { |l| l.include?("KICK #linux.se bob be nice") }, "a preview of what is sent")
    select_line("Send")
    ui("enter")
    assert_equal "PRIVMSG Linuks :KICK #linux.se bob be nice", irc.last
  end

  def test_a_form_with_several_forms
    catalog!(*OP_CATALOG)
    G.command("0xchan", "")
    ui("tab", "commands")
    select_line("KEY ")
    ui("enter")
    select_line("DEL <which>")
    ui("enter")
    select_line("Which")
    ui("enter")
    Weechat.buffers[UI]["input"] = "2"
    ui("enter")
    select_line("Send")
    ui("enter")
    assert_equal "PRIVMSG Linuks :KEY DEL 2", irc.last
  end

  def test_left_and_q_go_back
    catalog!(*OP_CATALOG)
    G.command("0xchan", "")
    ui("tab", "commands")
    select_line("KICK")
    ui("enter")
    select_line("Channel")
    ui("enter")
    ui("left")
    refute GemdropUI.ui[:picker]
    assert GemdropUI.ui[:form]
    ui("key", "q")
    refute GemdropUI.ui[:form]
    assert Weechat.buffers.key?(UI), "q went back, it didn't close the window"
  end

  def test_a_channel_offers_its_commands
    catalog!(*OP_CATALOG)
    G.command("0xchan", "")
    ui("tab", "channels")
    select_line("#linux.se")
    assert_match(/#linux\.se +· +op/, selected_line, "your level there")
    ui("enter")
    assert(screen.any? { |l| l.include?("Choose: a command for #linux.se") })
    assert(screen.any? { |l| l.match?(/(\A|❯| )KICK\z/) })
    refute(screen.any? { |l| l.match?(/MLOCK\z/) }, "only commands your level allows in this channel")
    select_line("TOPIC")
    ui("enter")
    assert(screen.any? { |l| l.match?(/Channel +#linux\.se/) }, "the channel filled in")
  end

  def test_admins_get_the_bot_tab
    G.command("0xchan", "")
    refute(screen[1].include?("Bot"))
    catalog!("@me zphinx admin")
    assert_match(/5 Bot/, screen[1])
  end

  # --- text that isn't ASCII --------------------------------------------------------------------

  def test_channels_and_replies_with_aao
    Weechat.channels["IRCnet"] = ["#norrköping"]
    Weechat.nicks["IRCnet,#norrköping,Linuks"] = true
    G.command("0xchan", "")
    ui("tab", "channels")
    assert(screen.any? { |l| l.include?("#norrköping") })
    gemdrop_notice_cb("", "irc_in2_notice", "IRCnet".b, ":Linuks!Linuks@bot.example NOTICE zphinx :Hej, här är svaret på din fråga │ ✓".b)
    assert_equal "Hej, här är svaret på din fråga │ ✓", GemdropUI.log.last.plain
    assert(screen.any? { |l| l.include?("Hej, här är svaret") }, "shown at the bottom")
    ui("dump")
    assert(lines.any? { |l| l.include?("#norrköping") }, "the dump works too")
  end

  # --- answers to what you type yourself -----------------------------------------------------------

  def test_answers_to_what_you_type_show_where_you_typed
    raw = ":Linuks!Linuks@bot.example NOTICE zphinx :Start with LIST for the command groups"
    G.send_bot("IRCnet", "WHOAMI")
    gemdrop_out_cb("", "IRCnet,irc_out1_privmsg", "PRIVMSG Linuks :WHOAMI")
    assert_equal "", G.notice_in("IRCnet", raw), "an answer to the script's own: the window only"

    gemdrop_out_cb("", "IRCnet,irc_out1_privmsg", "PRIVMSG Linuks :HELP") # typed: /msg Linuks HELP
    assert_equal raw, G.notice_in("IRCnet", raw), "shown where you typed it"
    assert_equal "Start with LIST for the command groups", GemdropUI.log.last.plain, "and kept in the window's log"
    gemdrop_out_cb("", "IRCnet,irc_out1_privmsg", "PRIVMSG #linux.se :hello")
    assert_equal raw, G.notice_in("IRCnet", raw)
  end
end
