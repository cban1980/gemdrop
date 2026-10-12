# WeeChat script

[contrib/weechat/gemdrop.rb](../contrib/weechat/gemdrop.rb) lets you work
with a Gemdrop bot from [WeeChat](https://weechat.org) (4.x, with the Ruby
plugin). It gives you:

- one full-window view with tabs for the status, settings, keys,
  channels, the bot's plugins and settings, and the log. You work it with
  the arrow keys, Enter, letters and the mouse, and type bot commands in
  it;
- logins with a key pair made for Gemdrop only (with the bot's keyauth
  plugin), or with a password kept in WeeChat's secure data;
- safeguards so that password only goes to the real bot;
- logging in by itself: when you connect, when it sees the bot, when it
  loads, and when the bot asks;
- automations, a status bar item, and table views of settings and
  plugins.

## Installing

```
cp contrib/weechat/gemdrop.rb ~/.local/share/weechat/ruby/
ln -s ../gemdrop.rb ~/.local/share/weechat/ruby/autoload/   # load it when WeeChat starts
```

Then, in WeeChat:

```
/script load gemdrop.rb
/set plugins.var.ruby.gemdrop.bots "IRCnet=Linuks,EFnet=Linuks"
/gd secret set IRCnet <your password>
/gd secret set EFnet <your password>
/gd identify                 (in a buffer of each network: logs in, and pins the bot's host)
/gd setup                    (puts the gemdrop item in the status bar)
```

Server names are WeeChat's (`/server list`). `bots` takes `*=Nick` for
every server.

## The gemdrop window

`/gd` (or `/gemdrop`) opens it: one full-window view, drawn by the script
like WeeChat's `/fset`.
- **Keys and the mouse only.** Everything works with the keys and the
  mouse: you never type a command line.
- **Forms for commands.** Channels, nicks and choices are picked from
  lists. Text (a kick reason, a topic, a password) is typed into the input
  line, which then shows the field's name as its prompt; passwords are
  hidden as you type.
- **Nothing else opens.** What the bot says shows at the bottom of every
  tab, and all of it in the Log tab. One window covers every network.

**Your access decides what you see.** The script asks the bot (its
`CATALOG` command, in the help plugin) what you may do, and offers only
that:
- Bot admins get every command and the Bot tab.
- A channel op gets the op commands, for the channels where they are op.
- Someone who isn't logged in gets what anyone may use (logging in,
  help).

It asks again whenever you log in or out.

The top line shows each network's bot and your login, then the tabs:

| Tab | Shows | Keys |
| --- | --- | --- |
| Status | per network: the bot (online, host, trusted), your login and access, how it logs in, key and password, the automatic logins | ⏎ or `i` log in, `l` log out, `w` who am I, `n` the network the other tabs show |
| Commands | the commands you may use, grouped, and where (for channel commands) | ⏎ opens one as a form; `h` its help |
| Channels | your channels: is the bot there, your level, autoup, autosummary | ⏎ the commands you may use there (the form gets the channel filled in); `u` / `s` autoup / autosummary, `U` op me now, `S` sum up now |
| Keys | your Gemdrop key, the networks that log in with it, your keys on the bot | ⏎ makes a key; `a` gives it to the bot; `d` removes one from the bot; `o` key-only (both asked twice) |
| Bot | (bot admins) the bot's plugins and each one's settings | ⏎ opens a plugin; on a setting, ⏎ toggles true/false or edits the value; `x` back to config.yml (asked twice); `R` reloads the plugin |
| Settings | every script setting, with its description (`*`: changed); per network the kept password and the bot's pinned host | ⏎ toggles, cycles or edits; `d` default; `x` deletes a password or unpins a host (asked twice) |
| Log | everything said, with its time; kept across restarts (`gemdrop/history.log` in WeeChat's data folder, passwords masked) | PgUp/PgDn scroll, End the latest |

**In a form:**
- **Filling it in:** ↑ ↓ choose a field and ⏎ fills it: a list to pick
  from, or the input line for text. `x` clears a field.
- **Sending:** **▶ Send** shows exactly what will be sent, and sends it
  once the needed fields are filled.
- **Several forms:** commands with several forms (`KEY ADD … | LIST |
  DEL …`) first ask which one.
- **Typing a value:** ⏎ takes it. Moving away (↑ ↓ ←, Tab, Alt-number,
  a click) or an empty ⏎ cancels and clears the input line.
- **Leaving:** ← or `q` goes back.

Everywhere:
- **Moving:** ↑ ↓ (Home, End, PgUp, PgDn) move, and Tab, Shift-Tab, → or
  Alt-1..7 switch tabs.
- **Other keys:** `r` refreshes, `?` lists the keys, `q` goes back or
  closes (`/gd` opens it again; nothing is lost).
- **Mouse** (with `/mouse enable`): a click selects and a second click
  runs; clicking a tab opens it, and the wheel moves. Every left click in
  the window is its own, so a click that moves a little doesn't switch
  buffers.

When the bot answers while the window is in the background, it shows in
the hotlist, and as a highlight for alerts. `/gd log` opens the window on
its Log tab.

## Commands

Each goes to the bot on the current buffer's network; add `@server` for
another one (`/gd whoami @EFnet`). Channel commands use the current
channel unless you name one.

| Command | Does |
| --- | --- |
| `/gd` | the gemdrop window (see above); `/gd log` opens it on the log |
| `/gd status` | the status as text in the log: bot online, its host and whether it is trusted, your login, kept passwords, automations |
| `/gd identify [key\|password]`, `logout`, `whoami` | log in (with your key or the kept password), log out, who you are |
| `/gd key add [comment]` | make your Gemdrop key pair if needed, and give the bot the public key (log in first) |
| `/gd key show`, `list`, `del <which>`, `only on\|off`, `use [server]` | your key, the bot's KEY commands, and using the key on another network |
| `/gd register [password]` | register your nick (and keep the password) |
| `/gd password <new>` | change your password; the kept one is updated when the bot confirms |
| `/gd secret set [server] <pw>`, `del`, `list` | the kept passwords (in `/secure`, never shown) |
| `/gd trust [reset \| user@host]` | the bot's pinned host |
| `/gd send <command>` | anything to the bot (also `raw`) |
| `/gd summary [#chan] [hours]` | what was said while you were away (AISUMMARY) |
| `/gd catchup` | a summary of every channel you share with the bot, one every 20 s |
| `/gd ai <question>`, `/gd chat <text>` | ask the AI privately / in the current channel |
| `/gd forget [#chan]`, `aistatus`, `agent [#chan] on\|off` | the ai plugin's commands |
| `/gd up`, `down`, `kick`, `kb`, `ban`, `unban`, `topic`, `access`, `mlock`, `chankey` | channel commands |
| `/gd plugins`, `settings <plugin>`, `set`, `unset`, `reload` | plugin admin |
| `/gd logsearch`, `links`, `title`, `help`, `list`, `more` | the rest |
| `/gd setup` | the gemdrop item in the status bar |

`/help gemdrop` lists them in WeeChat. Tab completes subcommands,
channels, nicks, plugin names, and the settings and commands the bot has
shown you.

## Passwords

- **Kept in WeeChat's secure data** as `gemdrop_<server>`
  (`/secure list`). Set a passphrase (`/secure passphrase ...`) so they
  are encrypted on disk.
- **Never shown** in the input bar or in the history: for `/gd secret`,
  `/gd register` and `/gd password`, for bot commands typed in the gemdrop
  buffer, and for `/msg <bot> IDENTIFY|REGISTER|PASSWORD|CHANKEY ...`.
  Lines WeeChat prints for what you sent the bot are masked too.
- **Sent only to the trusted bot.** Before IDENTIFY, the script asks the
  server for the bot's `user@host` (USERHOST, answered quietly). It sends
  the password only if that host matches `hostmasks`. The first `/gd
  identify` pins the host it sees. Automatic logins never pin; they wait
  until a host is pinned. If someone else takes the bot's nick, they get
  nothing, and you get an alert.
- **Answers from another host** are marked "not from the trusted host!"
  and ignored.

## Key logins

With the bot's `keyauth` plugin ([docs/keyauth.md](keyauth.md)), you can
log in with a key instead of a password.

1. Log in with your password once (`/gd identify`).
2. Run `/gd key add`.

That gives you:

- **A key pair for Gemdrop only.** Your SSH keys are never used or sent.
  The pair is Ed25519, in WeeChat's data folder as `gemdrop/key.pem`
  (mode 600). It is encrypted with a random passphrase kept in `/secure`
  (`gemdrop_key`).
- **Key logins from then on.** The bot sends a one-time challenge, and
  the script signs it in the format `ssh-keygen -Y sign` uses. A signature
  is useless after that one login. The script signs only challenges for
  your account, from the bot's trusted host, that it asked for.
- **A fallback.** If the key fails (say the bot lost it), the script logs
  in with the kept password and tells you. `/gd key only on` makes the bot
  refuse password logins to your account altogether. The script then
  switches to the key by itself.
- **Every network.** Keys are shared by all the bot's networks, like
  accounts. On another network, `/gd key use` (or `/gd identify key`) once
  makes the script use the key there too.

`login` (`auto`, `key`, `password`) sets how it logs in. `auto` uses the
key where it has worked (`key_logins`, kept up to date), or where no
password is kept.

## Logging in by itself

With your key or a kept password, the script logs you in on every network
by itself. `autoidentify` turns it all on or off; the rest say when:

| Setting | Default | Logs in |
| --- | --- | --- |
| `autoidentify` | `on` | at all (the switch for the ones below) |
| `identify_on_connect` | `on` | after you connect or reconnect to a network, `identify_delay` (5) seconds later |
| `identify_on_bot` | `on` | when it sees the bot: it joins, comes back or gets its nick back, you join a channel it is in, or a check (`check_interval`) finds it online while you are logged out |
| `identify_on_load` | `on` | when the script loads (WeeChat starting), where you aren't logged in |
| `identify_on_request` | `on` | when the bot says you must log in; with `retry`, your command is sent again (never LOGOUT or other account commands) |

It asks the bot first (WHOAMI) where you might already be logged in, so it
doesn't log in twice. It uses your key on networks where the key works,
else the kept password (`login`), and only ever to the bot's trusted host.
All of these are on the window's Settings tab.

## Automations

| Option | Default | Does |
| --- | --- | --- |
| `autoup` | | `server/#chan,...`: UP when you join (or log in while in) those channels |
| `autosummary` | | `server/#chan,...`: AISUMMARY when you rejoin them, spread out |
| `autorun` | | `server=CMD;CMD,...`: bot commands after every login |
| `watchdog` | `on` | highlights you when the bot quits, parts, is kicked or changes nick, and when it is back |
| `check_interval` | `300` | seconds between checks that the bot is online (`0`: only on events) |

Other options: `bots`, `hostmasks`, `accounts` (your account per server;
default your nick), `login`, `key_logins`, `capture`, `echo`. They are all under
`plugins.var.ruby.gemdrop.*` (the window's Settings tab, or `/fset gemdrop`).

The bot ignores a host that sends more than 8 commands in 30 seconds. The
script sends at most 6 per 31 seconds per network and holds the rest
(it tells you for how long). It counts on WeeChat sending a server's
messages about 2 seconds apart, and keeps count across a script reload,
so automations never get you ignored.

## The status bar item

`gemdrop` shows the bot and your login on the current buffer's network,
for example `gd:Linuks online, ✓ zphinx`. Add it with `/gd setup`, or to
any bar: `/set weechat.bar.status.items "...,gemdrop"`.

## Tests

`test/weechat_script_test.rb` runs the script against a stand-in for
WeeChat's API (part of `rake test`), the window included.
