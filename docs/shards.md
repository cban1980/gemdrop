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
bin/gemdrop-docker ports add 7700      # for the TLS link (optional: IRC works without it)
bin/gemdrop-docker restart             # applies the port; the bot stays on IRC
```

Then, as a bot admin:

| Command | Does |
| --- | --- |
| `SHARD INFO` | what a shard's config needs: this bot's nick, key fingerprint and address |
| `SHARD ADD <name> <fingerprint>` | lets the shard with that key link, for this network (the shard prints its fingerprint) |
| `SHARD LIST` | the shards: linked over TLS and/or IRC, their nick and server |
| `SHARD DEL <name>` | removes a shard and unlinks it |

Shards are kept in `data/plugins-shared/shards.json`, for all networks. This bot's
key is `hub.key` in the plugin's data folder (mode 600).

## Settings

| Setting | Default | |
| --- | --- | --- |
| `listen` | `0.0.0.0:7700` | where shards connect for the TLS link; `""` for IRC only (config.yml only) |
| `max_shards` | 16 | |
| `irc_state_seconds` | 10 | at most one state update per shard this often over IRC (flood limits) |

## What shards get, and what they don't

They get the state, sent again whenever it changes:
- the channels this bot should be in (configured and registered, less
  `skip_channels`), with their keys;
- each channel's access list, hostmasks and mode lock;
- who is logged in, as which account, from which user@host;
- the bot admins;
- the bots: this one and the linked shards.

They never get passwords, password hashes, keys or anything else of the bot's.
Nothing is sent while this bot is disconnected; shards keep what they have.

## How the link works

- **Two transports:** the TLS link (port 7700) when a shard can reach it, else
  NOTICEs over IRC.
- **Handshake:** signed hellos, with Ed25519 keys pinned on both sides and fresh
  X25519 keys each time.
- **Messages:** encrypted with AES-256-GCM using new keys for every session,
  numbered so nothing can be replayed, and compressed.

**Over IRC:**
- The state goes out only when it changed, at most every `irc_state_seconds`, in
  lines of under 400 bytes, paced with the bot's flood control.
- A shard's lines are accepted only from the nick and user@host it linked from.

**Opping shards:** this bot ops a shard only where its nick and user@host both
match what the shard is.

The details are in Gemshard's
[docs/protocol.md](https://github.com/cban1980/gemshard/blob/main/docs/protocol.md).
The plugin carries an identical copy of Gemshard's protocol module.
