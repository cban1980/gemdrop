# Key logins: log in to a bot account with an SSH key (Ed25519) instead of
# a password, by signing a one-time challenge. Only the public key is kept
# here; nothing that crosses IRC can be used again. Full documentation:
# docs/keyauth.md.
#
#   /msg Linuks KEY ADD ssh-ed25519 AAAA... [comment]   add a public key (logged in)
#   /msg Linuks KEY LIST | KEY DEL <n|fingerprint|comment>
#   /msg Linuks KEY ONLY on|off                          refuse password logins to your account
#   /msg Linuks AUTH [account]                           a challenge to sign
#   /msg Linuks AUTH <signature>                         the signature: you are logged in
#
# Sign a challenge with: echo -n '<challenge>' | ssh-keygen -Y sign -n gemdrop -f <key>
# (the WeeChat script, contrib/weechat/gemdrop.rb, does all of it with a key
# of its own). Keys are shared by all networks, like accounts.
#
# Install:  bin/gemdrop-docker plugin install contrib/plugins/keyauth.rb
require "base64"
require "digest"
require "openssl"
require "securerandom"

class Keyauth < Gemdrop::Plugin
  description "Log in with an SSH key (Ed25519) instead of a password: KEY ADD, then AUTH"
  help_group "Account"
  login_provider

  setting "max_keys", default: 10, type: :integer, min: 1, max: 50, desc: "keys per account"
  setting "challenge_seconds", default: 60, type: :integer, min: 10, max: 600,
                               desc: "how long a challenge can be answered"
  setting "attempts", default: 10, type: :integer, min: 1, max: 100,
                      desc: "challenges and failed signatures per host in 15 minutes"

  NAMESPACE = "gemdrop".freeze # the -n of ssh-keygen -Y sign
  KEY_TYPE = "ssh-ed25519".freeze
  # An Ed25519 public key as DER (SubjectPublicKeyInfo) is this and the 32 key bytes.
  ED25519_SPKI = ["302a300506032b6570032100"].pack("H*").freeze
  MAX_COMMENT = 40

  # A key-only account refuses IDENTIFY with a password (see KEY ONLY).
  password_policy do |account|
    record = live_record(account)
    "#{account} only takes key logins: AUTH (see HELP AUTH)." if record && record["only"] && record["keys"].any?
  end

  def setup
    @challenges = {} # casefolded nick => { account:, userhost:, text:, until: }
    @lock = Mutex.new
  end

  command "AUTH", usage: "AUTH [account] | AUTH <signature>", help: "log in with your SSH key", where: :private,
                  access: "anyone",
                  details: "AUTH (or AUTH <account>) gives you a challenge. Sign it with your key " \
                           "(ssh-keygen -Y sign -n gemdrop) and send AUTH <signature> within a minute.\n" \
                           "Add a key first with KEY ADD while logged in with your password." do |ctx, args|
    if args.size == 1 && args[0].length > 100
      finish(ctx, args[0])
    elsif args.size <= 1
      challenge(ctx, args[0] || ctx.nick)
    else
      usage!("AUTH [account] | AUTH <signature>")
    end
  end

  command "KEY", usage: "KEY ADD <ssh-ed25519 key> [comment] | LIST | DEL <which> | ONLY on|off",
                 help: "your SSH keys for AUTH", identified: true, where: :private,
                 details: "KEY ADD ssh-ed25519 AAAA... [comment] adds a public key (the line from a .pub file).\n" \
                          "KEY LIST shows your keys; KEY DEL <number|fingerprint|comment> removes one.\n" \
                          "KEY ONLY on refuses password logins to your account (after one AUTH with a key); " \
                          "KEY ONLY off allows them again.\n" \
                          "Bot admins: KEY LIST <account>, KEY DEL <account> <which>, KEY ONLY <account> off." do |ctx, args|
    sub = args.shift.to_s.upcase
    case sub
    when "ADD" then add_key(ctx, args)
    when "LIST" then list_keys(ctx, target(ctx, args, 0))
    when "DEL" then delete_key(ctx, target(ctx, args, 1), args.join(" "))
    when "ONLY" then key_only(ctx, target(ctx, args, 1), args.first.to_s.downcase)
    else usage!("KEY ADD <ssh-ed25519 key> [comment] | LIST | DEL <which> | ONLY on|off")
    end
  end

  help_topic "keys", summary: "logging in with an SSH key" do
    "Instead of a password you can log in with an SSH key (Ed25519): only your public key is kept here, " \
    "and what crosses IRC can't be used again.\n" \
    "1. Logged in with your password: /msg #{bot_nick} KEY ADD ssh-ed25519 AAAA... [comment]\n" \
    "2. /msg #{bot_nick} AUTH gives you a challenge; sign it: " \
    "echo -n '<challenge>' | ssh-keygen -Y sign -n #{NAMESPACE} -f <your key>\n" \
    "3. /msg #{bot_nick} AUTH <the signature, without the BEGIN/END lines, on one line>\n" \
    "The WeeChat script does all of this with a key of its own: /gd key add.\n" \
    "KEY ONLY on then refuses password logins to your account."
  end

  private

  # --- AUTH ----------------------------------------------------------------------------------

  def challenge(ctx, name)
    host_limit!(ctx)
    account = account_name(name)
    nonce = SecureRandom.hex(16)
    # The account is in it as asked, so the answer doesn't tell whether it exists.
    text = "gemdrop-auth:#{network}:#{account || name}:#{nonce}:#{Time.now.to_i}"
    @lock.synchronize do
      @challenges.reject! { |_, c| c[:until] < now }
      @challenges[casefold(ctx.nick)] = { account: account, userhost: ctx.userhost, text: text,
                                          until: now + settings["challenge_seconds"] }
    end
    ctx.reply_privately("Challenge: #{text} (sign it with ssh-keygen -Y sign -n #{NAMESPACE} and send " \
                        "AUTH <signature> within #{settings['challenge_seconds']}s)")
  end

  def finish(ctx, signature)
    pending = @lock.synchronize { @challenges.delete(casefold(ctx.nick)) }
    if pending.nil? || pending[:userhost] != ctx.userhost || pending[:until] < now
      raise Gemdrop::Error, "No challenge for you (or it expired): send AUTH first."
    end

    account = pending[:account]
    fingerprint = account && verify(account, pending[:text], signature)
    unless fingerprint
      host_limit!(ctx)
      log.warn("Key login to #{account || 'an unknown account'} failed from #{ctx.nick}!#{ctx.userhost}")
      raise Gemdrop::Error, "Key login failed: that isn't a signature of the challenge by one of the account's keys."
    end

    account = log_in(ctx.nick, ctx.userhost, account) or raise Gemdrop::Error, "Key login failed."
    touch(account, fingerprint)
    log.info("Key login: #{ctx.nick}!#{ctx.userhost} as #{account} with #{fingerprint}")
    ctx.reply_privately("You are now identified as #{account}.")
  end

  def host_limit!(ctx)
    host = ctx.userhost.to_s.split("@", 2).last.to_s.downcase
    return if rate_limit("auth:#{host}", limit: settings["attempts"], per: 900)

    raise Gemdrop::Error, "Too many attempts. Try again in a few minutes."
  end

  # The fingerprint of the account's key that signed text, or nil.
  def verify(account, text, signature)
    sig = parse_sshsig(signature) or return nil
    return nil unless sig[:namespace] == NAMESPACE && %w[sha256 sha512].include?(sig[:hash])

    record = live_record(account) or return nil
    key = record["keys"].find { |k| Base64.strict_decode64(k["key"]) == sig[:public_key] } or return nil
    digest = sig[:hash] == "sha512" ? Digest::SHA512.digest(text) : Digest::SHA256.digest(text)
    signed = "SSHSIG#{ssh_string(NAMESPACE)}#{ssh_string(sig[:reserved])}#{ssh_string(sig[:hash])}#{ssh_string(digest)}"
    ed25519_key(sig[:public_key]).verify(nil, sig[:raw_signature], signed) ? key["fp"] : nil
  rescue OpenSSL::PKey::PKeyError, ArgumentError
    nil
  end

  # An SSHSIG signature (ssh-keygen -Y sign), armored or as one line of
  # base64: { public_key:, namespace:, reserved:, hash:, raw_signature: }.
  def parse_sshsig(text)
    blob = Base64.strict_decode64(text.gsub(/-----[^-]*-----/, "").delete(" \t\r\n"))
    reader = SshReader.new(blob)
    return nil unless reader.bytes(6) == "SSHSIG" && reader.uint32 == 1

    public_key = reader.string
    namespace = reader.string
    reserved = reader.string
    hash = reader.string
    signature = SshReader.new(reader.string)
    return nil unless signature.string == KEY_TYPE

    raw = signature.string
    raw.bytesize == 64 ? { public_key: public_key, namespace: namespace, reserved: reserved, hash: hash, raw_signature: raw } : nil
  rescue ArgumentError
    nil
  end

  # Reads SSH wire format: uint32 lengths before strings.
  class SshReader
    def initialize(data)
      @data = data.b
      @at = 0
    end

    def bytes(count)
      raise ArgumentError, "truncated" if @at + count > @data.bytesize

      @data.byteslice(@at, count).tap { @at += count }
    end

    def uint32 = bytes(4).unpack1("N")
    def string = bytes(uint32)
  end

  def ssh_string(text) = [text.bytesize].pack("N") + text.b

  # An Ed25519 public key from its SSH blob (type + 32 bytes).
  def ed25519_key(blob)
    reader = SshReader.new(blob)
    raise ArgumentError, "not an Ed25519 key" unless reader.string == KEY_TYPE

    raw = reader.string
    raise ArgumentError, "not an Ed25519 key" unless raw.bytesize == 32

    OpenSSL::PKey.read(ED25519_SPKI + raw)
  end

  def fingerprint(blob) = "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(blob)).delete('=')}"

  # --- KEY -----------------------------------------------------------------------------------

  # The account a KEY command is about: another one's for admins, when
  # args has more than `rest` words (KEY LIST bob, KEY DEL bob 1).
  def target(ctx, args, rest)
    return ctx.account if args.size <= rest

    raise Gemdrop::Error, "Only bot admins can manage other accounts' keys." unless ctx.admin?

    name = args.shift
    account_name(name) or raise Gemdrop::Error, "No account named #{name}."
  end

  def add_key(ctx, args)
    usage!("KEY ADD ssh-ed25519 <base64> [comment]") if args.size < 2
    type, encoded, *comment = args
    raise Gemdrop::Error, "Only Ed25519 keys (ssh-ed25519) are supported." unless type == KEY_TYPE

    blob = begin
      Base64.strict_decode64(encoded)
    rescue ArgumentError
      raise Gemdrop::Error, "That isn't a public key (the base64 part is broken)."
    end
    begin
      ed25519_key(blob)
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      raise Gemdrop::Error, "That isn't an Ed25519 public key."
    end

    account = ctx.account
    fp = fingerprint(blob)
    comment = comment.join(" ")[0, MAX_COMMENT]
    owner = owner_of(blob)
    raise Gemdrop::Error, "That key is already yours (#{fp})." if owner && same_name?(owner, account)
    raise Gemdrop::Error, "That key belongs to another account." if owner

    update_record(account) do |record|
      raise Gemdrop::Error, "You have #{settings['max_keys']} keys already; KEY DEL one first." if
        record["keys"].size >= settings["max_keys"]

      record["keys"] << { "key" => encoded, "fp" => fp, "comment" => comment, "added" => today, "used" => nil }
    end
    log.info("#{account} added key #{fp} #{comment}".strip)
    ctx.reply_privately("Added #{fp}#{" (#{comment})" unless comment.empty?}. Log in with AUTH from now on.")
  end

  def list_keys(ctx, account)
    record = live_record(account)
    keys = record ? record["keys"] : []
    return ctx.reply_privately("#{account} has no keys. KEY ADD ssh-ed25519 AAAA... adds one.") if keys.empty?

    keys.each_with_index do |key, i|
      ctx.reply_privately("#{i + 1}. #{key['fp']}#{" #{key['comment']}" unless key['comment'].to_s.empty?}, " \
                          "added #{key['added']}, #{key['used'] ? "last used #{key['used']}" : 'never used'}")
    end
    ctx.reply_privately("Password logins to #{account}: #{record['only'] ? 'refused (KEY ONLY on)' : 'allowed'}.")
  end

  def delete_key(ctx, account, which)
    usage!("KEY DEL <number|fingerprint|comment>") if which.empty?

    removed = nil
    turned_off = false
    update_record(account) do |record|
      keys = record["keys"]
      index = if which.match?(/\A\d+\z/) then which.to_i - 1
              else
                fp = which.delete_prefix("SHA256:")
                keys.index { |k| k["fp"].delete_prefix("SHA256:").start_with?(fp) && fp.length >= 6 } ||
                  keys.index { |k| k["comment"].to_s.casecmp?(which) }
              end
      raise Gemdrop::Error, "No such key; KEY LIST shows them." unless index && index >= 0 && keys[index]

      removed = keys.delete_at(index)
      if keys.empty? && record["only"]
        record["only"] = false
        turned_off = true
      end
    end
    log.info("#{ctx.account} removed key #{removed['fp']} of #{account}")
    ctx.reply_privately("Removed #{removed['fp']}#{" (#{removed['comment']})" unless removed['comment'].to_s.empty?}." \
                        "#{' That was the last key: password logins are allowed again.' if turned_off}")
  end

  def key_only(ctx, account, value)
    usage!("KEY ONLY on|off") unless %w[on off].include?(value)
    on = value == "on"
    raise Gemdrop::Error, "Bot admins can only turn it off for others." if on && !same_name?(account, ctx.account)

    update_record(account) do |record|
      if on && record["keys"].none? { |k| k["used"] }
        raise Gemdrop::Error, "Log in with AUTH once first, so we know your key works."
      end

      record["only"] = on
    end
    log.info("#{ctx.account} turned key-only #{value} for #{account}")
    ctx.reply_privately(on ? "Password logins to #{account} are refused now; log in with AUTH." :
                             "Password logins to #{account} are allowed again.")
  end

  # --- storage -----------------------------------------------------------------------------------

  # The account's keys, if they are still its own: keys stored for an
  # account that was later deleted (and maybe registered again by someone
  # else) are ignored, and dropped at the next change.
  def live_record(account)
    record = (shared_data["accounts"] || {})[casefold(account)] or return nil
    registered = account_registered_at(account)
    return nil unless registered && record["registered_at"] == registered

    record["keys"] ||= []
    record
  end

  def update_record(account)
    registered = account_registered_at(account) or raise Gemdrop::Error, "No account named #{account}."
    shared_data.update do |data|
      accounts = (data["accounts"] ||= {})
      record = accounts[casefold(account)]
      record = nil unless record && record["registered_at"] == registered
      record ||= { "account" => account, "registered_at" => registered, "keys" => [], "only" => false }
      yield record
      accounts[casefold(account)] = record
    end
  end

  # The account that has this key, or nil.
  def owner_of(blob)
    encoded = Base64.strict_encode64(blob)
    (shared_data["accounts"] || {}).each_value do |record|
      next unless record["keys"]&.any? { |k| k["key"] == encoded }

      return record["account"] if live_record(record["account"])
    end
    nil
  end

  def touch(account, fp)
    update_record(account) do |record|
      key = record["keys"].find { |k| k["fp"] == fp }
      key["used"] = today if key
    end
  end

  def today = Time.now.utc.strftime("%Y-%m-%d")
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
