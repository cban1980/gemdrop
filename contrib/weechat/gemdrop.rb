# gemdrop.rb - a WeeChat script for working with the Gemdrop IRC bot.
#
# Everything the bot offers, from WeeChat, with a buffer of its own:
#
#   /gemdrop (or /gd)            opens the gemdrop buffer: type bot commands there
#   /gd status                   a dashboard: the bot, your login, secrets, automations
#   /gd identify | logout        logs in: with your key, or the password kept in /secure
#   /gd key add                  makes a key pair for Gemdrop only, and gives the bot the public key
#   /gd secret set <pw>          keeps your password in /secure (never shown, never in history)
#   /gd summary [#chan] [hours]  "what did I miss?" (the ai plugin's AISUMMARY)
#   /gd settings ai              a plugin's settings as a table; /gd set ai #chan chat on
#   /gd up | kick | ban | topic  channel commands for the current channel
#
# Automations (all optional, see /help gemdrop and /fset gemdrop):
#   - identifies when you connect, when the bot comes back, and when the bot
#     says you must; then retries what you asked for
#   - only sends your password to the real bot: its user@host is pinned the
#     first time you /gd identify (or set in hostmasks), and a nick thief
#     gets nothing; automatic logins wait until a host is pinned
#   - UP in chosen channels when you join them, summaries when you rejoin,
#     your own commands after every login (autorun)
#   - a watchdog that alerts you when the bot quits, is kicked or comes back
#   - a "gemdrop" bar item: the bot's state and your login on this network
#
# Install: copy or link it to ~/.local/share/weechat/ruby/ (autoload/ to load
# it at start), then /script load gemdrop.rb. Full documentation: docs/weechat.md.
#
# License: same as Gemdrop.

require "base64"
require "digest"
require "openssl"
require "securerandom"
require "socket"

SCRIPT_NAME = "gemdrop".freeze
SCRIPT_AUTHOR = "Gemdrop".freeze
SCRIPT_VERSION = "1.0.0".freeze
SCRIPT_LICENSE = "MIT".freeze
SCRIPT_DESC = "Work with the Gemdrop IRC bot: logins, secrets, automations, settings and views".freeze

# The script's logic. WeeChat calls the top-level callbacks at the end of
# the file, which hand over to this module, so the logic can be tested
# without WeeChat (test/weechat_script_test.rb).
module GemdropScript
  OPTIONS = {
    "bots" => ["*=Gemdrop", "the bot's nick per server: server=nick,... (* for every server), e.g. IRCnet=Linuks,EFnet=Linuks"],
    "hostmasks" => ["", "the bot's user@host per server (wildcards allowed): server=mask,...; your password is only " \
                        "sent to a bot that matches. Empty for a server: pinned the first time you identify"],
    "accounts" => ["", "your account per server: server=account,... (default: your nick there)"],
    "autoidentify" => ["on", "identify when you connect, when the bot comes back, and when the bot asks you to"],
    "login" => ["auto", "how to log in: auto (your key on servers where it worked or where no password is kept, " \
                        "else the password), key, or password"],
    "key_logins" => ["", "servers where your key works, server,... (the script keeps this up to date)"],
    "capture" => ["on", "show the bot's private notices in the gemdrop buffer (off: where WeeChat puts them)"],
    "echo" => ["on", "show the commands you send the bot in the gemdrop buffer (passwords masked)"],
    "autoup" => ["", "channels to get op in (UP) when you join them: server/#chan,... e.g. IRCnet/#linux.se"],
    "autosummary" => ["", "channels to sum up (AISUMMARY) when you rejoin them: server/#chan,..."],
    "autorun" => ["", "bot commands to send after each login: server=CMD;CMD,... e.g. EFnet=UP #gunnit"],
    "watchdog" => ["on", "alert (highlight) when the bot quits, is kicked or parts, and when it comes back"],
    "check_interval" => ["300", "seconds between checks that the bot is online (0: only on events)"],
    "retry" => ["on", "after logging in because the bot asked, send the command again"]
  }.freeze

  SECURE_PREFIX = "gemdrop_"
  KEY_SECRET = "gemdrop_key" # the passphrase of the key file, in /secure
  NAMESPACE = "gemdrop"      # the keyauth plugin's signing namespace
  PACE_LIMIT = 7   # commands to the bot ...
  PACE_WINDOW = 31 # ... per this many seconds (the bot allows 8 per 30)

  # Bot commands whose arguments hold passwords or keys, and which of the
  # arguments to hide: an index, :last, or :all.
  SECRET_ARGS = {
    "IDENTIFY" => [:last], "REGISTER" => [:all], "PASSWORD" => [:all],
    "CHANKEY" => [1], "CHANREGISTER" => [2]
  }.freeze
  SECRET_SETTING = /key|token|secret|password|passwd/i

  # Bot commands, for completion (more are learned from LIST's answers).
  BOT_COMMANDS = %w[
    REGISTER IDENTIFY LOGOUT PASSWORD WHOAMI PLUGIN HELP LIST MORE AI AIFORGET AISUMMARY AISTATUS AIAGENT AITEST
    ACCESS UP DOWN CHANREGISTER CHANDROP CHANKEY MLOCK KICK KB BAN UNBAN TOPIC LINKS TITLE LOGSEARCH
  ].freeze

  ERROR = /\A(?:Unknown command|Only |You must|You need|Invalid|Too many|Refused|No |Usage:|I don't|I only|That |The account|Passwords|Your password|Registration|Not |Can't|Cannot|Still |I'm busy|Busy|Summaries need|Agent mode needs)|failed|not allowed/i
  SUCCESS = /now identified|registered|saved|loaded|Password changed|logged out|is (?:on|off) in|is back to|Forgot|Added|Removed|Done/i

  SUBCOMMANDS = %w[
    buffer status identify logout whoami register password secret trust key send summary catchup ai chat forget aistatus
    agent up down kick kb ban unban topic access mlock chankey plugins settings set unset reload logsearch links title
    help list more setup
  ].freeze

  class << self
    attr_reader :state

    def reset!
      @state = {
        identified: {},   # server (lowercase) => account, or nil
        online: {},       # server => true / false / nil (unknown)
        bot_host: {},     # server => user@host last seen
        last_sent: {},    # server => [text, time] (for a retry after logging in)
        retried: {},      # server => time of the last retry
        pending_password: {}, # server => the new password, until the bot confirms
        after_userhost: Hash.new { |h, k| h[k] = [] }, # server => [:identify, :status ...]
        last_identify: {}, # server => time of the last IDENTIFY sent
        last_whoami: {},  # server => time
        view: {},         # server => { kind:, until: }
        plugins: [],      # plugin names seen in PLUGIN LIST
        settings: Hash.new { |h, k| h[k] = [] }, # plugin => setting names seen
        commands: BOT_COMMANDS.dup,
        outbox: {},       # server => [[text, echo, remember], ...] waiting to be sent
        sent_at: {},      # server => times of the commands sent lately
        flush_timer: {},  # server => true while a flush is scheduled
        login_method: {}, # server => :key or :password, asked for with /gd identify key|password
        auth_pending: {}, # server => time an AUTH was sent (a key login under way)
        buffer: nil,
        buffer_server: nil
      }
    end

    # --- options ----------------------------------------------------------------------------

    def option(name) = W.config_get_plugin(name).to_s

    def on?(name) = %w[on yes true 1].include?(option(name).strip.downcase)

    # "a=b,c=d" => { "a" => "b", "c" => "d" } (keys as written).
    def pairs(text)
      text.to_s.split(",").filter_map do |item|
        key, value = item.split("=", 2).map { |s| s.to_s.strip }
        [key, value] unless key.empty? || value.nil? || value.empty?
      end
    end

    # The value for server in a server=value option, or for "*".
    def per_server(name, server)
      list = pairs(option(name))
      list.find { |key, _| key.casecmp?(server.to_s) }&.last || list.find { |key, _| key == "*" }&.last
    end

    def bot_nick(server) = per_server("bots", server)

    def account(server) = per_server("accounts", server) || own_nick(server)

    def hostmask(server) = per_server("hostmasks", server)

    # server/#chan,... => does it list channel on server?
    def channel_listed?(name, server, channel)
      option(name).split(",").map(&:strip).any? do |item|
        srv, chan = item.split("/", 2)
        chan && srv.casecmp?(server) && chan.casecmp?(channel)
      end
    end

    # The servers that have a bot (for completion and status).
    def bot_servers
      servers = []
      infolist("irc_server", "") { |item| servers << W.infolist_string(item, "name") }
      servers.select { |server| bot_nick(server) }
    end

    # --- secrets ----------------------------------------------------------------------------

    def secure_name(server) = "#{SECURE_PREFIX}#{server.to_s.downcase.gsub(/[^a-z0-9_]/, '_')}"

    def secret(server)
      value = W.string_eval_expression("${sec.data.#{secure_name(server)}}", {}, {}, {}).to_s
      value.empty? ? nil : value
    end

    def store_secret(server, password)
      W.command("", "/mute /secure set #{secure_name(server)} #{password}")
    end

    def delete_secret(server)
      W.command("", "/mute /secure del #{secure_name(server)}")
    end

    # --- masking ----------------------------------------------------------------------------

    # A bot command with its passwords and keys replaced by ********.
    def mask_command(text)
      words = text.to_s.split(" ", -1)
      name = words.first.to_s.upcase
      if name == "PLUGIN" && words[1].to_s.casecmp?("SET")
        # PLUGIN SET <plugin> [#chan] <setting> <value...>
        at = words[3].to_s.start_with?("#", "&") ? 4 : 3
        return text unless words[at].to_s.match?(SECRET_SETTING) && words.size > at + 1

        return (words[0..at] + ["********"]).join(" ")
      end
      rules = SECRET_ARGS[name] or return text
      args = words[1..].reject(&:empty?)
      return text if args.empty?

      hidden = rules.flat_map do |rule|
        case rule
        when :all then (0...args.size).to_a
        when :last then [args.size - 1]
        else [rule]
        end
      end
      args = args.each_with_index.map { |arg, i| hidden.include?(i) && arg != "-" ? "********" : arg }
      ([words.first] + args).join(" ")
    end

    # Hides passwords in what you type (the input bar and the history):
    # bot commands typed in the gemdrop buffer, /msg <bot> ..., /gd secret
    # set, /gd register and /gd password.
    def mask_input(text, in_gemdrop_buffer)
      if (match = text.match(%r{\A(\s*/(?:gemdrop|gd)\s+)(.*)\z}im))
        return match[1] + mask_gd(match[2])
      end
      if (match = text.match(%r{\A(\s*/(?:msg|m|query|q|quote)\s+(?:-server\s+\S+\s+)?(?:PRIVMSG\s+)?\S+\s+:?)(.*)\z}im))
        return match[1] + mask_command(match[2])
      end
      return text unless in_gemdrop_buffer && !text.start_with?("/")

      if (match = text.match(/\A(@\S+\s+)(.*)\z/m))
        match[1] + mask_command(match[2])
      else
        mask_command(text)
      end
    end

    # /gd arguments with the password or key hidden.
    def mask_gd(args)
      words = args.split(" ", -1)
      sub = words.first.to_s.downcase
      hide_from =
        case sub
        when "secret" then words[1].to_s.casecmp?("set") ? (words.reject(&:empty?).size > 3 ? 3 : 2) : nil
        when "register", "password" then 1
        when "chankey" then words[1].to_s.start_with?("#", "&") ? 2 : 1
        when "send", "raw", "cmd" then return "#{words.first} #{mask_command(words[1..].join(' '))}"
        end
      return args unless hide_from

      shown = words.first(hide_from)
      rest = words[hide_from..].to_a.join(" ")
      rest.empty? ? args : "#{shown.join(' ')} #{'*' * rest.length}"
    end

    # A line WeeChat prints for something you sent: masked when it went to
    # the bot (its query, or "MSG(bot)" in the server buffer).
    def mask_printed(buffer_ptr, line)
      server = W.buffer_get_string(buffer_ptr, "localvar_server").to_s
      bot = bot_nick(server) or return line
      type = W.buffer_get_string(buffer_ptr, "localvar_type")
      to_bot = (type == "private" && W.buffer_get_string(buffer_ptr, "localvar_channel").casecmp?(bot)) ||
               (type == "server" && line.match?(/\b#{Regexp.escape(bot)}\b/i))
      return line unless to_bot

      prefix, text = line.split("\t", 2)
      return line unless text

      masked = text.sub(/\A(.*?)((?:IDENTIFY|REGISTER|PASSWORD|CHANKEY|CHANREGISTER|PLUGIN\s+SET)\b.*)\z/im) do
        Regexp.last_match(1) + mask_command(Regexp.last_match(2))
      end
      "#{prefix}\t#{masked}"
    end

    # --- talking to the bot -----------------------------------------------------------------

    # Sends a command to the bot on server, quietly (no "MSG(bot)" line).
    def send_bot(server, text, echo: true, remember: true)
      bot = bot_nick(server)
      unless bot
        error("No bot set for #{server}: /set plugins.var.ruby.gemdrop.bots \"#{server}=<nick>\"")
        return false
      end
      unless connected?(server)
        error("#{server} is not connected.")
        return false
      end
      text = text.to_s.strip
      return false if text.empty?

      (state[:outbox][key(server)] ||= []) << [text, echo, remember]
      flush(server)
      true
    end

    # Sends what waits in the outbox, at the pace the bot answers: it
    # ignores a host that sends more than 8 commands in 30 seconds.
    def flush(server)
      sent = (state[:sent_at][key(server)] ||= [])
      sent.reject! { |at| at <= now - PACE_WINDOW }
      queue = state[:outbox][key(server)] || []
      while queue.any? && sent.size < PACE_LIMIT
        text, echo, remember = queue.shift
        W.hook_signal_send("irc_input_send", W::WEECHAT_HOOK_SIGNAL_STRING,
                           "#{server};;1;;/quote -server #{server} PRIVMSG #{bot_nick(server)} :#{text}")
        sent << now
        first = text.split.first.to_s.upcase
        state[:last_sent][key(server)] = [text, now] if remember && !SECRET_ARGS.key?(first)
        echo_line(server, mask_command(text)) if echo && on?("echo")
      end
      return if queue.empty? || state[:flush_timer][key(server)]

      wait = [sent.first + PACE_WINDOW - now, 1].max
      note("Holding commands for #{bot_nick(server)} for #{wait}s (it answers 8 per 30 s).") if wait > 3
      state[:flush_timer][key(server)] = true
      W.hook_timer(wait * 1000, 0, 1, "gemdrop_timer_cb", "flush|#{server}")
    end

    def key(server) = server.to_s.downcase

    def connected?(server)
      value = nil
      infolist("irc_server", server) { |item| value = W.infolist_integer(item, "is_connected") == 1 }
      value
    end

    def own_nick(server) = W.info_get("irc_nick", server).to_s

    def now = Time.now.to_i

    # Asks the server for the bot's user@host (USERHOST, answered quietly
    # through a redirect), then runs what was queued for it.
    def check_bot(server, *then_do)
      bot = bot_nick(server) or return
      return unless connected?(server)

      state[:after_userhost][key(server)].concat(then_do)
      asked = (@userhost_asked ||= {})[key(server)]
      return if asked && now - asked < 20 # the answer is on its way

      @userhost_asked[key(server)] = now

      W.hook_hsignal_send("irc_redirect_command",
                          { "server" => server, "pattern" => "userhost", "signal" => "gemdrop", "string" => bot,
                            "timeout" => "15" })
      W.hook_signal_send("irc_input_send", W::WEECHAT_HOOK_SIGNAL_STRING, "#{server};;2;;/quote -server #{server} USERHOST #{bot}")
    end

    # The answer to USERHOST: "nick=+user@host" (or nothing when it's offline).
    def userhost_answered(server, output, error)
      queue = state[:after_userhost].delete(key(server)) || []
      @userhost_asked&.delete(key(server))
      if error.to_s.empty?
        bot = bot_nick(server)
        reply = output.to_s.lines.map { |l| l.split(" :", 2).last.to_s.strip }.join(" ")
        entry = reply.split.find { |e| e.split("=", 2).first.delete("*").casecmp?(bot.to_s) }
        if entry
          state[:online][key(server)] = true
          state[:bot_host][key(server)] = entry.split("=", 2).last.sub(/\A[+-]/, "")
        else
          state[:online][key(server)] = false
        end
      end
      refresh
      queue.uniq.each { |action| run_after_check(server, action) }
    end

    def run_after_check(server, action)
      case action
      when :identify, :identify_quiet then identify_now(server, quiet: action == :identify_quiet)
      when :status then print_status
      when :whoami then send_bot(server, "WHOAMI", echo: false, remember: false) if state[:online][key(server)]
      end
    end

    # An IRC line: { nick:, userhost:, command:, params: [...] } (the last
    # parameter without its ":"), or nil.
    def parse(raw)
      line = raw.to_s.sub(/\A@\S+ /, "")
      match = line.match(/\A:(\S+) (\S+)(?: (.*))?\z/) or return nil
      source, command, rest = match.captures
      params = []
      rest = rest.to_s
      until rest.empty?
        if rest.start_with?(":")
          params << rest[1..]
          break
        end
        word, rest = rest.split(" ", 2)
        params << word
        rest = rest.to_s
      end
      nick, userhost = source.split("!", 2)
      { nick: nick, userhost: userhost.to_s, command: command.upcase, params: params }
    end

    # --- logging in -------------------------------------------------------------------------

    def identify(server, quiet: false, method: nil)
      state[:login_method][key(server)] = method if method
      check_bot(server, quiet ? :identify_quiet : :identify)
    end

    # Sends IDENTIFY, if the bot is the one we trust.
    def identify_now(server, quiet: false)
      bot = bot_nick(server)
      unless state[:online][key(server)]
        error("#{bot} is not on #{server} right now; not identifying.") unless quiet
        return
      end
      wanted = state[:login_method].delete(key(server))
      method = login_method(server, wanted)
      unless method
        error("No way to log in on #{server}: /gd key add (while logged in), or /gd secret set #{server} " \
              "<password>") unless quiet
        return
      end
      host = state[:bot_host][key(server)].to_s
      mask = hostmask(server)
      if mask.nil? && quiet # only a login you asked for pins the host
        note("Not logging in to #{bot} on #{server} by itself: its host isn't pinned yet. /gd identify once " \
             "(it pins #{host}), or set it with /gd trust #{server} <user@host>.")
        return
      elsif mask.nil?
        pin_host(server, host)
      elsif !host_matches?(mask, host)
        alert("#{bot} on #{server} is #{host}, not #{mask}: NOT logging in. If the bot moved, " \
              "/gd trust #{server} reset (or set hostmasks).")
        return
      end
      last = state[:last_identify][key(server)]
      return if quiet && !wanted && last && now - last < 5 # not twice for the same reason

      state[:last_identify][key(server)] = now
      if method == :key
        state[:auth_pending][key(server)] = now
        send_bot(server, "AUTH #{account(server)}", remember: false)
      else
        send_bot(server, "IDENTIFY #{account(server)} #{secret(server)}", remember: false)
      end
    end

    # :key or :password for a login on server (wanted: one asked for), or nil.
    def login_method(server, wanted = nil)
      key_ok = key_exists?
      password_ok = !secret(server).nil?
      wanted ||= { "key" => :key, "password" => :password }[option("login").strip.downcase]
      return (key_ok ? :key : nil) if wanted == :key
      return (password_ok ? :password : nil) if wanted == :password
      return :key if key_ok && (key_login?(server) || !password_ok)
      return :password if password_ok

      key_ok ? :key : nil
    end

    def key_login?(server) = option("key_logins").split(",").map(&:strip).any? { |s| s.casecmp?(server) }

    def mark_key_login(server, works)
      list = option("key_logins").split(",").map(&:strip).reject { |s| s.empty? || s.casecmp?(server) }
      list << server if works
      W.config_set_plugin("key_logins", list.join(","))
    end

    # --- the key -----------------------------------------------------------------------------
    #
    # A key pair for Gemdrop only (not your SSH keys): Ed25519, in WeeChat's
    # data folder (gemdrop/key.pem, 0600), encrypted with a passphrase kept
    # in /secure. It signs the bot's challenges in the format ssh-keygen -Y
    # sign uses, with the namespace "gemdrop".

    def key_dir = File.join(W.info_get("weechat_data_dir", "").to_s, "gemdrop")
    def key_path = File.join(key_dir, "key.pem")
    def key_exists? = File.file?(key_path)

    def key_passphrase
      value = W.string_eval_expression("${sec.data.#{KEY_SECRET}}", {}, {}, {}).to_s
      value.empty? ? nil : value
    end

    # Makes the key pair if there is none; true when it made one.
    def ensure_key
      return false if key_exists?

      Dir.mkdir(key_dir, 0o700) unless File.directory?(key_dir)
      passphrase = SecureRandom.hex(32)
      W.command("", "/mute /secure set #{KEY_SECRET} #{passphrase}")
      pem = OpenSSL::PKey.generate_key("ED25519").private_to_pem(OpenSSL::Cipher.new("aes-256-cbc"), passphrase)
      File.open(key_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(pem) }
      @key = nil
      true
    end

    def private_key
      @key ||= OpenSSL::PKey.read(File.read(key_path), key_passphrase.to_s)
    end

    def ssh_string(text) = [text.bytesize].pack("N") + text.b
    def public_blob = ssh_string("ssh-ed25519") + ssh_string(private_key.public_to_der[-32..])
    def public_line = "ssh-ed25519 #{Base64.strict_encode64(public_blob)} gemdrop-weechat@#{Socket.gethostname}"
    def key_fingerprint = "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(public_blob)).delete('=')}"

    # text signed like ssh-keygen -Y sign -n gemdrop: one line of base64.
    def sign(text)
      head = "#{ssh_string(NAMESPACE)}#{ssh_string('')}#{ssh_string('sha512')}"
      signature = private_key.sign(nil, "SSHSIG#{head}#{ssh_string(Digest::SHA512.digest(text))}")
      Base64.strict_encode64("SSHSIG#{[1].pack('N')}#{ssh_string(public_blob)}#{head}" \
                             "#{ssh_string(ssh_string('ssh-ed25519') + ssh_string(signature))}")
    end

    # The bot's challenge (from its trusted host): signed and sent back if
    # it is for our login.
    def answer_challenge(server, text)
      return unless state[:auth_pending].delete(key(server))

      _tag, _network, name, = text.split(":", 5)
      unless text.start_with?("gemdrop-auth:") && name.to_s.casecmp?(account(server))
        return alert("A challenge from #{bot_nick(server)} on #{server} that isn't for #{account(server)}: not signed.")
      end

      state[:auth_pending][key(server)] = now # until the answer
      send_bot(server, "AUTH #{sign(text)}", echo: false, remember: false)
      echo_line(server, "AUTH <signature by #{key_fingerprint}>") if on?("echo")
    rescue OpenSSL::PKey::PKeyError, SystemCallError => e
      error("Couldn't sign with your key (#{key_path}): #{e.message}")
    end

    def key_command(server, words)
      action = words.shift.to_s.downcase
      case action
      when "create", "show", ""
        made = ensure_key
        note("#{made ? 'Made your Gemdrop key: ' : 'Your Gemdrop key: '}#{key_fingerprint} (#{key_path})")
        note("Public key: #{public_line}")
      when "add"
        ensure_key && note("Made your Gemdrop key: #{key_fingerprint} (#{key_path})")
        comment = words.empty? ? "gemdrop-weechat@#{Socket.gethostname}" : words.join(" ")
        send_bot(server, "KEY ADD #{public_line.split[0, 2].join(' ')} #{comment}")
      when "list" then send_bot(server, "KEY LIST #{words.join(' ')}".strip)
      when "del" then words.empty? ? error("/gd key del <number|fingerprint|comment>") : send_bot(server, "KEY DEL #{words.join(' ')}")
      when "only" then send_bot(server, "KEY ONLY #{words.join(' ')}".strip)
      when "use"
        target = words.first ? known_server(words.first) : server
        return error("No such server.") unless target

        mark_key_login(target, true)
        note("Logins on #{target} use your key from now on (keys are shared by the bot's networks).")
      else error("/gd key create|show|add [comment]|list|del <which>|only on|off|use [server]")
      end
    rescue OpenSSL::PKey::PKeyError, SystemCallError => e
      error("Your key (#{key_path}): #{e.message}")
    end

    def host_matches?(mask, host)
      return true if mask == "*"

      pattern = Regexp.new("\\A#{Regexp.escape(mask).gsub('\\*', '.*').gsub('\\?', '.')}\\z", Regexp::IGNORECASE)
      host.match?(pattern) || host.sub(/\A[~^=+-]/, "").match?(pattern)
    end

    # Trust on first use: the host the bot has the first time you identify.
    def pin_host(server, host)
      return if host.empty?

      list = pairs(option("hostmasks")).reject { |k, _| k.casecmp?(server) }
      list << [server, host]
      W.config_set_plugin("hostmasks", list.map { |k, v| "#{k}=#{v}" }.join(","))
      note("Pinned #{bot_nick(server)} on #{server} to #{host}; your password only goes to that host from now on " \
           "(/gd trust to change it).")
    end

    def logged_in(server, account)
      state[:identified][key(server)] = account
      refresh
      retry_last(server)
      autorun(server)
      autoup_joined(server)
    end

    def logged_out(server)
      state[:identified][key(server)] = nil
      refresh
    end

    # After a login the bot asked for, the command it refused, once.
    def retry_last(server)
      text, at = state[:last_sent][key(server)]
      return unless text && on?("retry") && @retry_wanted&.delete(key(server))
      return if now - at > 60

      state[:last_sent].delete(key(server))
      note("Sending again: #{text}")
      send_bot(server, text)
    end

    def autorun(server)
      commands = per_server("autorun", server) or return
      commands.split(";").map(&:strip).reject(&:empty?).each { |command| send_bot(server, command) }
    end

    # UP in the autoup channels you are already in (after logging in).
    def autoup_joined(server)
      channels_of(server).each do |channel|
        send_bot(server, "UP #{channel}") if channel_listed?("autoup", server, channel)
      end
    end

    def channels_of(server)
      list = []
      infolist("irc_channel", server) do |item|
        list << W.infolist_string(item, "name") if W.infolist_integer(item, "type").zero?
      end
      list
    end

    # --- what the bot says ------------------------------------------------------------------

    # A NOTICE that arrived (raw line). Returns the line to keep, or "" when
    # it was shown in the gemdrop buffer instead.
    def notice_in(server, raw)
      bot = bot_nick(server) or return raw
      msg = parse(raw) or return raw
      return raw unless msg[:nick].casecmp?(bot) && msg[:params][0].to_s.casecmp?(own_nick(server))

      text = msg[:params][1].to_s
      return raw if text.start_with?("\x01") # CTCP replies

      userhost = msg[:userhost]
      verified = host_trusted?(server, userhost)
      bot_line(server, text, verified) if on?("capture")
      learn(server, text) if verified # after showing it, so what it sets off comes below
      on?("capture") ? "" : raw
    end

    def host_trusted?(server, userhost)
      mask = hostmask(server)
      mask.nil? || host_matches?(mask, userhost)
    end

    # Updates the state from what the bot says.
    def learn(server, text)
      case text
      when /\AYou are now identified as (\S+?)\.\z/, /\AAccount (\S+) registered\. You are now identified\./
        mark_key_login(server, true) if state[:auth_pending].delete(key(server)) && !key_login?(server)
        logged_in(server, Regexp.last_match(1))
      when /\AChallenge: (\S+) /
        answer_challenge(server, Regexp.last_match(1))
      when /\AKey login failed|\ANo challenge for you/
        if state[:auth_pending].delete(key(server))
          mark_key_login(server, false)
          if secret(server) && option("login").strip.casecmp?("auto")
            note("Your key didn't work on #{server}; logging in with the password. (/gd key add while logged in " \
                 "gives the bot your key.)")
            identify(server, quiet: true, method: :password)
          end
        end
      when /\A\S+ only takes key logins/
        identify(server, quiet: true, method: :key) if key_exists?
      when /\AAdded SHA256:|\AThat key is already yours/
        mark_key_login(server, true)
      when /\A\S+ has no keys\./
        mark_key_login(server, false)
      when /\AYou are identified as (\S+?)\.\z/ # WHOAMI: no automations
        state[:identified][key(server)] = Regexp.last_match(1)
        refresh
      when /\AYou are not identified\./
        logged_out(server)
        identify(server, quiet: true) if on?("autoidentify") && @whoami_check&.delete(key(server))
      when /\AYou are now logged out\./
        logged_out(server)
      when /\AYou must IDENTIFY first|\AOnly identified users/
        logged_out(server)
        if on?("autoidentify") && secret(server)
          (@retry_wanted ||= {})[key(server)] = true
          identify(server, quiet: true)
        end
      when /\APassword changed\./
        if (password = state[:pending_password].delete(key(server)))
          store_secret(server, password)
          note("Your new password is kept in /secure (#{secure_name(server)}).")
        end
      when /\AInvalid account or password\./
        state[:pending_password].delete(key(server))
        alert("The bot on #{server} turned down your password. /gd secret set #{server} <password> if it changed.")
      when /\A(\S+): loaded, (?:commands (.+?)|no commands) \(/
        state[:plugins] |= [Regexp.last_match(1)]
        (Regexp.last_match(2) || "").split(", ").each { |c| state[:commands] |= [c.delete_prefix("!").upcase] }
      when /\A(\S+): (?:failed to load|unloaded|installing)/
        state[:plugins] |= [Regexp.last_match(1)]
      when /\A(\S+): (\S+) = /
        state[:settings][Regexp.last_match(1)] |= [Regexp.last_match(2)]
      when /\A[\w ]+ commands: ([A-Za-z!][\w!· -]+)\z/ # LIST <group>
        Regexp.last_match(1).split(" · ").each { |c| state[:commands] |= [c.strip.delete_prefix("!").upcase] }
      end
    end

    # --- the gemdrop buffer -----------------------------------------------------------------

    def buffer
      found = W.buffer_search("ruby", SCRIPT_NAME)
      return found unless found.to_s.empty?

      buf = W.buffer_new(SCRIPT_NAME, "gemdrop_input_cb", "", "gemdrop_close_cb", "")
      W.buffer_set(buf, "notify", "3")
      W.buffer_set(buf, "short_name", "gemdrop")
      state[:buffer_server] ||= current_server || bot_servers.first
      title
      buf
    end

    def buffer_server = state[:buffer_server] || current_server || bot_servers.first

    def current_server
      server = W.buffer_get_string(W.current_buffer, "localvar_server").to_s
      server.empty? ? nil : server
    end

    def current_channel
      buf = W.current_buffer
      return nil unless W.buffer_get_string(buf, "localvar_type") == "channel"

      W.buffer_get_string(buf, "localvar_channel")
    end

    def title
      buf = W.buffer_search("ruby", SCRIPT_NAME)
      return if buf.to_s.empty?

      server = buffer_server
      W.buffer_set(buf, "title", "Gemdrop on #{server || '?'}: #{state_text(server, color: false)} | type bot commands " \
                                 "(HELP, LIST ...), @server <command> for another network; /gd help")
    end

    def refresh
      W.bar_item_update(SCRIPT_NAME)
      title
    end

    # The gemdrop buffer's input: bot commands for its server; "@EFnet ..."
    # for another (and makes it the buffer's server).
    def input(text)
      server = buffer_server
      if (match = text.match(/\A@(\S+)\s*(.*)\z/m))
        server = known_server(match[1]) or return error("No server called #{match[1]}.")
        state[:buffer_server] = server
        title
        text = match[2]
        return note("Commands here now go to #{bot_nick(server) || '?'} on #{server}.") if text.strip.empty?
      end
      return error("No IRC server here; @server <command> picks one.") unless server

      send_view(server, text)
    end

    def known_server(name)
      found = nil
      infolist("irc_server", "") do |item|
        found = W.infolist_string(item, "name") if W.infolist_string(item, "name").casecmp?(name)
      end
      found
    end

    # Sends a command, with a header when its answer is shown as a view.
    def send_view(server, text)
      words = text.split
      kind = view_kind(words)
      if kind
        state[:view][key(server)] = { kind: kind, until: now + 6 }
      end
      send_bot(server, text)
    end

    def view_kind(words)
      first = words[0].to_s.upcase
      second = words[1].to_s.upcase
      return :settings if first == "PLUGIN" && second == "SETTINGS"
      return :plugins if first == "PLUGIN" && second == "LIST"
      return :access if first == "ACCESS"

      nil
    end

    def bot_line(server, text, verified)
      view = state[:view][key(server)]
      view = nil if view && now > view[:until]
      body = view ? view_line(view[:kind], text) : colored(text)
      prefix = "#{W.color('cyan')}#{bot_nick(server)}#{W.color('default')}"
      prefix += "#{W.color('darkgray')}@#{server}#{W.color('default')}" if several_bots?
      body = "#{W.color('*red')}(not from the trusted host!)#{W.color('default')} #{body}" unless verified
      tags = "notify_private,nick_#{bot_nick(server)},gemdrop_reply"
      tags += ",notify_highlight" unless verified
      W.print_date_tags(buffer, 0, tags, "#{prefix}\t#{body}")
    end

    def several_bots? = bot_servers.size > 1

    def colored(text)
      if text.match?(ERROR) then "#{W.color('red')}#{text}"
      elsif text.match?(SUCCESS) then "#{W.color('green')}#{text}"
      else text
      end
    end

    # A line of a view: settings and plugin lists as tables.
    def view_line(kind, text)
      case kind
      when :settings
        if (m = text.match(/\A(\S+): (\S+) = (.*?)( \(saved with PLUGIN SET\))?\z/))
          saved = m[4] ? " #{W.color('yellow')}[saved]" : ""
          return "#{W.color('bold')}#{m[2].ljust(24)}#{W.color('-bold')} #{value_color(m[3])}#{m[3]}#{W.color('default')}#{saved}"
        end
      when :plugins
        if (m = text.match(/\A(\S+): (loaded|failed to load|unloaded|installing)(.*)\z/))
          color = { "loaded" => "green", "unloaded" => "darkgray", "installing" => "yellow" }.fetch(m[2], "red")
          return "#{W.color('bold')}#{m[1].ljust(12)}#{W.color('-bold')} #{W.color(color)}#{m[2]}#{W.color('default')}#{m[3]}"
        end
      end
      colored(text)
    end

    def value_color(value)
      case value
      when "true", "on" then W.color("green")
      when "false", "off" then W.color("red")
      when /\A-?\d+(\.\d+)?\z/ then W.color("lightcyan")
      when /\A"/ then W.color("brown")
      else W.color("default")
      end
    end

    def echo_line(server, text)
      prefix = "#{W.color('lightgreen')}#{own_nick(server)}#{W.color('default')}"
      W.print_date_tags(buffer, 0, "no_highlight,notify_none,self_msg,gemdrop_sent",
                        "#{prefix}\t#{W.color('darkgray')}→ #{bot_nick(server)}#{" @#{server}" if several_bots?}: " \
                        "#{W.color('default')}#{text}")
    end

    def header(text)
      W.print_date_tags(buffer, 0, "no_highlight,notify_none", "#{W.color('blue')}──\t#{W.color('bold')}#{text}")
    end

    def note(text)
      W.print_date_tags(buffer, 0, "no_highlight,notify_none", "#{W.color('blue')}--\t#{text}")
    end

    def error(text)
      W.print_date_tags(buffer, 0, "no_highlight,notify_none", "#{W.prefix('error')}#{W.color('red')}#{text}")
      nil
    end

    def alert(text)
      W.print_date_tags(buffer, 0, "notify_highlight", "#{W.color('*red')}!!\t#{W.color('red')}#{text}")
    end

    # --- the status ---------------------------------------------------------------------------

    # One server's state, for the bar item and the buffer title.
    def state_text(server, color: true)
      return "no bot" unless server && bot_nick(server)

      c = ->(name) { color ? W.color(name) : "" }
      online = state[:online][key(server)]
      bot = "#{bot_nick(server)} #{online.nil? ? '?' : (online ? 'online' : 'offline')}"
      bot = "#{c.call(online == false ? 'red' : 'default')}#{bot}#{c.call('default')}"
      account = state[:identified][key(server)]
      login = account ? "#{c.call('green')}✓ #{account}" : "#{c.call('yellow')}not identified"
      "#{bot}, #{login}#{c.call('default')}"
    end

    def bar_item(buffer_ptr)
      server = W.buffer_get_string(buffer_ptr, "localvar_server").to_s
      server = buffer_server.to_s if server.empty? && W.buffer_get_string(buffer_ptr, "name") == SCRIPT_NAME
      return "" if server.empty? || !bot_nick(server)

      "#{W.color('cyan')}gd#{W.color('default')}:#{state_text(server)}"
    end

    def status
      header("Gemdrop status")
      servers = bot_servers
      return note("No server has a bot: /set plugins.var.ruby.gemdrop.bots \"IRCnet=Linuks\"") if servers.empty?

      servers.each { |server| check_bot(server, :status) if connected?(server) }
      print_status if servers.none? { |server| connected?(server) }
    end

    def print_status
      return if state[:after_userhost].values.any? { |queue| queue.include?(:status) }

      bot_servers.each do |server|
        host = state[:bot_host][key(server)]
        mask = hostmask(server)
        trust = if mask.nil? then "#{W.color('yellow')}not pinned yet"
                elsif host && host_matches?(mask, host) then "#{W.color('green')}trusted (#{mask})"
                elsif host then "#{W.color('*red')}NOT trusted: #{host} isn't #{mask}"
                else "pinned to #{mask}"
                end
        note("#{W.color('bold')}#{server}#{W.color('-bold')}: #{state_text(server)}" \
             "#{" (#{host})" if host}#{connected?(server) ? '' : " #{W.color('darkgray')}(not connected)"}")
        note("   host: #{trust}#{W.color('default')}; password: " \
             "#{secret(server) ? "#{W.color('green')}kept (#{secure_name(server)})" : "#{W.color('yellow')}none"}" \
             "#{W.color('default')}; account: #{account(server)}")
        note("   login: #{login_method(server) || 'none'}#{" (key #{key_text})" if key_exists?}" \
             "#{key_login?(server) ? ', the key works here' : ''}")
        autos = []
        autos << "identify" if on?("autoidentify")
        up = listed_channels("autoup", server)
        autos << "up #{up.join(' ')}" if up.any?
        sums = listed_channels("autosummary", server)
        autos << "summary #{sums.join(' ')}" if sums.any?
        run = per_server("autorun", server)
        autos << "run #{run}" if run
        note("   automations: #{autos.empty? ? 'none' : autos.join('; ')}#{'; watchdog' if on?('watchdog')}")
      end
    end

    def key_text
      key_fingerprint
    rescue OpenSSL::PKey::PKeyError, SystemCallError
      "unreadable: #{key_path}"
    end

    def listed_channels(name, server)
      option(name).split(",").map(&:strip).filter_map do |item|
        srv, chan = item.split("/", 2)
        chan if chan && srv.casecmp?(server)
      end
    end

    # --- events -------------------------------------------------------------------------------

    def connected(server)
      return unless bot_nick(server)

      state[:online].delete(key(server))
      logged_out(server)
      W.hook_timer(5000, 0, 1, "gemdrop_timer_cb", "connected|#{server}")
    end

    def disconnected(server)
      state[:online].delete(key(server))
      state[:identified].delete(key(server))
      refresh
    end

    def timer(data)
      action, server, arg = data.split("|", 3)
      case action
      when "flush"
        state[:flush_timer].delete(key(server))
        flush(server)
      when "connected"
        check_bot(server, on?("autoidentify") ? :identify_quiet : :whoami)
      when "botback"
        (@whoami_check ||= {})[key(server)] = true
        check_bot(server, :whoami)
      when "summary"
        send_bot(server, "AISUMMARY #{arg}") if channels_of(server).any? { |c| c.casecmp?(arg) }
      when "up"
        send_bot(server, "UP #{arg}") if state[:identified][key(server)]
      when "check"
        bot_servers.each { |s| check_bot(s) if connected?(s) }
      end
    end

    # JOIN, PART, QUIT, KICK and NICK lines: the bot's comings and goings,
    # and your own joins (for autoup and autosummary).
    def irc_event(server, command, raw)
      bot = bot_nick(server) or return
      msg = parse(raw) or return
      nick = msg[:nick]
      params = msg[:params]
      channel = %w[join part kick].include?(command) ? params[0].to_s : ""
      me = own_nick(server)
      case command
      when "join"
        if nick.casecmp?(bot)
          was = state[:online][key(server)]
          state[:online][key(server)] = true
          state[:bot_host][key(server)] = msg[:userhost] unless msg[:userhost].empty?
          refresh
          if was == false && on?("watchdog")
            alert("#{bot} is back on #{server} (#{channel}).")
          end
          # It may have restarted without its logins: check once it settled.
          unless @botback_pending&.[](key(server))
            (@botback_pending ||= {})[key(server)] = true
            W.hook_timer(4000, 0, 1, "gemdrop_timer_cb", "botback|#{server}")
          end
        elsif nick.casecmp?(me)
          joined(server, channel)
        end
      when "quit"
        return unless nick.casecmp?(bot)

        state[:online][key(server)] = false
        @botback_pending&.delete(key(server))
        refresh
        alert("#{bot} quit #{server}: #{params[0]}") if on?("watchdog")
      when "part"
        alert("#{bot} left #{channel} on #{server}.") if nick.casecmp?(bot) && on?("watchdog")
      when "kick"
        if params[1].to_s.casecmp?(bot)
          state[:online][key(server)] = true # kicked from a channel, still on IRC
          alert("#{bot} was kicked from #{channel} on #{server} by #{nick}: #{params[2]}") if on?("watchdog")
        end
      when "nick"
        if nick.casecmp?(bot) && on?("watchdog")
          alert("#{bot} on #{server} is now called #{params[0]}; update the bots option if that is for good.")
        end
      end
    end

    def joined(server, channel)
      if channel_listed?("autoup", server, channel) && state[:identified][key(server)]
        W.hook_timer(2000, 0, 1, "gemdrop_timer_cb", "up|#{server}|#{channel}")
      end
      return unless channel_listed?("autosummary", server, channel)

      @summaries = (@summaries || {}).select { |_, at| at > now - 120 }
      delay = 6 + 20 * @summaries.count { |k, _| k.start_with?("#{key(server)}|") } # the bot allows a few a minute
      @summaries["#{key(server)}|#{channel.downcase}"] = now
      W.hook_timer(delay * 1000, 0, 1, "gemdrop_timer_cb", "summary|#{server}|#{channel}")
    end

    # --- /gemdrop -----------------------------------------------------------------------------

    def command(buf, args)
      words = args.to_s.split
      words.rotate! if words.first&.start_with?("@") # /gd @EFnet whoami = /gd whoami @EFnet
      sub = words.shift.to_s.downcase
      server = W.buffer_get_string(buf, "localvar_server").to_s
      server = buffer_server.to_s if server.empty?
      if words.first&.start_with?("@") # /gd whoami @EFnet
        server = known_server(words.shift[1..]) or return error("No such server.")
      end
      channel = W.buffer_get_string(buf, "localvar_type") == "channel" ? W.buffer_get_string(buf, "localvar_channel") : nil
      server = nil if server.empty?
      need = -> { server && bot_nick(server) ? true : error("Which network? Use it in a buffer of that server, or /gd <command> @server ...") }
      chan_arg = lambda do
        words.first&.match?(/\A[#&!+]/) ? words.shift : (channel || (error("Which channel?") && nil))
      end

      case sub
      when "", "buffer"
        W.buffer_set(buffer, "display", "1")
        state[:buffer_server] = server if server
        title
      when "status" then status
      when "identify", "id"
        method = { "key" => :key, "password" => :password }[words.first.to_s.downcase]
        need.call && identify(server, method: method)
      when "key" then need.call && key_command(server, words)
      when "logout" then need.call && send_bot(server, "LOGOUT")
      when "whoami" then need.call && send_bot(server, "WHOAMI")
      when "register"
        return unless need.call

        if words.any?
          store_secret(server, words.join(" "))
          note("Password kept in /secure (#{secure_name(server)}).")
        end
        password = secret(server) or return error("/gd register <password> (it is kept in /secure).")
        send_bot(server, "REGISTER #{password}", remember: false)
      when "password"
        return unless need.call
        return error("/gd password <new password> (the old one is the kept one)") if words.empty?

        old = secret(server) or return error("No password kept for #{server}; /gd secret set first.")
        state[:pending_password][key(server)] = words.join(" ")
        send_bot(server, "PASSWORD #{old} #{words.join(' ')}", remember: false)
      when "secret" then secret_command(server, words)
      when "trust" then trust_command(server, words)
      when "send", "raw", "cmd"
        need.call && send_view(server, words.join(" "))
      when "summary"
        return unless need.call

        ch = chan_arg.call or return
        send_bot(server, "AISUMMARY #{ch} #{words.join(' ')}".strip)
      when "catchup"
        return unless need.call

        listed = channels_of(server).select { |c| bot_in?(server, c) }
        return note("The bot shares no channel with you on #{server}.") if listed.empty?

        listed.each_with_index do |c, i|
          W.hook_timer((1 + i * 20) * 1000, 0, 1, "gemdrop_timer_cb", "summary|#{server}|#{c}")
        end
        note("Summing up #{listed.join(', ')} (one every 20 s, the bot's pace).")
      when "ai" then need.call && send_bot(server, "AI #{words.join(' ')}")
      when "chat"
        return unless need.call

        ch = channel or return error("/gd chat <text> works in a channel buffer.")
        W.command(buf, "/msg #{ch} #{bot_nick(server)}: #{words.join(' ')}")
      when "forget"
        need.call && send_bot(server, "AIFORGET #{words.first&.start_with?('#') ? words.first : (channel || '')}".strip)
      when "aistatus" then need.call && send_bot(server, "AISTATUS")
      when "agent"
        return unless need.call

        ch = chan_arg.call or return
        mode = words.first.to_s.downcase
        return error("/gd agent [#chan] on|off") unless %w[on off].include?(mode)

        send_bot(server, "AIAGENT #{ch} #{mode}")
      when "up", "down"
        return unless need.call

        ch = chan_arg.call or return
        send_bot(server, "#{sub.upcase} #{ch}")
      when "kick", "kb", "ban", "unban", "topic"
        return unless need.call

        ch = chan_arg.call or return
        return error("/gd #{sub} [#chan] <#{sub == 'topic' ? 'text' : 'nick'}> ...") if words.empty?

        send_bot(server, "#{sub.upcase} #{ch} #{words.join(' ')}")
      when "access"
        return unless need.call

        ch = chan_arg.call or return
        words = ["LIST"] if words.empty?
        send_view(server, "ACCESS #{ch} #{words.join(' ')}")
      when "mlock"
        return unless need.call

        ch = chan_arg.call or return
        send_bot(server, "MLOCK #{ch} #{words.join(' ')}".strip)
      when "chankey"
        return unless need.call

        ch = chan_arg.call or return
        return error("/gd chankey [#chan] <key>|-") if words.empty?

        send_bot(server, "CHANKEY #{ch} #{words.join(' ')}")
      when "plugins" then need.call && send_view(server, "PLUGIN LIST")
      when "settings"
        return error("/gd settings <plugin>") if words.empty?

        need.call && send_view(server, "PLUGIN SETTINGS #{words.first}")
      when "set", "unset"
        return error("/gd #{sub} <plugin> [#chan] <setting>#{' <value>' if sub == 'set'}") if words.size < 2

        need.call && send_bot(server, "PLUGIN #{sub.upcase} #{words.join(' ')}")
      when "reload" then need.call && send_bot(server, "PLUGIN RELOAD #{words.join(' ')}".strip)
      when "logsearch", "search"
        return unless need.call

        ch = words.first&.start_with?("#") ? words.shift : channel
        send_bot(server, "LOGSEARCH #{[ch, *words].compact.join(' ')}")
      when "links" then need.call && send_bot(server, "LINKS #{[channel, *words].compact.join(' ')}".strip)
      when "title" then need.call && send_bot(server, "TITLE #{words.join(' ')}")
      when "help"
        return W.command(buf, "/help gemdrop") if words.empty? && !(server && bot_nick(server))

        need.call && send_bot(server, "HELP #{words.join(' ')}".strip)
      when "list" then need.call && send_bot(server, "LIST #{words.join(' ')}".strip)
      when "more" then need.call && send_bot(server, "MORE")
      when "setup" then setup_bar
      else
        error("Unknown: /gd #{sub}. /help gemdrop lists them; /gd send <command> sends anything to the bot.")
      end
    end

    def secret_command(server, words)
      action = words.shift.to_s.downcase
      if (named = words.first && known_server(words.first)) && (action != "set" || words.size == 2)
        server = named
        words.shift
      end
      case action
      when "set"
        return error("/gd secret set [server] <password> (no spaces)") unless words.size == 1 && server

        store_secret(server, words.first)
        note("Kept the password for #{server} in /secure (#{secure_name(server)}). Set a passphrase with " \
             "/secure passphrase so it is encrypted on disk.")
      when "del"
        return error("/gd secret del [server]") unless server

        delete_secret(server)
        note("Forgot the password for #{server}.")
      when "", "list"
        header("Kept passwords")
        bot_servers.each { |s| note("#{s}: #{secret(s) ? "kept (#{secure_name(s)})" : 'none'}") }
      else error("/gd secret set|del|list")
      end
    end

    def trust_command(server, words)
      return error("Which network?") unless server

      case words.first.to_s.downcase
      when "" then note("#{bot_nick(server)} on #{server}: #{hostmask(server) ? "pinned to #{hostmask(server)}" : 'not pinned yet'}" \
                        "#{", seen as #{state[:bot_host][key(server)]}" if state[:bot_host][key(server)]}.")
      when "reset", "-"
        list = pairs(option("hostmasks")).reject { |k, _| k.casecmp?(server) }
        W.config_set_plugin("hostmasks", list.map { |k, v| "#{k}=#{v}" }.join(","))
        note("Forgot #{server}'s pinned host; the next login pins the bot's host again.")
      else
        list = pairs(option("hostmasks")).reject { |k, _| k.casecmp?(server) }
        list << [server, words.first]
        W.config_set_plugin("hostmasks", list.map { |k, v| "#{k}=#{v}" }.join(","))
        note("#{server}: your password only goes to #{bot_nick(server)} at #{words.first}.")
      end
    end

    def bot_in?(server, channel)
      found = false
      infolist("irc_nick", "#{server},#{channel},#{bot_nick(server)}") { found = true }
      found
    end

    # Adds the gemdrop item to the status bar.
    def setup_bar
      option = W.config_get("weechat.bar.status.items")
      items = W.config_string(option)
      return note("The status bar already shows gemdrop.") if items.split(/[,+]/).include?(SCRIPT_NAME)

      W.config_option_set(option, "#{items},#{SCRIPT_NAME}", 1)
      note("Added the gemdrop item to the status bar (weechat.bar.status.items).")
    end

    # --- completion ---------------------------------------------------------------------------

    def complete(item, completion)
      words = case item
              when "gemdrop_subcommands" then SUBCOMMANDS
              when "gemdrop_bot_commands" then state[:commands]
              when "gemdrop_plugins" then state[:plugins].empty? ? %w[ai chanserv help links eventlog ctcp] : state[:plugins]
              when "gemdrop_settings" then state[:settings].values.flatten.uniq
              when "gemdrop_servers" then bot_servers.flat_map { |s| [s, "@#{s}"] }
              else []
              end
      words.each { |word| W.completion_list_add(completion, word, 0, W::WEECHAT_LIST_POS_SORT) }
    end

    # --- helpers --------------------------------------------------------------------------------

    def infolist(name, args)
      list = W.infolist_get(name, "", args)
      return if list.to_s.empty?

      yield list while W.infolist_next(list) == 1
    ensure
      W.infolist_free(list) if list && !list.to_s.empty?
    end
  end

  # WeeChat's API (Weechat in WeeChat; a stand-in in tests).
  W = defined?(Weechat) ? Weechat : nil
end

# --- WeeChat's callbacks (by name) ----------------------------------------------------------------

def weechat_init
  Weechat.register(SCRIPT_NAME, SCRIPT_AUTHOR, SCRIPT_VERSION, SCRIPT_LICENSE, SCRIPT_DESC, "", "")
  GemdropScript.reset!
  GemdropScript::OPTIONS.each do |name, (default, desc)|
    Weechat.config_set_plugin(name, default) unless Weechat.config_is_set_plugin(name) == 1
    Weechat.config_set_desc_plugin(name, "#{desc} (default: \"#{default}\")")
  end

  completion = [
    "buffer|status|whoami|logout|aistatus|plugins|catchup|more|setup %(gemdrop_servers)",
    "identify %(gemdrop_servers)", "register", "password",
    "secret set|del|list %(gemdrop_servers)", "trust reset %(gemdrop_servers)",
    "key add|show|list|del|only|use|create", "identify key|password",
    "send|raw %(gemdrop_bot_commands)", "help|list %(gemdrop_bot_commands)",
    "summary %(irc_channels)", "ai", "chat", "forget %(irc_channels)",
    "agent %(irc_channels) on|off", "up|down %(irc_channels)",
    "kick|kb|ban %(nicks)", "unban", "topic %(irc_channel_topic)",
    "access %(irc_channels) list|add|del|addmask|delmask %(nicks)",
    "mlock %(irc_channels)", "chankey %(irc_channels)",
    "settings %(gemdrop_plugins)", "set|unset %(gemdrop_plugins) %(irc_channels)|%(gemdrop_settings) %(gemdrop_settings)",
    "reload %(gemdrop_plugins)", "logsearch|search %(irc_channels)", "links %(irc_channels)", "title"
  ].join(" || ")
  args = "[status|identify|key|logout|whoami|register|password|secret|trust|send|summary|catchup|ai|chat|forget|aistatus|" \
         "agent|up|down|kick|kb|ban|unban|topic|access|mlock|chankey|plugins|settings|set|unset|reload|logsearch|" \
         "links|title|help|list|more|setup] [@server] [args]"
  help = <<~HELP
    Without arguments: opens the gemdrop buffer, where you type bot commands (HELP, WHOAMI, PLUGIN LIST ...); start a line with @server to talk to the bot on another network. The bot's answers show up there too (option capture).

    Commands go to the bot on the current buffer's server (or @server):
         status: the bot, your login, the pinned host, kept passwords, automations
       identify: [key|password] - log in with your key or the kept password (only to the trusted host)
            key: create|show - your Gemdrop key pair (made for this, never your SSH keys)
                 add [comment] - give the bot your public key (log in with the password first)
                 list|del <which>|only on|off - the bot's KEY commands; use [server] - use the key there
         logout, whoami: as the bot's commands
       register: register your nick (/gd register <password> keeps it too)
       password: change your password: /gd password <new> (updates the kept one)
         secret: set [server] <password> | del [server] | list - passwords in /secure, never shown
          trust: [reset|<user@host>] - the bot's pinned host (passwords only go there)
           send: send any command to the bot (also: raw)
        summary: [#chan] [hours] - what was said while you were away (AISUMMARY)
        catchup: a summary of every channel you share with the bot
       ai, chat: ask the AI privately / in the current channel
         forget: [#chan] - the AI forgets the conversation
       aistatus: the AI backends (admins)
          agent: [#chan] on|off - agent mode (admins)
     up, down, kick, kb, ban, unban, topic, access, mlock, chankey: channel commands for the current channel (or #chan)
        plugins: the bot's plugins, as a table (admins)
       settings: <plugin> - a plugin's settings, as a table (admins)
      set,unset: <plugin> [#chan] <setting> [value] (admins)
         reload: [plugin] (admins)
      logsearch: [#chan] <words>
          links: [#chan] [count]
          title: <url>
     help, list, more: the bot's help
          setup: put the gemdrop item in the status bar

    Options (/fset gemdrop): bots, hostmasks, accounts, autoidentify, login, key_logins, capture, echo, autoup, autosummary, autorun, watchdog, check_interval, retry.

    Examples:
      /set plugins.var.ruby.gemdrop.bots "IRCnet=Linuks,EFnet=Linuks"
      /gd secret set IRCnet my-password
      /set plugins.var.ruby.gemdrop.autoup "IRCnet/#linux.se,EFnet/#gunnit"
      /set plugins.var.ruby.gemdrop.autosummary "IRCnet/#linux.se"
      /gd summary 3
      /gd settings ai
      /gd set ai #linux.se max_reply_lines 2
  HELP
  %w[gemdrop gd].each do |name|
    Weechat.hook_command(name, SCRIPT_DESC, args, help, completion, "gemdrop_command_cb", "")
  end
  %w[subcommands bot_commands plugins settings servers].each do |item|
    Weechat.hook_completion("gemdrop_#{item}", "gemdrop: #{item.tr('_', ' ')}", "gemdrop_completion_cb", "")
  end
  Weechat.hook_modifier("irc_in2_notice", "gemdrop_notice_cb", "")
  Weechat.hook_modifier("input_text_display", "gemdrop_mask_cb", "")
  Weechat.hook_modifier("history_add", "gemdrop_mask_cb", "")
  Weechat.hook_modifier("weechat_print", "gemdrop_print_cb", "")
  %w[join part quit kick nick].each { |cmd| Weechat.hook_signal("*,irc_in2_#{cmd}", "gemdrop_irc_cb", cmd) }
  Weechat.hook_signal("irc_server_connected", "gemdrop_connected_cb", "")
  Weechat.hook_signal("irc_server_disconnected", "gemdrop_disconnected_cb", "")
  Weechat.hook_signal("buffer_switch", "gemdrop_refresh_cb", "")
  Weechat.hook_hsignal("irc_redirection_gemdrop_userhost", "gemdrop_userhost_cb", "")
  Weechat.hook_config("plugins.var.ruby.#{SCRIPT_NAME}.*", "gemdrop_config_cb", "")
  Weechat.bar_item_new(SCRIPT_NAME, "gemdrop_bar_item_cb", "")
  gemdrop_schedule_checks
  # Already connected (the script loaded late): find out where things stand.
  GemdropScript.bot_servers.each do |server|
    GemdropScript.check_bot(server, :whoami) if GemdropScript.connected?(server)
  end
  Weechat::WEECHAT_RC_OK
end

def gemdrop_schedule_checks
  Weechat.unhook($gemdrop_check_timer) if $gemdrop_check_timer
  seconds = GemdropScript.option("check_interval").to_i
  $gemdrop_check_timer = seconds.positive? ? Weechat.hook_timer(seconds * 1000, 0, 0, "gemdrop_timer_cb", "check") : nil
end

def gemdrop_command_cb(_data, buffer, args)
  GemdropScript.command(buffer, args)
  Weechat::WEECHAT_RC_OK
end

def gemdrop_input_cb(_data, _buffer, input)
  GemdropScript.input(input)
  Weechat::WEECHAT_RC_OK
end

def gemdrop_close_cb(_data, _buffer) = Weechat::WEECHAT_RC_OK

def gemdrop_completion_cb(_data, item, _buffer, completion)
  GemdropScript.complete(item, completion)
  Weechat::WEECHAT_RC_OK
end

def gemdrop_notice_cb(_data, _modifier, server, string)
  GemdropScript.notice_in(server, string)
rescue StandardError => e
  Weechat.print("", "#{Weechat.prefix('error')}gemdrop: #{e.class}: #{e.message}")
  string
end

# Passwords never show in the input bar or go into the history.
def gemdrop_mask_cb(_data, _modifier, buffer, string)
  GemdropScript.mask_input(string, Weechat.buffer_get_string(buffer, "name") == SCRIPT_NAME &&
                                   Weechat.buffer_get_string(buffer, "plugin") == "ruby")
end

# Nor in the lines WeeChat prints for your /msg <bot> IDENTIFY ... (in the
# query with the bot or the server buffer, your own lines only).
def gemdrop_print_cb(_data, _modifier, modifier_data, string)
  parts = modifier_data.split(";")
  return string unless parts.last.to_s.split(",").include?("self_msg")

  buffer = parts.first.start_with?("0x") ? parts.first : Weechat.buffer_search(parts[0].to_s, parts[1].to_s)
  GemdropScript.mask_printed(buffer, string)
end

def gemdrop_irc_cb(command, signal, raw)
  GemdropScript.irc_event(signal.split(",", 2).first, command, raw)
  Weechat::WEECHAT_RC_OK
end

def gemdrop_connected_cb(_data, _signal, server)
  GemdropScript.connected(server)
  Weechat::WEECHAT_RC_OK
end

def gemdrop_disconnected_cb(_data, _signal, server)
  GemdropScript.disconnected(server)
  Weechat::WEECHAT_RC_OK
end

def gemdrop_refresh_cb(*)
  GemdropScript.refresh
  Weechat::WEECHAT_RC_OK
end

def gemdrop_userhost_cb(_data, _signal, hashtable)
  GemdropScript.userhost_answered(hashtable["server"], hashtable["output"], hashtable["error"])
  Weechat::WEECHAT_RC_OK
end

def gemdrop_timer_cb(data, _remaining)
  GemdropScript.timer(data)
  Weechat::WEECHAT_RC_OK
end

def gemdrop_config_cb(_data, option, _value)
  gemdrop_schedule_checks if option.end_with?(".check_interval")
  GemdropScript.refresh
  Weechat::WEECHAT_RC_OK
end

# WeeChat calls it with (data, item, window); the buffer is the window's
# (no window: the item is drawn for a root bar, so the current buffer).
def gemdrop_bar_item_cb(_data, _item, window, *)
  buffer = window.to_s.empty? ? "" : Weechat.window_get_pointer(window, "buffer").to_s
  GemdropScript.bar_item(buffer.empty? ? Weechat.current_buffer : buffer)
rescue StandardError => e
  Weechat.print("", "#{Weechat.prefix('error')}gemdrop: bar item: #{e.class}: #{e.message}") unless $gemdrop_bar_failed
  $gemdrop_bar_failed = true # once, not on every redraw
  ""
end
