require "test_helper"

# Nothing plugin specific lives in the core: no core file names a contrib
# plugin's commands or files, and the plugins use nothing of the core but
# the plugin API (Gemdrop::Plugin, Gemdrop::Error, Gemdrop::RateLimiter).
class ModularityTest < Minitest::Test
  CORE = Dir[File.expand_path("../lib/**/*.rb", __dir__)] + %w[gemdrop gemdrop-account gemdrop-keeper].map { |b| File.expand_path("../bin/#{b}", __dir__) }
  PLUGINS = Dir[File.expand_path("../contrib/plugins/*.rb", __dir__)]
  API_CLASSES = %w[Gemdrop::Plugin Gemdrop::Error Gemdrop::RateLimiter].freeze
  # IRC's own commands (RFC 2812) and CTCP words the core handles; plugin
  # commands may share these names (ops' KICK, links' LINKS).
  IRC_WORDS = %w[ADMIN AWAY CAP CONNECT DIE ERROR INFO INVITE ISON JOIN KICK KILL LINKS LIST LUSERS MODE MOTD NAMES
                 NICK NOTICE OPER PART PASS PING PONG PRIVMSG QUIT REHASH RESTART SERVICE SERVLIST SQUERY SQUIT STATS
                 SUMMON TIME TOPIC TRACE USER USERHOST USERS VERSION WALLOPS WHO WHOIS WHOWAS CLIENTINFO ACTION].freeze

  def plugin_class(path)
    namespace = Module.new
    namespace.module_eval(File.read(path), path)
    namespace.constants.map { |c| namespace.const_get(c) }.find { |c| c.is_a?(Class) && c < Gemdrop::Plugin }
  end

  def test_the_core_knows_no_plugin
    core = CORE.to_h { |path| [path, File.read(path)] }
    PLUGINS.each do |path|
      name = File.basename(path, ".rb")
      commands = plugin_class(path).commands.keys - IRC_WORDS
      words = commands.map { |command| %("#{command}") } + [%("#{name}"), "plugins/#{name}.rb"]
      words.each do |word|
        found = core.select { |_, source| source.include?(word) }.keys.map { |f| File.basename(f) }
        assert_empty found, "#{word} (the #{name} plugin's) is mentioned in the core: #{found.join(', ')}"
      end
    end
  end

  def test_plugins_use_only_the_plugin_api
    PLUGINS.each do |path|
      used = File.read(path).scan(/Gemdrop::[A-Z]\w*(?:::[A-Z]\w*)*/).uniq - API_CLASSES
      assert_empty used, "#{File.basename(path)} reaches into the core: #{used.join(', ')}"
    end
  end
end
