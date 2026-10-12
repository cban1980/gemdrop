require "test_helper"

# The help plugin (contrib/plugins/help.rb): layered HELP, LIST and MORE,
# built from the help catalog (the core's commands, plugins' commands and
# the topics plugins publish).
class HelpPluginTest < Minitest::Test
  include StoreHelper

  GADGETS = <<~RUBY.freeze
    class Gadgets < Gemdrop::Plugin
      description "Handy gadgets"
      help_topic "sums", "Write sums like 2+2.\\nAsk %<nick>s nicely.", summary: "sum syntax"
      command "CALC", usage: "CALC [SUM]", help: "calculate", details: "Default 1+1.\\nAt most 10 terms.\\nNumbers up to 1000.\\nTotals add up.",
                      aliases: %w[C] do |ctx, _|
        ctx.reply("4")
      end
      command "SECRETCALC", help: "admins only", admin: true do |ctx, _|
        ctx.reply("6")
      end
      command "TABLECALC", usage: "TABLECALC", help: "in channels only", where: :channel do |ctx, _|
        ctx.reply("5")
      end
    end
  RUBY

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    File.write(File.join(@plugins_dir, "help.rb"),
               File.read(File.expand_path("../contrib/plugins/help.rb", __dir__)), perm: 0o600)
    File.write(File.join(@plugins_dir, "gadgets.rb"), GADGETS, perm: 0o600)
    install_plugins(@plugins_dir, "chanserv") # the Channel group and the levels topic
  end

  def start(settings = "")
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML + settings, perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      admins: [root]
      require_secure_users: false
      plugins:
        gadgets:
          prefix: "!"
    YAML
    @now = 0
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), connection: @conn, store: @store, hasher: TEST_HASHER,
                                                         clock: -> { @now }, logger: Logger.new(nil))
    @bot.handle(":server 001 Gemdrop :Welcome")
  end

  # Each question 31 s apart, clear of the per-host command limit.
  def ask(text, nick: "alice")
    @now += 31
    @conn.clear
    @bot.handle(":#{nick}!#{nick}@#{nick}.host PRIVMSG Gemdrop :#{text}")
    @conn.lines.grep(/\ANOTICE #{nick} :/).map { |l| l.split(" :", 2).last }
  end

  def admin!
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("root", "password123")
    ask("IDENTIFY password123", nick: "root")
  end

  def test_help_alone_is_short
    start
    assert_equal ["Start with LIST for the command groups, then LIST <group> for its commands and HELP <command> " \
                  "for one. MORE continues a long answer.",
                  "Topics: levels · sums · accounts - HELP <topic>"], ask("HELP")
  end

  def test_list_shows_groups_on_one_line_and_hides_admin_ones
    start
    lines = ask("LIST")
    assert_equal ["Command groups: Account (5) · Channel (10) · gadgets (2) · Help (3)",
                  "LIST <group> shows a group's commands, e.g. LIST account."], lines

    admin!
    assert_equal "Command groups: Account (5) · Admin (1) · Channel (11) · gadgets (3) · Help (3)",
                 ask("LIST", nick: "root").first
  end

  def test_list_a_group
    start
    assert_equal ["Account commands: REGISTER · IDENTIFY · LOGOUT · PASSWORD · WHOAMI",
                  "HELP <command> explains one, e.g. HELP register."], ask("LIST account")
    assert_equal "gadgets commands: CALC · !tablecalc", ask("COMMANDS gadgets").first
    assert_equal ["No group called Admin. LIST shows the groups."], ask("LIST Admin")
    assert_equal ["No group called acount. Did you mean Account? LIST shows the groups."], ask("LIST acount")
    assert_equal "Help commands: HELP · LIST · MORE", ask("LIST help").first
  end

  def test_help_on_a_command_is_one_line_then_details_then_more
    start
    lines = ask("HELP c")
    assert_equal ["CALC [SUM] - calculate.",
                  "Who: anyone · Use: /msg Gemdrop CALC, or !calc in channels · Also: C · From the gadgets plugin.",
                  "Default 1+1. (MORE for 3 more lines)"], lines
    assert_equal ["At most 10 terms.", "Numbers up to 1000.", "Totals add up."], ask("MORE")
    assert_equal ["Nothing more."], ask("MORE")
  end

  def test_core_command_help
    start
    assert_equal ["ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ... - manage a channel's access list.",
                  "Who: op and above on the channel · Use: /msg Gemdrop ACCESS · From the chanserv plugin."],
                 ask("HELP access").first(2)
    assert_equal "Who: anyone · Use: !tablecalc in channels · From the gadgets plugin.", ask("HELP !tablecalc")[1]
    assert_equal ["No help for SECRETCALC. Did you mean CALC? LIST shows the command groups."], ask("HELP SECRETCALC"),
                 "admin commands stay hidden, even as suggestions"
    assert_equal ["No help for whoam. Did you mean WHOAMI? LIST shows the command groups."], ask("HELP whoam")
    assert_equal ["No help for xyzzy. LIST shows the command groups."], ask("HELP xyzzy")
  end

  def test_topics_plugins_and_name_clashes
    start
    assert_equal ["Write sums like 2+2.", "Ask Gemdrop nicely."], ask("HELP sums")
    assert_includes ask("HELP accounts"), "/msg Gemdrop REGISTER <password> makes your current nick an account."
    assert_equal ["The gadgets plugin: Handy gadgets.", "Commands: CALC · !tablecalc", "Topics: sums (sum syntax)"],
                 ask("HELP plugin gadgets")

    File.write(File.join(@plugins_dir, "calc.rb"), "class Calc < Gemdrop::Plugin\n  description \"Shadowed\"\nend\n", perm: 0o600)
    @bot.send(:sync_plugins)
    assert_includes ask("HELP calc") + ask("MORE") + ask("MORE"), "HELP plugin calc describes the calc plugin."
    assert_equal ["No plugin called nope is loaded."], ask("HELP plugin nope")
  end

  def test_long_lists_are_packed_and_continued
    many = (1..60).map { |i| "  command(\"LONGCOMMAND#{i}\") { |ctx, _| ctx.reply('x') }" }.join("\n")
    File.write(File.join(@plugins_dir, "big.rb"), "class Big < Gemdrop::Plugin\n#{many}\nend\n", perm: 0o600)
    start(%(  help:\n    lines_per_answer: 2\n))
    lines = ask("LIST big")
    assert_equal 2, lines.size
    assert(lines.all? { |l| l.length <= 400 })
    assert_match(/\(MORE for \d+ more lines?\)\z/, lines.last)
    rest = ask("MORE")
    assert(rest.join.include?("LONGCOMMAND60"))
  end

  def test_unread_rest_expires
    start
    clock = 0
    @bot.send(:plugin_manager).plugin("help").define_singleton_method(:now) { clock }
    ask("HELP calc")
    clock += 700
    assert_equal ["Nothing more."], ask("MORE")
  end

  def test_intro_setting
    start(%(  help:\n    intro: "Gemdrop at your service"\n))
    assert_equal "Gemdrop at your service", ask("HELP").first
  end

  def test_unknown_commands_point_at_help_only_when_it_is_there
    start
    assert_equal ["Unknown command. Try HELP."], ask("FROBNICATE")
    File.delete(File.join(@plugins_dir, "help.rb"))
    @bot.send(:sync_plugins)
    assert_equal ["Unknown command."], ask("FROBNICATE")
  end

  def test_other_plugins_can_read_the_catalog
    start
    catalog = @bot.send(:plugin_manager).plugin("gadgets").help_catalog
    assert_equal "core", catalog.command("whoami").source
    assert_equal %w[CALC SECRETCALC TABLECALC], catalog.plugin("gadgets").commands.map(&:name)
    assert_equal "!", catalog.command("tablecalc").prefix
    refute catalog.command("tablecalc").private
    assert_equal "admin", catalog.command("secretcalc").access
  end

  def test_plugins_hook_in_with_live_topics_and_groups
    File.write(File.join(@plugins_dir, "status.rb"), <<~RUBY, perm: 0o600)
      class Status < Gemdrop::Plugin
        help_group "Fun"
        setting "mood", default: "cheerful", type: :string
        help_topic("mood", summary: "how the bot feels") { "Right now I'm \#{settings['mood']}.\nAsk %<nick>s again later." }
        help_topic("empty", summary: "nothing") { "" }
        command("MOOD", help: "the bot's mood") { |ctx, _| ctx.reply(settings["mood"]) }
      end
    RUBY
    File.write(File.join(@plugins_dir, "jokes.rb"), <<~RUBY, perm: 0o600)
      class Jokes < Gemdrop::Plugin
        help_group "Fun"
        command("JOKE", help: "a joke") { |ctx, _| ctx.reply("knock knock") }
      end
    RUBY
    start
    assert_includes ask("HELP mood"), "HELP topic mood is a help page about it."
    assert_equal ["Right now I'm cheerful.", "Ask Gemdrop again later."], ask("HELP topic mood")
    assert_equal ["Nothing to say about empty right now."], ask("HELP empty")
    assert_equal ["No help page called nope."], ask("HELP topic nope")
    assert(ask("LIST").first.include?("Fun (2)"))
    assert_equal ["Fun commands: JOKE · MOOD", "HELP <command> explains one, e.g. HELP joke."], ask("LIST fun")
    assert_equal ["The status plugin: no description.", "Commands: MOOD", "Topics: mood (how the bot feels) · empty (nothing)"],
                 ask("HELP plugin status")
  end

  def test_help_topic_needs_text_or_a_block
    assert_raises(ArgumentError) { Class.new(Gemdrop::Plugin) { help_topic("x") } }
    assert_raises(ArgumentError) { Class.new(Gemdrop::Plugin) { help_topic("x", "text") { "block" } } }
  end
end
