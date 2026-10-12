# gemdrop.rb - a WeeChat script for working with the Gemdrop IRC bot.
#
# Everything the bot offers, from WeeChat, with a buffer of its own:
#
#   /gemdrop (or /gd)            the gemdrop window: status, settings, keys, channels, the bot's
#                                plugins and the log, all in one (arrows, Enter, letters, mouse);
#                                type bot commands in it
#   /gd log                      the same window, on its log
#   /gd status                   the status, as text in the log
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
require "date"
require "time"

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
    "autoidentify" => ["on", "log in by itself (the identify_on_* settings say when)"],
    "identify_on_connect" => ["on", "log in after you connect or reconnect to a network"],
    "identify_on_bot" => ["on", "log in when the bot appears: it joins or comes back, you join a channel it is in, or " \
                                "a check finds it online while you are logged out"],
    "identify_on_load" => ["on", "log in when the script loads (WeeChat starting), where you aren't logged in"],
    "identify_on_request" => ["on", "log in when the bot says you must, then send your command again (retry)"],
    "identify_delay" => ["5", "seconds after connecting before logging in (the bot may still be joining)"],
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
  PACE_LIMIT = 6     # commands to the bot ...
  PACE_WINDOW = 31   # ... per this many seconds (the bot allows 8 per 30)
  # WeeChat's flood control sends a server's messages about 2 s apart, so a
  # command reaches the bot later than it is handed over; this is assumed.
  SEND_SPACING = 2.5
  # Never sent again after a login the bot asked for.
  NO_RETRY = %w[LOGOUT WHOAMI AUTH IDENTIFY REGISTER PASSWORD KEY].freeze

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
    ui log status identify logout whoami register password secret trust key send summary catchup ai chat forget aistatus
    agent up down kick kb ban unban topic access mlock chankey plugins settings set unset reload logsearch links title
    help list more setup
  ].freeze

  class << self
    attr_reader :state

    def reset!
      @whoami_check = @retry_wanted = @userhost_asked = @botback_pending = @summaries = @key = nil
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
        bot_keys: {},     # server => [{ n:, fp:, comment:, added:, used: }] from KEY LIST
        plugin_list: {},  # server => [{ name:, state:, info: }] from PLUGIN LIST
        plugin_settings: {}, # server => { plugin => [{ name:, value:, saved: }] } from PLUGIN SETTINGS
        key_only: {},     # server => true / false, from KEY LIST
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

    # Whether to log in by itself on this occasion (:connect, :bot, :load, :request).
    def auto?(occasion) = on?("autoidentify") && on?("identify_on_#{occasion}")

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
    # sent_at holds when each command is expected to reach the bot: handed
    # over now, but behind the ones still in WeeChat's queue.
    def flush(server)
      clock = Time.now.to_f
      sent = (state[:sent_at][key(server)] ||= [])
      sent.reject! { |at| at <= clock - PACE_WINDOW }
      queue = state[:outbox][key(server)] || []
      while queue.any? && sent.size < PACE_LIMIT
        text, echo, remember = queue.shift
        W.hook_signal_send("irc_input_send", W::WEECHAT_HOOK_SIGNAL_STRING,
                           "#{server};;1;;/quote -server #{server} PRIVMSG #{bot_nick(server)} :#{text}")
        sent << [clock, (sent.last || 0) + SEND_SPACING].max
        first = text.split.first.to_s.upcase
        state[:last_sent][key(server)] = [text, now] if remember && !SECRET_ARGS.key?(first) && !NO_RETRY.include?(first)
        echo_line(server, mask_command(text)) if echo && on?("echo")
      end
      return if queue.empty? || state[:flush_timer][key(server)]

      wait = [(sent.first + PACE_WINDOW - clock).ceil, 1].max
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
      when :ensure_login then ensure_login(server) if state[:online][key(server)]
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

    # Logs in if we aren't: asks WHOAMI, and "You are not identified."
    # logs in (see learn). force: ask even if we think we are (the bot may
    # have restarted). One question at a time per network (for up to 15 s).
    def ensure_login(server, force: false)
      return if !force && state[:identified][key(server)]
      return unless login_method(server)

      asked = (@whoami_check ||= {})[key(server)]
      return if asked.is_a?(Integer) && now - asked < 15

      @whoami_check[key(server)] = now
      send_bot(server, "WHOAMI", echo: false, remember: false)
    end

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
      GemdropUI.render
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
        GemdropUI.keys_changed(server)
      when /\A\S+ has no keys\./
        mark_key_login(server, false)
        state[:bot_keys][key(server)] = []
      when /\A(\d+)\. (SHA256:\S+)(?: (.*?))?, added (\S+), (?:never used|last used (\S+))\z/ # KEY LIST
        n = Regexp.last_match(1).to_i
        entry = { n: n, fp: Regexp.last_match(2), comment: Regexp.last_match(3).to_s, added: Regexp.last_match(4),
                  used: Regexp.last_match(5) }
        list = n == 1 ? [] : (state[:bot_keys][key(server)] || [])
        state[:bot_keys][key(server)] = list << entry
      when /\APassword logins to \S+: (refused|allowed)/
        state[:key_only][key(server)] = Regexp.last_match(1) == "refused"
      when /\ARemoved SHA256:|\APassword logins to \S+ (?:are refused now|are allowed again)/
        GemdropUI.keys_changed(server)
      when /\AYou are identified as (\S+?)\.\z/ # WHOAMI: no automations
        @whoami_check&.delete(key(server))
        state[:identified][key(server)] = Regexp.last_match(1)
        refresh
      when /\AYou are not identified\./
        logged_out(server)
        identify(server, quiet: true) if @whoami_check&.delete(key(server)) && on?("autoidentify")
      when /\AYou are now logged out\./
        logged_out(server)
      when /\AYou must IDENTIFY first|\AOnly identified users/
        logged_out(server)
        if auto?(:request) && login_method(server)
          (@retry_wanted ||= {})[key(server)] = on?("retry")
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
      when /\A(\S+): (loaded|failed to load|unloaded|installing)(.*)\z/
        name, plugin_state, rest = Regexp.last_match.captures
        list = (state[:plugin_list][key(server)] ||= [])
        list.reject! { |entry| entry[:name] == name }
        list << { name: name, state: plugin_state, info: rest.sub(/\A[:,.]\s*/, "") }
        state[:plugins] |= [name]
        commands = rest[/commands (.+?) \(/, 1]
        commands&.split(", ")&.each { |c| state[:commands] |= [c.delete_prefix("!").upcase] }
      when /\A(\S+): (\S+) (?:= .* saved for|for \S+ is back to|is back to)/ # PLUGIN SET / UNSET
        GemdropUI.plugin_changed(server, Regexp.last_match(1))
      when /\A(\S+): (\S+) = (.*?)( \(saved with PLUGIN SET\))?\z/ # PLUGIN SETTINGS
        plugin, name, value, saved = Regexp.last_match.captures
        state[:settings][plugin] |= [name]
        table = ((state[:plugin_settings][key(server)] ||= {})[plugin] ||= [])
        table.reject! { |row| row[:name] == name }
        table << { name: name, value: value, saved: !saved.nil? }
        (Regexp.last_match(2) || "").split(", ").each { |c| state[:commands] |= [c.delete_prefix("!").upcase] }
      when /\A[\w ]+ commands: ([A-Za-z!][\w!· -]+)\z/ # LIST <group>
        Regexp.last_match(1).split(" · ").each { |c| state[:commands] |= [c.strip.delete_prefix("!").upcase] }
      end
    end

    # --- the gemdrop window ------------------------------------------------------------------
    #
    # Everything is in one buffer, the gemdrop window (GemdropUI): what the
    # script and the bot say goes to its log.

    def buffer = GemdropUI.buffer || GemdropUI.create

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

    def title = GemdropUI.title

    def refresh
      W.bar_item_update(SCRIPT_NAME)
      title
      GemdropUI.render
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
      body = "#{W.color('*red')}(not from the trusted host!)#{W.color('default')} #{body}" unless verified
      who = "#{bot_nick(server)}#{"@#{server}" if several_bots?}"
      GemdropUI.add_log(:bot, "#{W.color('cyan')}#{who}#{W.color('default')}", body, who,
                        "#{'(not from the trusted host!) ' unless verified}#{text}", notify: verified ? 2 : 3)
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
      me = own_nick(server)
      to = "→ #{bot_nick(server)}#{" @#{server}" if several_bots?}: "
      GemdropUI.add_log(:sent, "#{W.color('lightgreen')}#{me}#{W.color('default')}",
                        "#{W.color('darkgray')}#{to}#{W.color('default')}#{text}", me, "#{to}#{text}")
    end

    def header(text) = GemdropUI.add_log(:note, "#{W.color('blue')}──#{W.color('default')}", "#{W.color('bold')}#{text}", "──", text)
    def note(text) = GemdropUI.add_log(:note, "#{W.color('blue')}--#{W.color('default')}", text, "--", text)

    def error(text)
      GemdropUI.add_log(:error, "#{W.color('red')}=!=#{W.color('default')}", "#{W.color('red')}#{text}", "=!=", text)
      nil
    end

    def alert(text)
      GemdropUI.add_log(:alert, "#{W.color('*red')}!!#{W.color('default')}", "#{W.color('red')}#{text}", "!!", text, notify: 3)
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
      delay = option("identify_delay").to_i.clamp(1, 300)
      W.hook_timer(delay * 1000, 0, 1, "gemdrop_timer_cb", "connected|#{server}")
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
        check_bot(server, auto?(:connect) ? :identify_quiet : :whoami)
      when "botback"
        auto?(:bot) ? ensure_login(server, force: true) : check_bot(server, :whoami)
      when "seen"
        ensure_login(server) if auto?(:bot) && bot_in?(server, arg)
      when "summary"
        send_bot(server, "AISUMMARY #{arg}") if channels_of(server).any? { |c| c.casecmp?(arg) }
      when "up"
        send_bot(server, "UP #{arg}") if state[:identified][key(server)]
      when "check"
        bot_servers.each { |s| check_bot(s, *(auto?(:bot) ? [:ensure_login] : [])) if connected?(s) }
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
        elsif params[0].to_s.casecmp?(bot) # it got its nick back
          state[:online][key(server)] = true
          state[:bot_host][key(server)] = msg[:userhost] unless msg[:userhost].empty?
          refresh
          alert("#{bot} is back on #{server} (got its nick back).") if on?("watchdog")
          W.hook_timer(3000, 0, 1, "gemdrop_timer_cb", "botback|#{server}")
        end
      end
    end

    def joined(server, channel)
      if auto?(:bot) && !state[:identified][key(server)] # the bot may be in it (known once the names are in)
        W.hook_timer(3000, 0, 1, "gemdrop_timer_cb", "seen|#{server}|#{channel}")
      end
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
      when "", "ui", "dashboard"
        state[:buffer_server] = server if server
        return GemdropUI.open if words.empty?

        GemdropUI.command(buf, words)
      when "log", "buffer"
        state[:buffer_server] = server if server
        GemdropUI.open(tab: "log")
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

# The gemdrop window: everything in one full-window buffer, drawn line by
# line like /fset (a WeeChat "free" buffer). Tabs: the status, settings,
# your keys, channels, the bot's plugins and settings, and the log of
# what the bot and the script said. Keys work only here: arrows move, Enter
# toggles or edits, letters are shortcuts (with something in the input line
# they are just letters), PgUp/PgDn scroll; the mouse selects and switches
# tabs. Text typed in the input line goes to the bot (@EFnet ... for another
# network), or runs as a command when it starts with /.
module GemdropUI
  NAME = SCRIPT_NAME
  TABS = [%w[status Status], %w[settings Settings], %w[keys Keys], %w[channels Channels], %w[bot Bot],
          %w[log Log]].freeze
  BOOLEANS = %w[autoidentify identify_on_connect identify_on_bot identify_on_load identify_on_request retry capture echo
                watchdog].freeze
  CHOICES = { "login" => %w[auto key password] }.freeze
  SETTING_GROUPS = [
    ["Logging in", %w[autoidentify identify_on_connect identify_on_bot identify_on_load identify_on_request
                      identify_delay login retry key_logins]],
    ["The bot", %w[bots hostmasks accounts]],
    ["Automations", %w[autoup autosummary autorun]],
    ["Display and alerts", %w[capture echo watchdog check_interval]]
  ].freeze
  # Letters bound in the window (each is a shortcut on some tab).
  LETTERS = %w[i l w r q a d o n u s x R U S L ?].freeze
  FOOTERS = {
    "status" => "⏎ or i log in · l log out · w who am I · n network · r refresh",
    "settings" => "⏎ toggle, or edit in the input line · d default · x delete/reset",
    "keys" => "⏎ do it · a give the bot your key · d delete · o key-only · n network · r refresh",
    "channels" => "u autoup · s autosummary · U op me now · S sum up now · r refresh",
    "bot" => "⏎ open a plugin / toggle or edit a setting · x unset · R reload plugin · n network · r refresh",
    "log" => "PgUp/PgDn scroll · End latest"
  }.freeze
  CONFIRM_SECONDS = 6
  MAX_LOG = 2000         # lines kept in memory
  HISTORY_LINES = 300    # lines read back from the history file at start
  HISTORY_BYTES = 512 * 1024
  STRIP = 3              # latest log lines at the bottom of each tab

  # A line you can select: help is shown under the list, enter runs on ⏎,
  # keys maps shortcut letters to what they do on this line.
  Item = Struct.new(:line, :help, :enter, :keys)
  # A log line: kind (:bot, :sent, :note, :error, :alert), colored prefix
  # and text, and the same without colors.
  Entry = Struct.new(:at, :kind, :prefix, :text, :plain_prefix, :plain)

  class << self
    def ui
      @ui ||= { tab: "status", sel: Hash.new(0), confirm: nil, fetched: {}, log: [], scroll: 0, open_plugin: nil }
    end

    def reset! = @ui = nil

    def g = GemdropScript
    def w = GemdropScript::W

    def buffer
      found = w.buffer_search("ruby", NAME).to_s
      found.empty? ? nil : found
    end

    def open(tab: nil)
      buf = buffer || create
      ui[:tab] = tab if tab
      ui[:scroll] = 0 if tab == "log"
      w.buffer_set(buf, "display", "1")
      tab_opened
      render
    end

    def create
      buf = w.buffer_new(NAME, "gemdrop_ui_input_cb", "", "gemdrop_ui_close_cb", "")
      w.buffer_set(buf, "type", "free")
      w.buffer_set(buf, "short_name", "gemdrop")
      w.buffer_set(buf, "notify", "3")
      w.buffer_set(buf, "localvar_set_no_log", "1")
      {
        "up" => "/gd ui up", "down" => "/gd ui down", "home" => "/gd ui first", "end" => "/gd ui last",
        "pgup" => "/gd ui pgup", "pgdn" => "/gd ui pgdn",
        "tab" => "/gd ui next", "shift-tab" => "/gd ui prev", "return" => "/gd ui enter",
        "left" => "/gd ui prev", "right" => "/gd ui next"
      }.merge((1..TABS.size).to_h { |n| ["meta-#{n}", "/gd ui tab #{n}"] })
        .merge(LETTERS.to_h { |letter| [letter, "/gd ui key #{letter}"] })
        .each { |key, command| w.buffer_set(buf, "key_bind_#{key}", command) }
      bind_mouse
      render_into(buf)
      buf
    end

    def bind_mouse
      area = "@chat(ruby.#{NAME})"
      w.key_bind("mouse", { "#{area}:button1" => "/gd ui click ${_chat_line_y} ${_chat_line_x}",
                            "#{area}:wheelup" => "/gd ui wheelup", "#{area}:wheeldown" => "/gd ui wheeldown" })
    end

    def unbind_mouse
      %w[button1 wheelup wheeldown].each { |button| w.key_unbind("mouse", "@chat(ruby.#{NAME}):#{button}") }
    end

    def closed = ui.delete(:items)

    def title
      buf = buffer or return
      server = g.buffer_server
      w.buffer_set(buf, "title", "Gemdrop · #{server || '?'}: #{g.state_text(server, color: false)} · type bot commands " \
                                 "here (@EFnet ... for another network), /gd help")
    end

    # --- the log ----------------------------------------------------------------------------------

    def add_log(kind, prefix, text, plain_prefix, plain, notify: 0)
      entry = Entry.new(Time.now, kind, prefix, text, plain_prefix, plain)
      log = ui[:log]
      log << entry
      log.shift(log.size - MAX_LOG) if log.size > MAX_LOG
      ui[:scroll] += 1 if ui[:scroll].positive? # keep the view still while scrolled back
      save_history(entry)
      buf = buffer || (notify.positive? ? create : nil) # something to see: the window appears in the list
      return unless buf

      w.buffer_set(buf, "hotlist", notify.to_s) if notify.positive?
      render
    end

    def log = ui[:log]

    def history_path = File.join(g.key_dir, "history.log")

    def save_history(entry)
      dir = g.key_dir
      Dir.mkdir(dir, 0o700) unless File.directory?(dir)
      File.open(history_path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
        file.puts("#{entry.at.strftime('%Y-%m-%d %H:%M:%S')}\t#{entry.kind}\t#{entry.plain_prefix}\t" \
                  "#{entry.plain.to_s.delete("\n")}")
      end
      trim_history if File.size(history_path) > HISTORY_BYTES
    rescue SystemCallError
      nil
    end

    def trim_history
      kept = File.readlines(history_path).last(MAX_LOG)
      File.write(history_path, kept.join, perm: 0o600)
    end

    def load_history
      return unless File.file?(history_path)

      File.readlines(history_path).last(HISTORY_LINES).each do |line|
        at, kind, prefix, text = line.chomp.split("\t", 4)
        time = Time.strptime(at.to_s, "%Y-%m-%d %H:%M:%S") rescue next
        ui[:log] << Entry.new(time, kind.to_s.to_sym, "#{c('darkgray')}#{prefix}#{c('default')}",
                              "#{c('darkgray')}#{text}#{c('default')}", prefix, text)
      end
    rescue SystemCallError
      nil
    end

    def log_line(entry, room)
      stamp = entry.at.strftime(entry.at.to_date == Date.today ? "%H:%M" : "%m-%d %H:%M")
      prefix = cell_colored(entry.prefix, entry.plain_prefix, 14)
      text = entry.text
      text = "#{text[0, room]}…" if entry.plain.length > room && !text.include?("\x19") # no colors: cut plainly
      "#{c('darkgray')}#{stamp}#{c('default')} #{prefix} #{text}#{c('default')}"
    end

    def cell_colored(colored, plain, size)
      plain.length >= size ? colored : "#{colored}#{' ' * (size - plain.length)}"
    end

    # --- commands from keys and the mouse ---------------------------------------------------------

    def command(buf, words)
      action = words.shift.to_s.downcase
      case action
      when "up" then move(-1)
      when "down" then move(1)
      when "first" then tab == "log" ? scroll_to(log.size) : move(-10_000)
      when "last" then tab == "log" ? scroll_to(0) : move(10_000)
      when "pgup" then tab == "log" ? scroll_to(ui[:scroll] + page) : move(-10)
      when "pgdn" then tab == "log" ? scroll_to(ui[:scroll] - page) : move(10)
      when "wheelup" then tab == "log" ? scroll_to(ui[:scroll] + 3) : move(-1)
      when "wheeldown" then tab == "log" ? scroll_to(ui[:scroll] - 3) : move(1)
      when "next" then switch_tab(tab_index + 1)
      when "prev" then switch_tab(tab_index - 1)
      when "tab" then switch_tab(words.first.to_i - 1)
      when "enter" then enter(buf)
      when "key" then letter(buf, words.first.to_s)
      when "click" then click(words[0].to_i, words[1].to_i)
      when "dump" then return dump
      else g.error("/gd ui up|down|pgup|pgdn|next|prev|tab <n>|enter|key <letter>|click <y> <x>")
      end
      render
    end

    def tab = ui[:tab]
    def tab_index = TABS.index { |name, _| name == tab } || 0

    def switch_tab(index)
      ui[:tab] = TABS[index % TABS.size].first
      ui[:confirm] = nil
      ui[:scroll] = 0
      tab_opened
    end

    # What a tab fetches when it opens.
    def tab_opened
      server = g.buffer_server
      case tab
      when "keys" then fetch_keys(server)
      when "bot" then fetch_plugins(server)
      end
    end

    def logged_in_on?(server) = server && g.state[:identified][g.key(server)] && g.state[:online][g.key(server)] != false

    def fetch(server, what, command, force: false)
      return unless logged_in_on?(server)

      last = ui[:fetched][[g.key(server), what]]
      return if !force && last && g.now - last < 30

      ui[:fetched][[g.key(server), what]] = g.now
      yield if block_given?
      g.send_bot(server, command, echo: false, remember: false)
    end

    def fetch_keys(server, force: false) = fetch(server, :keys, "KEY LIST", force: force)

    def fetch_plugins(server, force: false)
      fetch(server, :plugins, "PLUGIN LIST", force: force) { g.state[:plugin_list][g.key(server)] = [] }
      fetch_settings(server, ui[:open_plugin], force: force) if ui[:open_plugin]
    end

    def fetch_settings(server, plugin, force: false)
      fetch(server, [:settings, plugin], "PLUGIN SETTINGS #{plugin}", force: force) do
        (g.state[:plugin_settings][g.key(server)] ||= {})[plugin] = []
      end
    end

    def keys_changed(server)
      ui[:fetched].delete([g.key(server), :keys])
      fetch_keys(server) if buffer && tab == "keys"
    end

    def plugin_changed(server, plugin)
      ui[:fetched].delete([g.key(server), [:settings, plugin]])
      fetch_settings(server, plugin) if buffer && tab == "bot" && ui[:open_plugin] == plugin
    end

    def items = ui[:items] || []

    def selected
      list = items
      return nil if list.empty?

      ui[:sel][tab] = ui[:sel][tab].clamp(0, list.size - 1)
      list[ui[:sel][tab]]
    end

    def move(by)
      ui[:sel][tab] += by
      ui[:confirm] = nil
      selected
    end

    def scroll_to(lines)
      ui[:scroll] = lines.clamp(0, [log.size - page, 0].max)
    end

    def enter(buf)
      input = w.buffer_get_string(buf, "input").to_s
      unless input.strip.empty? # typed something: a command, a shortcut, or something for the bot
        w.buffer_set(buf, "input", "")
        return w.command(buf, input) if input.start_with?("/")
        return letter(buf, input.strip, typed: true) if input.strip.length == 1

        return g.input(input)
      end
      selected&.enter&.call
    end

    # A letter key: a shortcut when the input line is empty, else typing.
    def letter(buf, char, typed: false)
      unless typed || w.buffer_get_string(buf, "input").to_s.empty?
        return w.command(buf, "/input insert #{char}")
      end

      case char
      when "q" then return w.buffer_close(buffer) if buffer
      when "L" then return switch_tab(TABS.index { |name, _| name == "log" })
      when "r" then return refresh_now
      when "n" then return next_server
      when "?" then return g.note("Keys: ↑↓ ⏎, Tab or alt-1..#{TABS.size} for tabs, PgUp/PgDn, q closes. Type bot " \
                                  "commands in the input line. Here: #{FOOTERS[tab]}")
      end
      action = selected&.keys&.[](char) or return
      action.call
    end

    def click(y, x)
      if y == 1 # the tabs
        @tab_spans&.each { |(from, to), index| return switch_tab(index) if x.between?(from, to) }
        return
      end
      index = items.index { |item| item.line == y } or return
      if ui[:sel][tab] == index then selected&.enter&.call # a second click: do it
      else ui[:sel][tab] = index
      end
    end

    def refresh_now
      g.bot_servers.each { |server| g.check_bot(server, :whoami) if g.connected?(server) }
      server = g.buffer_server
      fetch_keys(server, force: true) if tab == "keys"
      fetch_plugins(server, force: true) if tab == "bot"
    end

    def next_server
      servers = g.bot_servers
      return if servers.empty?

      index = servers.index(g.buffer_server) || -1
      g.state[:buffer_server] = servers[(index + 1) % servers.size]
      title
      tab_opened
    end

    # Runs it after a second press within a few seconds.
    def confirmed?(what, question)
      if ui[:confirm] && ui[:confirm][0] == what && g.now - ui[:confirm][1] <= CONFIRM_SECONDS
        ui[:confirm] = nil
        return true
      end
      ui[:confirm] = [what, g.now, question]
      false
    end

    # Puts a command in the input line to finish and run with ⏎.
    def prefill(text)
      w.buffer_set(buffer, "input", text)
      w.buffer_set(buffer, "input_pos", text.length.to_s)
    end

    # --- drawing ----------------------------------------------------------------------------------

    def render
      buf = buffer or return
      render_into(buf)
    end

    def render_into(buf)
      @rendering_for = buf
      lines = []
      list = []
      header(lines)
      case tab
      when "status" then status_tab(lines, list)
      when "settings" then settings_tab(lines, list)
      when "keys" then keys_tab(lines, list)
      when "channels" then channels_tab(lines, list)
      when "bot" then bot_tab(lines, list)
      when "log" then log_tab(lines)
      end
      ui[:items] = list
      chosen = selected
      footer(lines, chosen)
      w.buffer_clear(buf)
      @drawn = lines.each_with_index.map do |text, y|
        mark = chosen && chosen.line == y
        mark ? "#{c('yellow')}❯#{c('default')} #{c('bold')}#{text}#{c('-bold')}" : "  #{text}"
      end
      @drawn.each_with_index { |text, y| w.print_y(buf, y, text) }
      title
    end

    def c(name) = w.color(name)

    def window
      found = w.window_search_with_buffer(@rendering_for || buffer).to_s
      found.empty? ? nil : found
    end

    def width = window ? w.window_get_integer(window, "win_chat_width").clamp(40, 400) : 100
    def height = window ? w.window_get_integer(window, "win_chat_height").clamp(10, 300) : 40
    def page = [height - 8, 5].max

    def rule = "#{c('blue')}#{'─' * (width - 4)}#{c('default')}"

    def header(lines)
      servers = g.bot_servers
      summary = servers.map { |s| "#{c('bold')}#{s}#{c('-bold')} #{g.state_text(s)}" }
                       .join("#{c('darkgray')}  │  #{c('default')}")
      lines << "#{c('*lightcyan')}Gemdrop#{c('default')}   #{summary.empty? ? 'no bot yet: Settings, bots' : summary}"
      x = 2
      spans = {}
      tabs = TABS.each_with_index.map do |(name, label), i|
        text = " #{i + 1} #{label} "
        spans[[x, x + text.length - 1]] = i
        x += text.length + 1
        name == tab ? "#{c('black,cyan')}#{text}#{c('default')}" : "#{c('cyan')}#{text}#{c('default')}"
      end
      @tab_spans = spans
      lines << tabs.join(" ")
      lines << rule
    end

    def footer(lines, chosen)
      lines << ""
      if tab != "log" # the latest lines of the log, so what you do shows here
        lines << rule
        log.last(STRIP).each { |entry| lines << log_line(entry, width - 24) }
      end
      lines << rule
      help = chosen&.help.to_s
      if ui[:confirm] && g.now - ui[:confirm][1] <= CONFIRM_SECONDS
        help = "#{c('*yellow')}#{ui[:confirm][2]} Press again to confirm.#{c('default')}"
      end
      wrap(help, width - 4).each { |line| lines << line } unless help.empty?
      wrap("#{FOOTERS[tab]} · tab/alt-1..#{TABS.size} tabs · q close · ? keys · type bot commands below",
           width - 4).each { |line| lines << "#{c('darkgray')}#{line}#{c('default')}" }
    end

    def wrap(text, size)
      text.scan(/\S.{0,#{size - 2}}(?=\s|\z)|\S+/)
    end

    def section(lines, title) = lines << "#{c('bold')}#{c('lightcyan')}#{title}#{c('default')}#{c('-bold')}"

    def yes(flag, on = "✓", off = "·") = flag ? "#{c('green')}#{on}#{c('default')}" : "#{c('darkgray')}#{off}#{c('default')}"

    def cell(text, size) = text.to_s.length >= size ? "#{text.to_s[0, size - 1]}…" : text.to_s.ljust(size)

    def dim(text) = "#{c('darkgray')}#{text}#{c('default')}"

    # --- the tabs ---------------------------------------------------------------------------------

    def status_tab(lines, list)
      servers = g.bot_servers
      return lines << "No server has a bot yet: Settings tab, bots (e.g. IRCnet=Linuks,EFnet=Linuks)." if servers.empty?

      servers.each do |server|
        k = g.key(server)
        online = g.state[:online][k]
        host = g.state[:bot_host][k]
        mask = g.hostmask(server)
        trusted = mask && host && g.host_matches?(mask, host)
        account = g.state[:identified][k]
        method = g.login_method(server)
        list << Item.new(lines.size, "#{server}: ⏎ or i logs in now (#{method || 'no key or password'}), l logs out, " \
                                     "w asks who you are. Typed commands go to #{server == g.buffer_server ? 'this' : 'the selected'} " \
                                     "network (n switches).",
                         -> { g.identify(server) },
                         { "i" => -> { g.identify(server) }, "l" => -> { g.send_bot(server, "LOGOUT") },
                           "w" => -> { g.send_bot(server, "WHOAMI") } })
        here = server == g.buffer_server ? " #{c('cyan')}◂ typed commands go here#{c('default')}" : ""
        lines << "#{c('bold')}#{server}#{c('-bold')}#{g.connected?(server) ? '' : " #{c('red')}(not connected)#{c('default')}"}#{here}"
        trust = if mask.nil? then "#{c('yellow')}host not pinned yet#{c('default')}"
                elsif trusted then "#{c('green')}trusted#{c('default')}"
                elsif host then "#{c('*red')}NOT the trusted host (#{mask})#{c('default')}"
                else "pinned to #{mask}"
                end
        lines << "   Bot       #{g.bot_nick(server)}  #{online.nil? ? '?' : yes(online, 'online', 'offline')}" \
                 "#{"  #{host}" if host}  #{trust}"
        lines << "   You       #{account ? "#{c('green')}✓ logged in as #{account}#{c('default')}" : "#{c('yellow')}not logged in#{c('default')}"}" \
                 "   (logs in with: #{method || "#{c('red')}nothing#{c('default')}"})"
        lines << "   Key       #{g.key_exists? ? yes(g.key_login?(server), 'works here', 'not used here yet') : dim('none (Keys tab)')}" \
                 "   Password #{g.secret(server) ? "#{c('green')}kept#{c('default')}" : dim('none')}"
        lines << "   Auto      #{%w[connect bot load request].map { |o| "#{o} #{yes(g.auto?(o.to_sym))}" }.join('  ')}"
        lines << ""
      end
    end

    def settings_tab(lines, list)
      SETTING_GROUPS.each do |title, names|
        section(lines, title)
        names.each do |name|
          default, desc = GemdropScript::OPTIONS.fetch(name)
          value = g.option(name)
          shown = if BOOLEANS.include?(name) then yes(g.on?(name), "on ", "off")
                  elsif value.empty? then dim("(empty)")
                  else "#{c('lightcyan')}#{value}#{c('default')}"
                  end
          changed = value == default ? "" : " #{c('yellow')}*#{c('default')}"
          list << Item.new(lines.size, "#{name}: #{desc}. Default: #{default.empty? ? '(empty)' : default}.",
                           -> { change(name) }, { "d" => -> { w.config_set_plugin(name, default) } })
          lines << "   #{cell(name, 22)} #{shown}#{changed}"
        end
        lines << ""
      end
      networks_section(lines, list)
      lines << dim("* changed from the default")
    end

    # Per network: the kept password and the bot's pinned host.
    def networks_section(lines, list)
      section(lines, "Networks")
      g.bot_servers.each do |server|
        kept = !g.secret(server).nil?
        list << Item.new(lines.size, "#{server}'s password, kept in /secure (#{g.secure_name(server)}): ⏎ puts " \
                                     "/gd secret set in the input line (the password is hidden as you type); " \
                                     "x (twice) deletes it.",
                         -> { prefill("/gd secret set #{server} ") },
                         { "x" => -> { forget_password(server) } })
        lines << "   #{cell("#{server} password", 22)} #{kept ? "#{c('green')}kept#{c('default')}" : dim('none')}"
        mask = g.hostmask(server)
        list << Item.new(lines.size, "The bot's host on #{server}: logins only go to it. ⏎ puts /gd trust in the input " \
                                     "line to set it; x (twice) unpins it (the next /gd identify pins it again).",
                         -> { prefill("/gd trust #{server} #{mask}") },
                         { "x" => -> { unpin(server) } })
        lines << "   #{cell("#{server} bot host", 22)} #{mask ? "#{c('lightcyan')}#{mask}#{c('default')}" : dim('not pinned')}"
      end
      lines << ""
    end

    def forget_password(server)
      g.command(buffer, "secret del #{server}") if confirmed?([:forget, server], "Delete #{server}'s kept password?")
    end

    def unpin(server)
      g.trust_command(server, ["reset"]) if confirmed?([:unpin, server], "Unpin the bot's host on #{server}?")
    end

    # Booleans toggle, choices cycle; anything else goes to the input line
    # as a /set to edit (⏎ runs it).
    def change(name)
      if BOOLEANS.include?(name)
        w.config_set_plugin(name, g.on?(name) ? "off" : "on")
      elsif (choices = CHOICES[name])
        w.config_set_plugin(name, choices[((choices.index(g.option(name)) || -1) + 1) % choices.size])
      else
        text = %(/set plugins.var.ruby.#{SCRIPT_NAME}.#{name} "#{g.option(name)}")
        prefill(text)
        w.buffer_set(buffer, "input_pos", (text.length - 1).to_s)
      end
    end

    def keys_tab(lines, list)
      server = g.buffer_server
      section(lines, "Your Gemdrop key")
      if g.key_exists?
        list << Item.new(lines.size, "Your key pair, made for Gemdrop only: #{g.key_path}, encrypted with a passphrase " \
                                     "in /secure. ⏎ shows the public key in the log; a gives it to the bot on #{server}.",
                         -> { g.key_command(server, ["show"]) }, { "a" => -> { g.key_command(server, ["add"]) } })
        lines << "   #{g.key_text}"
      else
        list << Item.new(lines.size, "⏎ makes a key pair for Gemdrop only; a makes one and gives it to the bot on #{server}.",
                         -> { g.key_command(server, ["create"]) }, { "a" => -> { g.key_command(server, ["add"]) } })
        lines << "   #{c('yellow')}none yet#{c('default')} - ⏎ makes one"
      end
      lines << ""
      section(lines, "Logging in with it")
      g.bot_servers.each do |s|
        works = g.key_login?(s)
        list << Item.new(lines.size, "#{s}: ⏎ #{works ? 'stops using' : 'uses'} the key for logins there " \
                                     "(the bot's keys work on all its networks).",
                         -> { g.mark_key_login(s, !works) }, {})
        lines << "   #{cell(s, 10)} #{yes(works, 'uses the key', 'uses the password')}"
      end
      lines << ""
      section(lines, "Your keys on the bot (#{server || '?'}#{', n switches' if g.bot_servers.size > 1})")
      return lines << "   #{dim("log in on #{server || 'a network'} to see them")}" unless logged_in_on?(server)

      keys = g.state[:bot_keys][g.key(server)]
      lines << "   #{dim('asking the bot...')}" if keys.nil?
      lines << "   #{dim('none: a gives it yours')}" if keys && keys.empty?
      (keys || []).each do |entry|
        mine = g.key_exists? && entry[:fp] == g.key_text
        list << Item.new(lines.size, "#{entry[:fp]}#{" (#{entry[:comment]})" unless entry[:comment].empty?}: d (twice) " \
                                     "removes it from the bot.",
                         -> {}, { "d" => -> { delete_key(server, entry) } })
        lines << "   #{entry[:n]}. #{cell(entry[:fp], 24)} #{cell(entry[:comment], 24)} added #{entry[:added]}, " \
                 "#{entry[:used] ? "used #{entry[:used]}" : 'never used'}#{"  #{c('green')}(this one)#{c('default')}" if mine}"
      end
      only = g.state[:key_only][g.key(server)]
      list << Item.new(lines.size, "Key-only: the bot refuses password logins to your account. ⏎ or o (twice) " \
                                   "turns it #{only ? 'off' : 'on'}.",
                       -> { key_only(server, !only) }, { "o" => -> { key_only(server, !only) } })
      lines << "   Password logins: #{if only.nil? then '?'
                                      elsif only then "#{c('green')}refused (key only)#{c('default')}"
                                      else 'allowed'
                                      end}"
    end

    def delete_key(server, entry)
      return unless confirmed?([:delete, entry[:fp]], "Remove #{entry[:fp]} from the bot?")

      g.send_bot(server, "KEY DEL #{entry[:n]}")
    end

    def key_only(server, on)
      return unless confirmed?([:only, on], "Turn key-only #{on ? 'on: passwords stop working' : 'off'}?")

      g.send_bot(server, "KEY ONLY #{on ? 'on' : 'off'}")
    end

    def channels_tab(lines, list)
      any = false
      g.bot_servers.each do |server|
        next unless g.connected?(server)

        section(lines, server)
        lines << "   #{dim("#{cell('channel', 22)} bot   autoup   autosummary")}"
        g.channels_of(server).each do |channel|
          any = true
          list << Item.new(lines.size, "#{channel} on #{server}: u autoup (op when you join), s autosummary (a summary " \
                                       "when you rejoin), U op me now, S sum up now.",
                           -> { toggle("autoup", server, channel) },
                           { "u" => -> { toggle("autoup", server, channel) },
                             "s" => -> { toggle("autosummary", server, channel) },
                             "U" => -> { g.send_bot(server, "UP #{channel}") },
                             "S" => -> { g.send_bot(server, "AISUMMARY #{channel}") } })
          lines << "   #{cell(channel, 22)} #{yes(g.bot_in?(server, channel))}     " \
                   "#{yes(g.channel_listed?('autoup', server, channel), '[x]', '[ ]')}      " \
                   "#{yes(g.channel_listed?('autosummary', server, channel), '[x]', '[ ]')}"
        end
        lines << ""
      end
      lines << "No channels yet." unless any
    end

    def toggle(name, server, channel)
      items = g.option(name).split(",").map(&:strip).reject(&:empty?)
      entry = "#{server}/#{channel}"
      kept = items.reject { |item| item.casecmp?(entry) }
      w.config_set_plugin(name, (kept.size == items.size ? kept + [entry] : kept).join(","))
    end

    # The bot's plugins and their settings (bot admins).
    def bot_tab(lines, list)
      server = g.buffer_server
      section(lines, "Plugins on #{server || '?'}#{' (n switches network)' if g.bot_servers.size > 1}")
      return lines << "   #{dim("log in on #{server || 'a network'} to see them (bot admins)")}" unless logged_in_on?(server)

      plugins = g.state[:plugin_list][g.key(server)]
      return lines << "   #{dim('asking the bot... (only bot admins get an answer)')}" if plugins.nil? || plugins.empty?

      plugins.sort_by { |p| p[:name] }.each do |plugin|
        name = plugin[:name]
        open = ui[:open_plugin] == name
        color = { "loaded" => "green", "unloaded" => "darkgray", "installing" => "yellow" }.fetch(plugin[:state], "red")
        info = plugin[:info].to_s[0, 300].sub(/(?<![.!?])\z/, ".")
        list << Item.new(lines.size, "#{name}: #{info} ⏎ #{open ? 'closes' : 'opens'} its " \
                                     "settings; R reloads it.",
                         -> { open_plugin(server, open ? nil : name) },
                         { "R" => -> { g.send_bot(server, "PLUGIN RELOAD #{name}") } })
        lines << "   #{open ? '▾' : '▸'} #{c('bold')}#{cell(name, 14)}#{c('-bold')} #{c(color)}#{plugin[:state]}#{c('default')}"
        next unless open

        rows = (g.state[:plugin_settings][g.key(server)] || {})[name]
        lines << "       #{dim('asking the bot...')}" if rows.nil? || rows.empty?
        (rows || []).each do |row|
          list << Item.new(lines.size, "#{name} #{row[:name]} = #{row[:value][0, 300]}. ⏎ #{boolean?(row) ? 'toggles it' : 'puts /gd set in the input line to edit it'}" \
                                       "#{'; x (twice) goes back to config.yml' if row[:saved]}. Per channel: /gd set #{name} #chan #{row[:name]} <value>.",
                           -> { change_plugin_setting(server, name, row) },
                           { "x" => -> { unset_plugin_setting(server, name, row) } })
          saved = row[:saved] ? " #{c('yellow')}(set here)#{c('default')}" : ""
          lines << "       #{cell(row[:name], 24)} #{g.value_color(row[:value])}#{cell(row[:value], [width - 40, 20].max)}#{c('default')}#{saved}"
        end
      end
    end

    def boolean?(row) = %w[true false].include?(row[:value])

    def open_plugin(server, name)
      ui[:open_plugin] = name
      fetch_settings(server, name) if name
    end

    def change_plugin_setting(server, plugin, row)
      if boolean?(row)
        g.send_bot(server, "PLUGIN SET #{plugin} #{row[:name]} #{row[:value] == 'true' ? 'false' : 'true'}")
      else
        prefill("/gd set #{plugin} #{row[:name]} #{row[:value]}")
      end
    end

    def unset_plugin_setting(server, plugin, row)
      return unless row[:saved] && confirmed?([:unset, plugin, row[:name]], "Put #{plugin} #{row[:name]} back to config.yml?")

      g.send_bot(server, "PLUGIN UNSET #{plugin} #{row[:name]}")
    end

    def log_tab(lines)
      room = height - 8
      shown = log[[log.size - room - ui[:scroll], 0].max, room] || []
      if ui[:scroll].positive?
        lines << dim("… #{ui[:scroll]} newer line#{'s' unless ui[:scroll] == 1} below (End: the latest)")
        shown = shown.first(room - 1)
      end
      lines << dim("nothing yet") if shown.empty?
      shown.each { |entry| lines << log_line(entry, width - 24) }
    end

    # The window as plain text in the log (WeeChat doesn't log free
    # buffers), to check what it shows.
    def dump
      render
      (@drawn || []).each { |line| g.note("|#{w.string_remove_color(line, '')}") }
    end

    def drawn = @drawn || []
  end
end

# --- WeeChat's callbacks (by name) ----------------------------------------------------------------

def weechat_init
  Weechat.register(SCRIPT_NAME, SCRIPT_AUTHOR, SCRIPT_VERSION, SCRIPT_LICENSE, SCRIPT_DESC, "gemdrop_shutdown_cb", "")
  GemdropScript.reset!
  # What was sent just before a /ruby reload still counts against the bot's limit.
  GemdropScript.state[:sent_at] = $gemdrop_sent_at if $gemdrop_sent_at.is_a?(Hash)
  GemdropUI.reset!
  GemdropUI.load_history
  GemdropScript::OPTIONS.each do |name, (default, desc)|
    Weechat.config_set_plugin(name, default) unless Weechat.config_is_set_plugin(name) == 1
    Weechat.config_set_desc_plugin(name, "#{desc} (default: \"#{default}\")")
  end

  completion = [
    "ui|log|status|whoami|logout|aistatus|plugins|catchup|more|setup %(gemdrop_servers)",
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
  args = "[ui|log|status|identify|key|logout|whoami|register|password|secret|trust|send|summary|catchup|ai|chat|forget|aistatus|" \
         "agent|up|down|kick|kb|ban|unban|topic|access|mlock|chankey|plugins|settings|set|unset|reload|logsearch|" \
         "links|title|help|list|more|setup] [@server] [args]"
  help = <<~HELP
    Without arguments: opens the gemdrop window, one full-window view with tabs (Status, Settings, Keys, Channels, Bot, Log): arrows move, Enter toggles or edits, letters are shortcuts (shown at the bottom), tab or alt-1..6 switch tabs, PgUp/PgDn scroll, q closes; the mouse works too. Type bot commands in its input line (HELP, WHOAMI ...; @server ... for another network); what the bot says shows at the bottom of every tab and in the Log tab.
    /gd log opens it on the Log tab.

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

    Settings (the window's Settings tab, or /fset gemdrop): bots, hostmasks, accounts, autoidentify, identify_on_connect, identify_on_bot, identify_on_load, identify_on_request, identify_delay, login, key_logins, retry, capture, echo, autoup, autosummary, autorun, watchdog, check_interval.

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
  # Already connected (the script loaded late): find out where things stand,
  # and log in where we aren't (identify_on_load).
  GemdropScript.bot_servers.each do |server|
    next unless GemdropScript.connected?(server)

    GemdropScript.check_bot(server, GemdropScript.auto?(:load) ? :ensure_login : :whoami)
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

def gemdrop_ui_input_cb(_data, buffer, input)
  GemdropUI.command(buffer, ["enter"]) if input.to_s.strip.empty?
  GemdropScript.input(input) unless input.to_s.strip.empty?
  Weechat::WEECHAT_RC_OK
end

def gemdrop_ui_close_cb(_data, _buffer)
  GemdropUI.closed
  Weechat::WEECHAT_RC_OK
end

def gemdrop_shutdown_cb
  $gemdrop_sent_at = GemdropScript.state[:sent_at]
  GemdropUI.unbind_mouse
  Weechat::WEECHAT_RC_OK
end

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
