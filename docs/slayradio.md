# The slayradio plugin

[contrib/plugins/slayradio.rb](../contrib/plugins/slayradio.rb) keeps a log
of everything [SLAY Radio](https://www.slayradio.org) plays, read from the
station's own Recently Played page, and answers what is playing, what was
played and how often, and a song's history on the station.

Every answer is one line (at most 400 bytes; what doesn't fit is left out):

```
<zphinx> !np
<Linuks> SLAY Radio now: Electronscape – Sanxion Loader (03:58), started 1 min ago · https://www.slayradio.org/songinfo/5243 · played 203 times since 2019 · rated 96.25%
<zphinx> !slay played wobbler
<Linuks> SLAY Radio played "wobbler" 3 times since 2026-10-15: Wobbler – Dominator (Analogue Re-looped Relaxation) once, last today 19:51 #5046 · Wobbler – Hunter's Moon (The Four By Four Thingie) once, last today 18:35 #5050 · Wobbler – Krakout (the muddy chirp remix) once, last today 19:09 #5065
<zphinx> !slay info dominator
<Linuks> SLAY Radio #5046: Wobbler - Dominator (Analogue Re-looped Relaxation) · 240 plays since 2018-02-01 · https://www.slayradio.org/songinfo/5046 · last 2026-10-15 19:51 · rated 97.92% (48 votes) · 24 requests · 04:32 · RKO: http://remix.kwed.org/remix/5775
```

The `#numbers` are the station's song numbers, which `SLAY INFO` takes.

## Commands

| Command | Answers |
| --- | --- |
| `NP` | what is playing now (or that a live show is on), with the song's plays and rating |
| `SLAY LAST` | the last few songs played, with their times |
| `SLAY PLAYED <words>` | how often and when songs matching were played, from the log |
| `SLAY TOP [day\|week\|month\|all]` | the most played artists and songs in the log (default: the last week) |
| `SLAY INFO <words\|#number>` | a song's whole history on SLAY Radio: plays since it was added, last played, rating, votes, requests, length, its remix on Remix.Kwed.Org |

`PLAYED` and `TOP` use the plugin's own log, which starts when the plugin
was installed. `INFO` and `NP` show the station's figures, which go back
to when each song was added. `INFO` finds a song by name among the recent
plays and the log, or by the station's number (`SLAY INFO #5243`, also in
its `/songinfo/` links).

## The log

The Recently Played page lists the last 30 plays, about two hours. The
plugin reads it every `poll_seconds` (default 3 minutes), on the first
network only, and adds each new play to
`data/plugins-shared/slayradio/plays-<year>.jsonl`, one JSON object a line:

```json
{"at":"2026-10-15T17:56:18Z","local":"2026-10-15 19:56:18","artist":"Electronscape","title":"Sanxion Loader","song":5243,"length":"03:58"}
```

`at` is UTC and `local` the station's own (Swedish) time; `song` is the
station's song number. Every network's instance reads the same files.
During a live show, the page lists the show ("SLAY Radio Live", song 1935)
and not its songs, so the log does too. If the bot is off for more than
two hours, the plays in between aren't logged.

## Setting up

```
bin/gemdrop-docker plugin install contrib/plugins/slayradio.rb
```

```yaml
plugins:
  slayradio:
    prefix: "!"                      # !np and !slay in channels
    announce: ["#SLAYRadio"]         # optional: say each new song there
```

| Setting | Default | |
| --- | --- | --- |
| `poll_seconds` | 180 | how often the Recently Played page is read (60–1800) |
| `announce` | `[]` | channels where each new song is said, once, as it is logged |
| `results` | 3 | songs in an answer (1–5), as many as fit in the line; per channel |
| `per_channel_per_minute` | 6 | answers a minute in one channel; per channel |

Each person can use `NP` and `SLAY` every 5 seconds.

## Being a good guest

slayradio.org's robots.txt allows bots everywhere but `/cgi-bin/`. The
plugin reads two of its normal pages: Recently Played (a few kilobytes,
every 3 minutes, kept for a minute for `NP` and `LAST`) and a song's page
for `NP` and `INFO` (kept for an hour), with Gemdrop's own user agent. It
uses none of the site's internal programming interfaces.
