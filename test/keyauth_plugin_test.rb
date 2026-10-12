require "test_helper"
require "base64"
require "open3"
require "openssl"

# The keyauth plugin (contrib/plugins/keyauth.rb): SSH key logins with a
# signed challenge, and the core hooks it uses (login_provider,
# password_policy, shared_data).
class KeyauthPluginTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @plugins_dir = install_plugins(File.join(@tmpdir, "plugins"), "keyauth")
    accounts = Gemdrop::Accounts.new(@store, TEST_HASHER)
    accounts.register("alice", "password123")
    accounts.register("bob", "password456")
    @key = OpenSSL::PKey.generate_key("ED25519")
    start
  end

  def start(network: "IRCnet")
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML, perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      network: #{network}
      admins: [root]
      require_secure_users: false
      data_file: #{File.join(@tmpdir, 'data', 'gemdrop.json')}
      plugins_dir: #{@plugins_dir}
    YAML
    @conn = FakeConnection.new
    @now = 0
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), connection: @conn, store: @store, hasher: TEST_HASHER,
                                                         clock: -> { @now }, logger: Logger.new(@log = StringIO.new))
    @bot.handle(":server 001 Gemdrop :Welcome")
  end

  def plugin = @bot.send(:plugin_manager).plugin("keyauth")

  # 5 s apart, within the bot's 8 commands per 30 s per host.
  def ask(text, nick: "alice", host: "alice.host")
    @now += 5
    @conn.clear
    @bot.handle(":#{nick}!#{nick}@#{host} PRIVMSG Gemdrop :#{text}")
    @conn.lines.grep(/\ANOTICE #{nick} :/).map { |l| l.split(" :", 2).last }
  end

  def whoami(nick: "alice", host: "alice.host") = ask("WHOAMI", nick: nick, host: host).first

  def ssh_string(text) = [text.bytesize].pack("N") + text.b
  def public_blob(key = @key) = ssh_string("ssh-ed25519") + ssh_string(key.public_to_der[-32..])
  def public_line(key = @key, comment = "laptop") = "ssh-ed25519 #{Base64.strict_encode64(public_blob(key))} #{comment}"

  # What ssh-keygen -Y sign -n <namespace> writes, as one line of base64.
  def sign(text, key: @key, namespace: "gemdrop")
    signed = "SSHSIG#{ssh_string(namespace)}#{ssh_string('')}#{ssh_string('sha512')}" \
             "#{ssh_string(Digest::SHA512.digest(text))}"
    signature = ssh_string("ssh-ed25519") + ssh_string(key.sign(nil, signed))
    Base64.strict_encode64("SSHSIG#{[1].pack('N')}#{ssh_string(public_blob(key))}#{ssh_string(namespace)}" \
                           "#{ssh_string('')}#{ssh_string('sha512')}#{ssh_string(signature)}")
  end

  def challenge(nick: "alice", host: "alice.host", account: nil)
    line = ask(["AUTH", account].compact.join(" "), nick: nick, host: host).first
    line[/\AChallenge: (\S+) /, 1] or flunk("no challenge: #{line.inspect}")
  end

  def enroll(nick: "alice", password: "password123", key: @key)
    ask("IDENTIFY #{password}", nick: nick, host: "#{nick}.host")
    ask("KEY ADD #{public_line(key)}", nick: nick, host: "#{nick}.host")
    ask("LOGOUT", nick: nick, host: "#{nick}.host")
  end

  def test_add_a_key_then_log_in_with_it
    ask("IDENTIFY password123")
    reply = ask("KEY ADD #{public_line}").first
    assert_match(/\AAdded SHA256:\S+ \(laptop\)\. Log in with AUTH/, reply)
    ask("LOGOUT")

    text = challenge
    assert_match(/\Agemdrop-auth:IRCnet:alice:\h{32}:\d+\z/, text)
    assert_equal ["You are now identified as alice."], ask("AUTH #{sign(text)}")
    assert_equal "You are identified as alice.", whoami
    assert_match(/Key login: alice!alice@alice.host as alice with SHA256:/, @log.string)
    assert_match(/alice!alice@alice.host logged in as alice \(by plugin keyauth\)/, @log.string)
    assert_match(/last used \d{4}-/, ask("IDENTIFY password123").then { ask("KEY LIST").first })
  end

  def test_a_signature_works_once_and_only_for_its_challenge
    enroll
    text = challenge
    signature = sign(text)
    assert_equal ["You are now identified as alice."], ask("AUTH #{signature}")
    ask("LOGOUT")
    assert_match(/No challenge for you/, ask("AUTH #{signature}").first, "no replay")
    challenge
    assert_match(/Key login failed/, ask("AUTH #{signature}").first, "an old signature for a new challenge")
    assert_equal "You are not identified.", whoami
  end

  def test_wrong_key_namespace_or_user_fail
    enroll
    other = OpenSSL::PKey.generate_key("ED25519")
    assert_match(/Key login failed/, ask("AUTH #{sign(challenge, key: other)}").first)
    assert_match(/Key login failed/, ask("AUTH #{sign(challenge, namespace: 'git')}").first)
    text = challenge
    assert_match(/No challenge for you/, ask("AUTH #{sign(text)}", host: "elsewhere").first,
                 "the challenge is bound to nick and user@host")
    bob_text = challenge(nick: "bob", host: "bob.host", account: "alice")
    assert_equal ["You are now identified as alice."], ask("AUTH #{sign(bob_text)}", nick: "bob", host: "bob.host"),
                 "anyone holding alice's key may log in as alice, from any nick"
    assert_match(/Key login failed/, ask("AUTH #{sign(challenge(account: 'nobody'))}").first)
    assert_equal "You are not identified.", whoami
  end

  def test_challenges_expire
    enroll
    text = challenge
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 61
    plugin.define_singleton_method(:now) { clock }
    assert_match(/expired/, ask("AUTH #{sign(text)}").first)
  end

  def test_attempts_are_limited_per_host
    10.times { challenge }
    assert_match(/Too many attempts/, ask("AUTH").first)
  end

  def test_key_only_refuses_passwords_after_a_key_login
    enroll
    ask("IDENTIFY password123")
    assert_match(/Log in with AUTH once first/, ask("KEY ONLY on").first)
    ask("LOGOUT")
    ask("AUTH #{sign(challenge)}")
    assert_match(/refused now/, ask("KEY ONLY on").first)
    ask("LOGOUT")

    assert_equal ["alice only takes key logins: AUTH (see HELP AUTH)."], ask("IDENTIFY wrong-password")
    assert_equal ["alice only takes key logins: AUTH (see HELP AUTH)."], ask("IDENTIFY alice password123", nick: "x")
    refute_match(/Failed password/, @log.string, "the password isn't even checked")
    assert_equal ["You are now identified as bob."], ask("IDENTIFY password456", nick: "bob", host: "bob.host"),
                 "other accounts are unaffected"

    ask("AUTH #{sign(challenge)}")
    assert_match(/allowed again/, ask("KEY ONLY off").first)
    ask("LOGOUT")
    assert_equal ["You are now identified as alice."], ask("IDENTIFY password123")
  end

  def test_deleting_the_last_key_ends_key_only
    enroll
    ask("AUTH #{sign(challenge)}")
    ask("KEY ONLY on")
    assert_match(/Removed SHA256:\S+ \(laptop\)\. That was the last key/, ask("KEY DEL laptop").first)
    ask("LOGOUT")
    assert_equal ["You are now identified as alice."], ask("IDENTIFY password123")
  end

  def test_list_and_delete
    second = OpenSSL::PKey.generate_key("ED25519")
    ask("IDENTIFY password123")
    ask("KEY ADD #{public_line}")
    ask("KEY ADD #{public_line(second, 'server')}")
    lines = ask("KEY LIST")
    assert_match(/\A1\. SHA256:\S+ laptop, added \d{4}-\d\d-\d\d, never used\z/, lines[0])
    assert_match(/\A2\. SHA256:\S+ server,/, lines[1])
    assert_equal "Password logins to alice: allowed.", lines[2]
    fp = lines[1][/SHA256:(\S+)/, 1]
    assert_match(/Removed SHA256:#{Regexp.escape(fp)} \(server\)/, ask("KEY DEL #{fp[0, 8]}").first)
    assert_match(/No such key/, ask("KEY DEL 5").first)
    assert_match(/already yours/, ask("KEY ADD #{public_line}").first)
  end

  def test_keys_are_checked_when_added
    ask("IDENTIFY password123")
    assert_match(/Only Ed25519/, ask("KEY ADD ssh-rsa AAAAB3NzaC1yc2E x").first)
    assert_match(/base64 part is broken/, ask("KEY ADD ssh-ed25519 !!!").first)
    assert_match(/isn't an Ed25519 public key/, ask("KEY ADD ssh-ed25519 #{Base64.strict_encode64('junk')}").first)
    ask("KEY ADD #{public_line}")
    ask("LOGOUT")
    ask("IDENTIFY password456", nick: "bob", host: "bob.host")
    assert_match(/belongs to another account/, ask("KEY ADD #{public_line}", nick: "bob", host: "bob.host").first)
    assert_match(/You must IDENTIFY first/, ask("KEY LIST", nick: "carol", host: "c").first)
  end

  def test_admins_manage_others_keys
    enroll
    ask("AUTH #{sign(challenge)}")
    ask("KEY ONLY on")
    ask("LOGOUT")
    assert_match(/Only bot admins/, ask("KEY LIST alice", nick: "bob", host: "bob.host").then do
      ask("IDENTIFY password456", nick: "bob", host: "bob.host")
      ask("KEY LIST alice", nick: "bob", host: "bob.host").first
    end)
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("root", "s3cret-admin")
    ask("IDENTIFY s3cret-admin", nick: "root", host: "root.host")
    assert_match(/\A1\. SHA256:/, ask("KEY LIST alice", nick: "root", host: "root.host").first)
    assert_match(/only turn it off/, ask("KEY ONLY alice on", nick: "root", host: "root.host").first)
    assert_match(/allowed again/, ask("KEY ONLY alice off", nick: "root", host: "root.host").first)
    assert_equal ["You are now identified as alice."], ask("IDENTIFY password123")
  end

  def test_keys_of_a_deleted_account_dont_carry_over
    enroll
    accounts = Gemdrop::Accounts.new(@store, TEST_HASHER)
    accounts.delete("alice")
    sleep 1.1 # a different registered_at
    accounts.register("alice", "newowner123")
    assert_match(/Key login failed/, ask("AUTH #{sign(challenge)}").first)
    assert_equal ["You are now identified as alice."], ask("IDENTIFY newowner123"), "and no key-only either"
    assert_match(/has no keys/, ask("KEY LIST").first)
  end

  def test_keys_are_shared_by_all_networks
    enroll
    start(network: "EFnet")
    assert_equal ["You are now identified as alice."], ask("AUTH #{sign(challenge)}")
    assert File.exist?(File.join(@tmpdir, "data", "plugins-shared", "keyauth.json"))
  end

  def test_a_real_ssh_keygen_signature
    skip "no ssh-keygen" unless system("command -v ssh-keygen >/dev/null 2>&1")
    key_file = File.join(@tmpdir, "id_ed25519")
    system("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "real", "-f", key_file, exception: true)
    ask("IDENTIFY password123")
    assert_match(/\AAdded/, ask("KEY ADD #{File.read("#{key_file}.pub").strip}").first)
    ask("LOGOUT")
    text = challenge
    armored, _err, status = Open3.capture3("ssh-keygen", "-Y", "sign", "-n", "gemdrop", "-f", key_file, stdin_data: text)
    assert status.success?
    assert_equal ["You are now identified as alice."], ask("AUTH #{armored.lines[1..-2].join.delete("\n")}")
  end

  def test_only_login_providers_can_log_in
    File.write(File.join(@plugins_dir, "sneaky.rb"), <<~RUBY, perm: 0o600)
      class Sneaky < Gemdrop::Plugin
        command("SNEAK") { |ctx, _| log_in(ctx.nick, ctx.userhost, "alice") }
      end
    RUBY
    @bot.send(:sync_plugins)
    assert_match(/doesn't declare login_provider/, ask("SNEAK", nick: "mallory", host: "m").first)
    assert_equal "You are not identified.", whoami(nick: "mallory", host: "m")
  end

  def test_help
    assert_match(/AUTH \[account\] \| AUTH <signature>/, @bot.send(:plugin_manager).help_catalog(Gemdrop::Bot::CORE_HELP)
                                                             .command("auth").usage)
  end
end
