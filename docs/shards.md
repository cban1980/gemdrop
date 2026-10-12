# The shards plugin

[contrib/plugins/shards.rb](../contrib/plugins/shards.rb) links
[Gemshard](https://github.com/cban1980/gemshard) bots, called shards, to this bot.
Each shard runs on its own machine, on another server of the same network. Together
they keep the bot's channels as they should be, also while the bot is away or the
network is split:
- **Channels:** shards are in the same channels as the bot, and join and part
  with it.
- **Op and voice:** they op and voice whoever should have it, by login, hostmask
  or bot admin. They never take op or voice from anyone.
- **Mode locks:** they keep the channels' mode locks.
- **The bots:** they keep every bot opped.

This bot is their only source of truth. Shards get the state from it and learn
about each other from it. They talk to nobody else and can't change anything here.

## Setting up

```
bin/gemdrop-docker plugin install contrib/plugins/shards.rb
```

Shards talk to this bot over IRC only, so no port needs to be opened.
Whoever hosts a shard needs Gemshard's repo and Docker: `bin/gemshard-docker
setup <name>` asks for what `SHARD INFO` shows, and prints the `SHARD ADD` line
to send back.

Then, as a bot admin:

| Command | Does |
| --- | --- |
| `SHARD INFO` | what a shard's host needs: the network, this bot's gecos, nick and key fingerprint |
| `SHARD ADD <name> <fingerprint>` | lets the shard with that key link, for this network (the shard prints its fingerprint) |
| `SHARD LIST` | the shards: whether they are linked, their nick and server |
| `SHARD DEL <name>` | removes a shard and unlinks it |

Shards are kept in `data/plugins-shared/shards.json`, per network: the same shard (same name and key) may be added on several networks. This bot's
key is `hub.key` in the plugin's data folder (mode 600).

## Settings

| Setting | Default | |
| --- | --- | --- |
| `max_shards` | 16 | |
| `irc_state_seconds` | 10 | at most one state update per shard this often over IRC (flood limits) |

## What shards get, and what they don't

They get the state, sent again whenever it changes:
- the channels this bot should be in (configured and registered, less
  `skip_channels`), with their keys;
- each channel's access list, hostmasks and mode lock;
- who is logged in, as which account, from which user@host;
- the bot admins;
- this bot's nick, user@host and gecos: shards know this bot by its gecos
  (`realname` in config.yml), since its nick may change;
- the bots: this one and the linked shards.

They never get passwords, password hashes, keys or anything else of the bot's.
Nothing is sent while this bot is disconnected; shards keep what they have.

## How the link works

- **Over IRC only:** NOTICEs between the bots; nothing listens on a port.
- **Handshake:** signed hellos, with Ed25519 keys pinned on both sides and fresh
  X25519 keys each time.
- **Messages:** encrypted with AES-256-GCM using new keys for every session,
  numbered so nothing can be replayed, and compressed.

**Pacing:**
- The state goes out only when it changed, at most every `irc_state_seconds`, in
  lines of under 400 bytes, paced with the bot's flood control.
- A shard's lines are accepted only from the nick and user@host it linked from.

**Opping shards:** this bot ops a shard only where its nick and user@host both
match what the shard is.

The details are in Gemshard's
[docs/protocol.md](https://github.com/cban1980/gemshard/blob/main/docs/protocol.md).
The plugin carries an identical copy of Gemshard's protocol module.
