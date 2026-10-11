require "minitest/autorun"

# A stand-in for WeeChat's API, enough for contrib/weechat/gemdrop.rb.
module Weechat
  WEECHAT_RC_OK = 0
  WEECHAT_HOOK_SIGNAL_STRING = "string".freeze
  WEECHAT_LIST_POS_SORT = "sort".freeze

  class << self
    attr_accessor :options, :secure, :sent, :printed, :commands, :timers, :servers, :channels, :buffers, :current,
                  :nicks, :completions, :config

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
      @config = { "weechat.bar.status.items" => "buffer_name,lag" }
    end

    def config_get_plugin(name) = @options.fetch(name, GemdropScript::OPTIONS.dig(name, 0)).to_s
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
    def info_get(name, server) = name == "irc_nick" ? @servers.dig(server, :nick).to_s : ""

    # Infolists are arrays of hashes here.
    def infolist_get(name, _pointer, args)
      items =
        case name
        when "irc_server"
          @servers.select { |n, _| args.empty? || n == args }
                  .map { |n, s| { "name" => n, "is_connected" => s[:connected] ? 1 : 0 } }
        when "irc_channel" then @channels.fetch(args, []).map { |c| { "name" => c, "type" => 0 } }
        when "irc_nick" then @nicks[args] ? [{ "name" => args.split(",").last }] : []
        else []
        end
      { items: items, at: -1 }
    end

    def infolist_next(list)
      list[:at] += 1
      list[:at] < list[:items].size ? 1 : 0
    end

    def infolist_string(list, field) = list[:items][list[:at]][field].to_s
    def infolist_integer(list, field) = list[:items][list[:at]][field].to_i
    def infolist_free(_list) = nil

    def buffer_search(plugin, name)
      return "0xgemdrop" if plugin == "ruby" && name == "gemdrop" && @buffers.key?("0xgemdrop")

      @buffers.find { |_, b| b["name"] == name }&.first.to_s
    end

    def buffer_new(name, *)
      @buffers["0xgemdrop"] = { "name" => name, "plugin" => "ruby" }
      "0xgemdrop"
    end

    def buffer_set(buffer, property, value) = (@buffers[buffer] ||= {})[property] = value
    def buffer_get_string(buffer, property) = @buffers.fetch(buffer, {})[property].to_s
    def current_buffer = @current

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
    Weechat.options["bots"] = "IRCnet=Linuks"
  end

  def lines = Weechat.printed.map(&:last)

  # What reached IRC (the PRIVMSGs to the bot, and USERHOSTs).
  def irc = Weechat.sent.map { |s| s.split(";;", 3).last.sub(%r{\A/quote -server \S+ }, "") }

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
    assert_equal 7, irc.size, "7 per 31 s"
    assert_equal [[31_000, "flush|IRCnet"]], Weechat.timers.map { |ms, data| [ms.round(-3), data] }
    assert(lines.any? { |l| l.include?("Holding commands for Linuks for 31s") })
    G.state[:sent_at]["ircnet"].map! { |at| at - 31 } # time passes
    G.timer("flush|IRCnet")
    assert_equal 10, irc.size
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
    assert(lines.last.include?("NOT sending your password"))
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
    assert_equal "0xgemdrop", Weechat.printed.last[0]
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
    assert_includes Weechat.printed.last[1], "notify_highlight"
    assert_nil G.state[:identified]["ircnet"]
  end

  def test_settings_and_plugin_views
    G.send_view("IRCnet", "PLUGIN SETTINGS ai")
    bot_says("ai: chat = true (saved with PLUGIN SET)")
    assert_match(/\Achat {20} true \[saved\]\z/, lines.last.split("\t", 2).last)
    G.send_view("IRCnet", "PLUGIN LIST")
    bot_says("ai: loaded, commands AI, AISUMMARY (private messages). Talks")
    assert_match(/\Aai {11}loaded, commands AI/, lines.last.split("\t", 2).last)
    assert_includes G.state[:plugins], "ai"
    assert_includes G.state[:commands], "AISUMMARY"
    assert_includes G.state[:settings]["ai"], "chat"
  end

  # --- events ------------------------------------------------------------------------------------

  def test_watchdog
    online!
    G.irc_event("IRCnet", "quit", ":Linuks!Linuks@bot.example QUIT :Ping timeout")
    assert_match(/Linuks quit IRCnet: Ping timeout/, lines.last)
    assert_includes Weechat.printed.last[1], "notify_highlight"
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
    online!
    assert_equal "PRIVMSG Linuks :WHOAMI", irc.last
    bot_says("You are not identified.")
    online!
    assert_equal "PRIVMSG Linuks :IDENTIFY zphinx sesame", irc.last
  end

  def test_autosummary_on_rejoin_is_spread_out
    Weechat.options["autosummary"] = "IRCnet/#linux.se,IRCnet/#other"
    G.irc_event("IRCnet", "join", ":zphinx!z@h JOIN #linux.se")
    G.irc_event("IRCnet", "join", ":zphinx!z@h JOIN #other")
    assert_equal [[6000, "summary|IRCnet|#linux.se"], [26_000, "summary|IRCnet|#other"]], Weechat.timers
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
end
