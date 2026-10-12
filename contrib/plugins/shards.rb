# Shards: small Gemshard bots (github.com/cban1980/gemshard), each on a
# server of its own on the same network, that keep this bot's channels as
# they should be when it is away: in the same channels, with the right
# people opped and voiced, the mode locks kept and the bots opping each
# other, also across a netsplit or while this bot reconnects. This bot is
# their only source of truth: they get everything from it, learn about
# each other from it, and talk to nobody else.
#
#   /msg Linuks SHARD INFO                     this bot's key, for a shard's config
#   /msg Linuks SHARD ADD <name> <fingerprint> let a shard link (its key's fingerprint)
#   /msg Linuks SHARD LIST | SHARD DEL <name>
#
# Shards link over IRC notices, and also over a direct TLS link (setting
# listen, port 7700) where they can reach it; the link is faster and is
# used first. Either way the same protocol protects it: signed hellos
# with pinned Ed25519 keys, then AES-256-GCM with fresh keys for every
# session, numbered so nothing can be played again (docs/shards.md).
# Shards get: the channels this bot is in (and their keys), access lists,
# hostmasks, mode locks, who is logged in as what, and the other shards.
# Passwords, keys and the rest of the bot's data never go out, and shards
# can't change anything here.
#
# Install:  bin/gemdrop-docker plugin install contrib/plugins/shards.rb
# For the TLS link, publish the port: bin/gemdrop-docker ports add 7700
require "base64"
require "digest"
require "json"
require "openssl"
require "securerandom"
require "socket"
require "timeout"
require "zlib"

class Shards < Gemdrop::Plugin
  description "Links Gemshard bots that keep the channels' modes while this bot is away"
  help_group "Admin"

  setting "listen", default: "0.0.0.0:7700", type: :string, locked: true,
                    desc: "where shards connect for the TLS link (\"\": IRC only)"
  setting "max_shards", default: 16, type: :integer, min: 1, max: 100
  setting "irc_state_seconds", default: 10, type: :integer, min: 2, max: 600,
                               desc: "at most one state update per shard this often over IRC (flood limits)"

  NAME = /\A[a-z0-9][a-z0-9_-]{0,31}\z/
  MAX_LINE = 4096         # bytes a shard's line may have on the TLS link
  HANDSHAKE_SECONDS = 10
  PING = { tcp: 20, irc: 120 }.freeze     # seconds between pings
  EXPIRE = { tcp: 70, irc: 330 }.freeze   # a session silent this long is over
  MODES_PER_LINE = 3

  # The secure layer between a shard and its hub, the same over IRC notices
  # and over the TLS link (docs/protocol.md). This module is a copy of Gemshard's
  # lib/gemshard/protocol.rb; keep the two the same.
  #
  # Each side has an Ed25519 identity key; the other side pins its
  # fingerprint. A session starts with signed hellos carrying fresh X25519
  # keys; HKDF turns their shared secret into one AES-256-GCM key per
  # direction. Every message is then compressed, encrypted and numbered:
  # nothing can be read, changed or played again, and a new session has
  # new keys (forward secrecy).
  module Protocol
    VERSION = 1
    CLOCK_SKEW = 300         # seconds a hello's time may be off
    ED25519_SPKI = ["302a300506032b6570032100"].pack("H*").freeze
    X25519_SPKI = ["302a300506032b656e032100"].pack("H*").freeze
    IRC_TAG = "GS1"          # starts every IRC line of the protocol
    IRC_CHUNK = 300          # base64 characters per IRC line
    MAX_CHUNKS = 64
    MAX_MESSAGE = 256 * 1024 # bytes of a message, uncompressed

    class Error < StandardError; end

    module_function

    def b64(bytes) = Base64.strict_encode64(bytes)

    def unb64(text)
      Base64.strict_decode64(text.to_s)
    rescue ArgumentError
      raise Error, "bad base64"
    end

    def raw_public(key) = key.public_to_der[-32..]

    def ed25519_public(raw)
      raise Error, "a key is 32 bytes" unless raw.bytesize == 32

      OpenSSL::PKey.read(ED25519_SPKI + raw)
    end

    def x25519_public(raw)
      raise Error, "a key is 32 bytes" unless raw.bytesize == 32

      OpenSSL::PKey.read(X25519_SPKI + raw)
    end

    # "SHA256:..." of an Ed25519 public key (its SubjectPublicKeyInfo).
    def fingerprint(key) = "SHA256:#{b64(Digest::SHA256.digest(key.public_to_der)).delete('=')}"

    # --- the handshake: signed hellos -----------------------------------------------------------

    # A signed message: {"m" => json, "s" => signature}, as one string.
    def signed(identity, message)
      json = JSON.generate(message)
      JSON.generate("m" => json, "s" => b64(identity.sign(nil, json)))
    end

    # The message of a signed string, if the key in it ("id") signed it.
    # Returns [message, the signer's public key].
    def verify_signed(text)
      outer = JSON.parse(text)
      raise Error, "not a signed message" unless outer.is_a?(Hash) && outer["m"].is_a?(String)

      message = JSON.parse(outer["m"])
      raise Error, "not a signed message" unless message.is_a?(Hash)

      key = ed25519_public(unb64(message["id"]))
      raise Error, "bad signature" unless key.verify(nil, unb64(outer["s"]), outer["m"])

      [message, key]
    rescue JSON::ParserError, OpenSSL::PKey::PKeyError
      raise Error, "not a signed message"
    end

    def fresh?(message, now = Time.now.to_i) = (message["at"].to_i - now).abs <= CLOCK_SKEW

    # Half of a handshake: what this side keeps, and the hello to send.
    # type: "hello" (the shard) or "welcome" (the hub); fields: more to say.
    def start(identity, type, fields = {})
      ephemeral = OpenSSL::PKey.generate_key("X25519")
      nonce = SecureRandom.random_bytes(16)
      message = { "t" => type, "v" => VERSION, "id" => b64(raw_public(identity)), "eph" => b64(raw_public(ephemeral)),
                  "nonce" => b64(nonce), "at" => Time.now.to_i }.merge(fields)
      [{ ephemeral: ephemeral, nonce: nonce }, signed(identity, message)]
    end

    # The session from both hellos. mine: what start kept; theirs: the other
    # side's verified hello; shard: true on the shard's side.
    def session(mine, theirs, my_key, their_key, shard:)
      shared = mine[:ephemeral].derive(x25519_public(unb64(theirs["eph"])))
      shard_nonce, hub_nonce = shard ? [mine[:nonce], unb64(theirs["nonce"])] : [unb64(theirs["nonce"]), mine[:nonce]]
      shard_fp, hub_fp = shard ? [fingerprint(my_key), fingerprint(their_key)] : [fingerprint(their_key), fingerprint(my_key)]
      keys = OpenSSL::KDF.hkdf(shared, salt: shard_nonce + hub_nonce, info: "gemshard v1 #{shard_fp} #{hub_fp}",
                                       length: 64, hash: "SHA256")
      to_hub = keys.byteslice(0, 32)
      to_shard = keys.byteslice(32, 32)
      Session.new(shard ? to_hub : to_shard, shard ? to_shard : to_hub,
                  Digest::SHA256.hexdigest(shard_nonce + hub_nonce)[0, 12])
    end

    # One direction's key and counter each way. seal and open are the
    # messages' only way in and out once the handshake is done.
    class Session
      attr_reader :id

      def initialize(send_key, receive_key, id)
        @send_key = send_key
        @receive_key = receive_key
        @id = id
        @sent = 0
        @received = 0
        @lock = Mutex.new
      end

      # A message (a hash) as base64: counter, then AES-256-GCM of the
      # compressed JSON, then the tag.
      def seal(message)
        counter = @lock.synchronize { @sent += 1 }
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = @send_key
        cipher.iv = iv(counter)
        cipher.auth_data = "gs1"
        data = cipher.update(Zlib::Deflate.deflate(JSON.generate(message))) + cipher.final
        Protocol.b64([counter].pack("Q>") + data + cipher.auth_tag)
      end

      # The message in a sealed string; raises Error if it was changed,
      # isn't for this session, or was seen before.
      def open(text)
        bytes = Protocol.unb64(text)
        raise Error, "too short" if bytes.bytesize < 8 + 16

        counter = bytes.byteslice(0, 8).unpack1("Q>")
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = @receive_key
        cipher.iv = iv(counter)
        cipher.auth_tag = bytes.byteslice(-16, 16)
        cipher.auth_data = "gs1"
        plain = cipher.update(bytes.byteslice(8, bytes.bytesize - 24)) + cipher.final
        @lock.synchronize do
          raise Error, "played again" if counter <= @received

          @received = counter
        end
        json = Zlib::Inflate.new.then { |z| z.inflate(plain).tap { z.close } }
        raise Error, "too big" if json.bytesize > MAX_MESSAGE

        message = JSON.parse(json)
        raise Error, "not a message" unless message.is_a?(Hash)

        message
      rescue OpenSSL::Cipher::CipherError
        raise Error, "not ours (changed, or another session's)"
      rescue Zlib::Error, JSON::ParserError
        raise Error, "not a message"
      end

      private

      def iv(counter) = "\0\0\0\0#{[counter].pack('Q>')}".b
    end

    # --- IRC: lines of at most IRC_CHUNK characters ---------------------------------------------------

    # "GS1 <tag> <i>/<n> <part>" lines for a payload (a hello, or a sealed
    # message); tag says what it is ("h" for handshakes, else the session id).
    def irc_lines(tag, payload)
      text = tag == "h" ? b64(payload) : payload
      parts = text.scan(/.{1,#{IRC_CHUNK}}/)
      raise Error, "too big for IRC" if parts.size > MAX_CHUNKS

      message_id = SecureRandom.hex(3)
      parts.each_with_index.map { |part, i| "#{IRC_TAG} #{tag} #{message_id} #{i + 1}/#{parts.size} #{part}" }
    end

    # Puts IRC lines back together, per sender. feed returns [tag, payload]
    # once a message is complete, else nil.
    class Assembler
      TIMEOUT = 120

      def initialize = @pending = {}

      def feed(sender, line)
        _proto, tag, message_id, position, part = line.split(" ", 5)
        index, total = position.to_s.split("/").map(&:to_i)
        return nil unless tag && part && total.to_i.between?(1, MAX_CHUNKS) && index.between?(1, total)

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @pending.delete_if { |_, entry| entry[:at] < now - TIMEOUT }
        entry = (@pending[[sender.downcase, message_id]] ||= { parts: {}, total: total, at: now, tag: tag })
        return nil unless entry[:total] == total && entry[:tag] == tag

        entry[:parts][index] = part
        return nil unless entry[:parts].size == total

        @pending.delete([sender.downcase, message_id])
        text = (1..total).map { |i| entry[:parts][i] }.join
        [tag, tag == "h" ? Protocol.unb64(text) : text]
      end
    end
  end

  def setup
    @assembler = Protocol::Assembler.new
    @hellos = {}  # nonces of hellos seen lately: a hello is only taken once
    @op_asked = {}
    every(2) { tick }
    start_listener if primary? && !settings["listen"].to_s.empty?
  end

  def teardown
    stop_listener if @server
  end

  on(:notice) { |event| irc_in(event) }

  command "SHARD", usage: "SHARD INFO | LIST | ADD <name> <fingerprint> | DEL <name>", admin: true,
                   where: :private, help: "Gemshard bots that keep the channels while this bot is away",
                   details: "SHARD INFO shows this bot's key fingerprint and nick, for a shard's config.\n" \
                            "SHARD ADD <name> <fingerprint> lets the shard with that key link, for this network " \
                            "(the shard prints its fingerprint when it starts).\n" \
                            "SHARD LIST shows the shards and how they are linked; SHARD DEL <name> removes one." do |ctx, args|
    sub = args.shift.to_s.upcase
    case sub
    when "INFO"
      ctx.reply_privately("In a shard's config: hub_nick: #{bot_nick}, hub_fingerprint: #{hub_fingerprint}" \
                          "#{", hub_address: <this host>:#{listen_port} (for the TLS link)" unless settings['listen'].to_s.empty?}")
    when "ADD" then add_shard(ctx, args)
    when "DEL" then delete_shard(ctx, args)
    when "LIST" then list_shards(ctx)
    else usage!("SHARD INFO | LIST | ADD <name> <fingerprint> | DEL <name>")
    end
  end

  private

  # --- the allowlist (for all networks; each shard is for one) ---------------------------------------

  def allowed = shared_data["shards"] || {}

  def add_shard(ctx, args)
    name, fingerprint = args
    usage!("SHARD ADD <name> <fingerprint>") unless name && fingerprint
    name = name.downcase
    raise Gemdrop::Error, "A name is 1-32 of a-z, 0-9, _ and -." unless name.match?(NAME)

    fingerprint = fingerprint.sub(/\A(?:sha256:)?/i, "SHA256:")
    raise Gemdrop::Error, "That isn't a fingerprint (SHA256:... as the shard prints it)." unless
      fingerprint.match?(%r{\ASHA256:[A-Za-z0-9+/]{43}\z})

    shared_data.update do |data|
      shards = (data["shards"] ||= {})
      if shards.size >= settings["max_shards"] && !shards.key?(name)
        raise Gemdrop::Error, "There are #{settings['max_shards']} shards already."
      end
      if (other = shards.find { |n, s| s["fingerprint"] == fingerprint && n != name })
        raise Gemdrop::Error, "That key is shard #{other.first}'s already."
      end

      shards[name] = { "fingerprint" => fingerprint, "network" => network, "added_by" => ctx.account,
                       "added" => Time.now.utc.strftime("%Y-%m-%d") }
    end
    log.info("#{ctx.account} added shard #{name} (#{fingerprint}) for #{network}")
    ctx.reply_privately("Shard #{name} may link for #{network} now.")
  end

  def delete_shard(ctx, args)
    name = args.first.to_s.downcase
    usage!("SHARD DEL <name>") if name.empty?
    removed = nil
    shared_data.update { |data| removed = (data["shards"] ||= {}).delete(name) }
    raise Gemdrop::Error, "No shard called #{name}." unless removed

    sessions.each { |s| end_session(s, "removed") if s[:name] == name }
    log.info("#{ctx.account} removed shard #{name}")
    ctx.reply_privately("Removed shard #{name}; it is unlinked.")
  end

  def list_shards(ctx)
    shards = allowed
    return ctx.reply_privately("No shards yet. SHARD INFO, then SHARD ADD <name> <fingerprint>.") if shards.empty?

    shards.sort.each do |name, entry|
      links = sessions.select { |s| s[:name] == name }
      state = if links.empty? then "not linked"
              else
                way = links.map { |s| s[:transport] == :tcp ? "TLS from #{s[:address]}" : "IRC" }.join(" and ")
                bot = links.find { |s| s[:nick] }
                "linked over #{way}#{", on IRC as #{bot[:nick]}#{" (#{bot[:server]})" if bot[:server]}" if bot}"
              end
      ctx.reply_privately("#{name} (#{entry['network']}): #{state}; key #{entry['fingerprint'][0, 19]}...")
    end
  end

  # --- sessions (for all networks: the TLS listener serves them all) ---------------------------------

  def sessions = (shared["sessions"] || []).dup

  def add_session(session)
    old = sessions.select { |s| s[:name] == session[:name] && s[:transport] == session[:transport] }
    old.each { |s| end_session(s, "linked again") }
    shared.synchronize { |data| (data["sessions"] ||= []) << session }
  end

  def end_session(session, why)
    removed = false
    shared.synchronize { |data| removed = !(data["sessions"] ||= []).delete(session).nil? }
    session[:socket]&.close rescue nil # rubocop:disable Style/RescueModifier
    log.info("Shard #{session[:name]} unlinked over #{session[:transport] == :tcp ? 'TLS' : 'IRC'} (#{why})") if removed
  end

  def key_path = File.join(data_dir, "hub.key")
  def listen_port = settings["listen"].to_s.rpartition(":").last.to_i

  def hub_key
    @hub_key ||= if File.file?(key_path)
                   OpenSSL::PKey.read(File.read(key_path))
                 else
                   OpenSSL::PKey.generate_key("ED25519").tap do |key|
                     File.open(key_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(key.private_to_pem) }
                   end
                 end
  end

  def hub_fingerprint = Protocol.fingerprint(hub_key)

  # A shard's hello (over IRC or the TLS link): the session, and the
  # signed welcome to send back; nil if it is refused.
  def handshake(payload, transport:, nick: nil, userhost: nil, address: nil, socket: nil)
    message, key = Protocol.verify_signed(payload)
    return refused("not a hello", address || nick) unless message["t"] == "hello" && message["v"] == Protocol::VERSION
    return refused("a hello from another time", address || nick) unless Protocol.fresh?(message)

    fingerprint = Protocol.fingerprint(key)
    name, entry = allowed.find { |_, s| s["fingerprint"] == fingerprint }
    return refused("an unknown key #{fingerprint}", address || nick) unless name
    unless message["network"].to_s.casecmp?(entry["network"]) && (transport == :tcp || entry["network"].casecmp?(network))
      return refused("shard #{name} is for #{entry['network']}", address || nick)
    end

    @hellos.delete_if { |_, at| at < Time.now.to_f - (Protocol::CLOCK_SKEW * 2) }
    return refused("a hello seen before", address || nick) if @hellos.key?(message["nonce"])

    @hellos[message["nonce"]] = Time.now.to_f
    mine, welcome = Protocol.start(hub_key, "welcome", "to" => message["nonce"], "network" => entry["network"])
    session = {
      name: name, network: entry["network"], transport: transport, address: address, socket: socket, lock: Mutex.new,
      session: Protocol.session(mine, message, hub_key, key, shard: false), nick: nick, userhost: userhost,
      server: nil, seen: Time.now.to_f, pinged: Time.now.to_f, digest: nil, pushed: 0
    }
    add_session(session)
    log.info("Shard #{name} linked over #{transport == :tcp ? "TLS from #{address}" : "IRC as #{nick}"}")
    [session, welcome]
  rescue Protocol::Error => e
    refused(e.message, address || nick)
  end

  def refused(why, from)
    log.warn("Refused a shard from #{from}: #{why}")
    nil
  end

  # What a shard says, once it is decrypted.
  def received(session, message)
    session[:seen] = Time.now.to_f
    return unless message["t"] == "status"

    if session[:transport] == :tcp # over IRC we know who it is from the line itself
      session[:nick] = message["nick"].to_s[0, 64] if message["nick"]
      session[:userhost] = message["userhost"].to_s[0, 200] if message["userhost"]
    end
    session[:server] = message["server"].to_s[0, 100] if message["server"]
    sessions.each { |s| s[:digest] = nil if s[:network] == session[:network] } # the bots changed: all get it
  end

  # --- over IRC --------------------------------------------------------------------------------

  def irc_in(event)
    return unless event.channel.nil? && event.text.to_s.start_with?("#{Protocol::IRC_TAG} ")

    complete = @assembler.feed(event.nick.to_s, event.text) or return
    tag, payload = complete
    if tag == "h"
      session, welcome = handshake(payload, transport: :irc, nick: event.nick, userhost: event.userhost)
      Protocol.irc_lines("h", welcome).each { |line| notice(event.nick, line) } if session
      return
    end

    session = sessions.find do |s|
      s[:transport] == :irc && s[:session].id == tag && same_name?(s[:nick], event.nick) && s[:userhost] == event.userhost
    end
    return unless session

    received(session, session[:session].open(payload))
  rescue Protocol::Error => e
    log.debug("Dropped a shard line from #{event.nick}: #{e.message}")
  end

  def send_message(session, message)
    sealed = session[:session].seal(message)
    if session[:transport] == :tcp
      session[:lock].synchronize { session[:socket].write("#{sealed}\n") }
    else
      Protocol.irc_lines(session[:session].id, sealed).each { |line| notice(session[:nick], line) }
    end
    true
  rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
    end_session(session, "write failed")
    false
  rescue Protocol::Error => e
    log.warn("Can't send shard #{session[:name]} a message: #{e.message}")
    false
  end

  # --- the state, every 2 seconds --------------------------------------------------------------------

  # This network's state to its shards when it changed (over the TLS link
  # if the shard has one, else over IRC at most every irc_state_seconds),
  # pings now and then, and op for shards where we have it.
  def tick
    return unless connected? # shards keep what they have meanwhile

    state = snapshot
    digest = Digest::SHA256.hexdigest(JSON.generate(state))
    now = Time.now.to_f
    mine = sessions.select { |s| s[:network] == network }
    mine.each do |session|
      next end_session(session, "silent") if now - session[:seen] > EXPIRE[session[:transport]]
      next if session[:transport] == :irc && mine.any? { |s| s[:name] == session[:name] && s[:transport] == :tcp }

      if session[:digest] != digest &&
         (session[:transport] == :tcp || now - session[:pushed] >= settings["irc_state_seconds"])
        session[:digest] = digest if send_message(session, state)
        session[:pushed] = now
      elsif now - session[:pinged] >= PING[session[:transport]]
        session[:pinged] = now
        send_message(session, { "t" => "ping" })
      end
    end
    op_shards
  end

  def snapshot
    chanserv = plugin("chanserv")
    {
      "t" => "state", "network" => network,
      "hub" => { "nick" => bot_nick, "userhost" => userhost_of(bot_nick) },
      "bots" => shard_bots, "admins" => admins,
      "channels" => wanted_channels.map do |channel|
        registered = channel_registered?(channel)
        key = (registered ? registry.channel_key(channel) : nil) || channel_modes(channel)["k"]
        {
          "name" => channel, "key" => key == "*" ? nil : key,
          "access" => registered ? channel_access(channel).to_h : {},
          "masks" => registered ? registry.masks(channel).map { |mask, level, _by| [mask, level] } : [],
          "mlock" => chanserv&.mode_lock(channel)
        }
      end,
      "sessions" => identified_users.filter_map do |nick, account|
        userhost = userhost_of(nick) and { "nick" => nick, "userhost" => userhost, "account" => account }
      end.sort_by { |s| s["nick"].downcase }
    }
  end

  # The channels this bot should be in (configured and registered, less
  # skip_channels), also while it is out of one or reconnecting, so shards
  # leave a channel only when this bot is really done with it.
  def wanted_channels
    skip = Array(bot_config["skip_channels"])
    (Array(bot_config["channels"]) + registered_channels + channels)
      .uniq { |c| casefold(c) }.reject { |c| skip.any? { |s| same_name?(s, c) } }.sort_by { |c| casefold(c) }
  end

  # The linked shards on this network as they are on IRC. Over IRC, nick
  # and user@host come from their own lines; over the TLS link, from what
  # they say. Bots op one only where both match.
  def shard_bots
    sessions.select { |s| s[:network] == network && s[:nick] && s[:userhost] }
            .group_by { |s| s[:name] }
            .map { |name, list| list.find { |s| s[:transport] == :irc } || list.first }
            .map { |s| { "name" => s[:name], "nick" => s[:nick], "userhost" => s[:userhost], "server" => s[:server] }.compact }
            .sort_by { |b| b["name"] }
  end

  def op_shards
    bots = shard_bots
    return if bots.empty?

    channels.each do |channel|
      next unless op?(channel)

      nicks = bots.filter_map do |bot|
        member = user(channel, bot["nick"])
        bot["nick"] if member && !member.op? && member.userhost.to_s.casecmp?(bot["userhost"])
      end
      nicks.reject! { |nick| (@op_asked[[casefold(channel), casefold(nick)]] || 0) > Time.now.to_f - 30 }
      next if nicks.empty?

      nicks.each { |nick| @op_asked[[casefold(channel), casefold(nick)]] = Time.now.to_f }
      nicks.each_slice(MODES_PER_LINE) { |slice| op(channel, *slice) }
    end
  end

  # --- the TLS link (one listener for every network, in the primary's plugin) --------------------------

  # TLS keeps the link private and fast; who is who is settled by the
  # signed hellos inside it, so a throwaway certificate will do.
  def server_context
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.rand(64)
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=gemdrop-shards")
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + (365 * 86_400)
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.min_version = OpenSSL::SSL::TLS1_3_VERSION
    ctx.key = key
    ctx.cert = cert
    ctx
  end

  def start_listener
    host, _, port = settings["listen"].to_s.rpartition(":")
    @server = TCPServer.new(host.delete("[]").then { |h| h.empty? ? "0.0.0.0" : h }, port.to_i)
    @context = server_context
    @listener = Thread.new { accept_loop }
    log.info("Listening for shards on #{settings['listen']} (key #{hub_fingerprint})")
  rescue SystemCallError => e
    log.error("Can't listen for shards on #{settings['listen']}: #{e.message}")
  end

  def stop_listener
    @server.close
    @listener&.kill
    sessions.each { |s| end_session(s, "the hub is reloading") if s[:transport] == :tcp }
  rescue IOError, SystemCallError
    nil
  end

  def accept_loop
    loop do
      socket = @server.accept
      Thread.new { serve(socket) }
    end
  rescue IOError, SystemCallError
    nil
  end

  def serve(socket)
    address = socket.remote_address.inspect_sockaddr
    tls = OpenSSL::SSL::SSLSocket.new(socket, @context)
    tls.sync_close = true
    Timeout.timeout(HANDSHAKE_SECONDS) { tls.accept }
    hello = Timeout.timeout(HANDSHAKE_SECONDS) { read_line(tls) } or return tls.close
    session, welcome = handshake(hello, transport: :tcp, address: address, socket: tls)
    return tls.close unless session

    session[:lock].synchronize { tls.write("#{welcome}\n") }
    read_loop(session)
  rescue OpenSSL::SSL::SSLError, IOError, SystemCallError, Timeout::Error => e
    log.debug("A shard link from #{address} ended: #{e.class}: #{e.message}")
    socket.close rescue nil # rubocop:disable Style/RescueModifier
  end

  def read_loop(session)
    loop do
      break unless IO.select([session[:socket]], nil, nil, EXPIRE[:tcp])

      line = read_line(session[:socket]) or break
      received(session, session[:session].open(line))
    rescue Protocol::Error => e
      log.warn("Shard #{session[:name]} sent something that isn't ours (#{e.message}); unlinked")
      break
    end
  ensure
    end_session(session, "link closed")
  end

  def read_line(socket)
    line = socket.gets("\n", MAX_LINE) or return nil
    raise IOError, "line too long" unless line.end_with?("\n")

    line.chomp
  end
end
