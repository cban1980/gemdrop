# The keyauth plugin

[contrib/plugins/keyauth.rb](../contrib/plugins/keyauth.rb) lets people
log in to their bot account with an SSH key (Ed25519) instead of a
password. The bot keeps only the public key. A login is a signature of a
one-time challenge, so nothing that crosses IRC can be used again; a
password, by contrast, passes readable through every IRC server on the
way.

```
bin/gemdrop-docker plugin install contrib/plugins/keyauth.rb
```

The easy way to use it is the WeeChat script: `/gd key add` once, and it
logs in with a key pair made for Gemdrop only (see
[weechat.md](weechat.md#key-logins)). By hand, with any Ed25519 key, it
works as below.

## Commands

| Command | Who | Does |
| --- | --- | --- |
| `KEY ADD ssh-ed25519 AAAA... [comment]` | logged in | adds a public key (the line from a `.pub` file) |
| `KEY LIST` | logged in | your keys: fingerprint, comment, added, last used; and whether passwords are refused |
| `KEY DEL <number\|fingerprint\|comment>` | logged in | removes a key (a fingerprint can be shortened to 6+ characters) |
| `KEY ONLY on\|off` | logged in | refuses (or allows again) password logins to your account |
| `AUTH [account]` | anyone | a challenge to sign (for your nick's account by default) |
| `AUTH <signature>` | anyone | the signed challenge; you are logged in |

Bot admins can also use `KEY LIST <account>`, `KEY DEL <account> <which>`
and `KEY ONLY <account> off`, to help someone who lost their key.

## Logging in by hand

```
/msg Linuks AUTH
-Linuks- Challenge: gemdrop-auth:IRCnet:zphinx:6f1c...:1760170000 (sign it with ssh-keygen -Y sign -n gemdrop and send AUTH <signature> within 60s)

$ printf %s 'gemdrop-auth:IRCnet:zphinx:6f1c...:1760170000' | ssh-keygen -Y sign -n gemdrop -f ~/.ssh/gemdrop

/msg Linuks AUTH <the base64 between the BEGIN and END lines, joined into one line>
-Linuks- You are now identified as zphinx.
```

## How it works

1. `AUTH` gives a challenge with the network, the account, a random nonce
   and the time. It is kept for your nick and user@host, for
   `challenge_seconds` (60).
2. The signature is in the format of `ssh-keygen -Y sign` (SSHSIG), with
   the namespace `gemdrop`, so a signature made for git or anything else
   doesn't count.
3. The bot checks that the signature is of that exact challenge, by one of
   the account's keys, from the same nick and user@host, in time. Each
   challenge works once.
4. The login is the same as after `IDENTIFY`. The bot's log names the key
   (`Key login: ... with SHA256:...`).

## Safety

- **Only public keys are stored,** in `data/plugins-shared/keyauth.json`.
  They are shared by all networks, like accounts, so a key added on IRCnet
  works on EFnet.
- **Key-only accounts.** `KEY ONLY on` makes `IDENTIFY` with a password
  refuse the account before the password is checked, so a leaked or
  guessed password is worthless. It can only be turned on after you have
  logged in with a key once, so you know it works. Removing the last key
  turns it off.
- **Attempts are limited:** `attempts` (10) challenges and failed
  signatures per host in 15 minutes.
- **No account enumeration:** a challenge is given for any name, whether
  or not the account exists or has keys.
- **Deleted accounts:** keys are tied to the account's registration. If an
  account is deleted and the name registered again, the old keys don't
  work for it.
- **One account per key:** a key can't be added to a second account.
- **Locked out?** A bot admin can turn key-only off with `KEY ONLY
  <account> off`. If the admin is the one locked out, unloading the plugin
  (removing its file and reloading) brings password logins back.

## Settings

| Setting | Default | |
| --- | --- | --- |
| `max_keys` | 10 | keys per account |
| `challenge_seconds` | 60 | how long a challenge can be answered |
| `attempts` | 10 | challenges and failed signatures per host in 15 minutes |
