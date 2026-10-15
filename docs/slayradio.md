# The slayradio plugin

[contrib/plugins/slayradio.rb](../contrib/plugins/slayradio.rb) follows what
[SLAY Radio](https://www.slayradio.org) plays as C64 remixes: which C64 tune
the remix on air comes from and who wrote it, the remix on Remix.Kwed.Org,
and the station's other remixes of the same tune. It also keeps a log of
everything the station plays, from its own Recently Played page.

Every answer is one line (at most 400 bytes; what doesn't fit is left out):

```
<zphinx> !slay
<Linuks> SLAY Radio now: Wobbler – Warhawk (There4am Remix) (02:57), started 0 min ago · a remix of Rob Hubbard's Warhawk · https://remix.kwed.org/remix/6076 · RKO: Very Good, 2557 downloads · 26 other remixes of it on SLAY Radio: !slay others · SID: https://deepsid.chordian.net/?file=MUSICIANS%2FH%2FHubbard_Rob%2FWarhawk.sid&subtune=1 · played 188 times on SLAY since 2019 · rated 99.14%
<zphinx> !slay others
<Linuks> SLAY Radio has 26 other remixes of Warhawk (Rob Hubbard): Puffy64 – Warhawk 100% #6370 · The St. Albans Rob Hubbard Fan Club – Warhawk Of The Worlds 100% #5547 · Martin Dodd – Warhawk (Synthwave mix feat dr.blitzen) 100% #5341 · o2 – Warhawk 99.59% #903 · …
<zphinx> !remix
<Linuks> RKO: 30 remixes of Warhawk by Rob Hubbard (on SLAY Radio now: Wobbler – Warhawk (There4am Remix)) (https://remix.kwed.org/search/Warhawk) · best: Warhawk (Halcón de la guerra mix) – N-JOY (Rob Hubbard [GB]), Outstanding, 3:43, https://remix.kwed.org/remix/4710 · …
```

There is no `NP`: in #SLAYRadio, `!np` belongs to `[S]`, the station's own
bot. `!remix` without words is the [remix](remix.md) plugin's: Remix.Kwed.Org's
remixes of the tune on air, also those the station doesn't have.

**Where it comes from.** The station's page for each song links its remix on
Remix.Kwed.Org (rating, downloads, the original's composer), its original
SID on DeepSID (HVSC's path, so the tune's name and, failing RKO, its
composer: `MUSICIANS/H/Hubbard_Rob/Warhawk.sid` is Rob Hubbard's Warhawk),
and its "other remixes of the same subtune", with the station's ratings.

The `#numbers` are the station's song numbers, which `SLAY INFO` takes.

**Countries.** With the [artists](artists.md) plugin loaded, names get their
countries (`Wobbler [SE]`), and `SLAY COUNTRIES` counts the plays by the
artists' countries (a play by two artists counts for both).

## Commands

| Command | Answers |
| --- | --- |
| `SLAY` (or `SLAY NOW`) | the remix on air: which C64 tune it remixes and whose, its Remix.Kwed.Org page, rating and downloads, how many other remixes of the tune the station has, the original SID, the station's plays and rating; or that a live show is on |
| `SLAY OTHERS` | the station's other remixes of the tune on air, best rated first, with their numbers |
| `SLAY LAST` | the last few songs played, with their times |
| `SLAY PLAYED <words>` | how often and when songs matching were played, from the log |
| `SLAY TOP [day\|week\|month\|all]` | the most played artists and songs in the log (default: the last week) |
| `SLAY COUNTRIES [day\|week\|month\|all]` | where the artists played come from: plays by country, from the log (default: the last week) |
| `SLAY INFO <words\|#number>` | a song's whole history on SLAY Radio: the tune it remixes, plays since it was added, last played, rating, votes, requests, length, its remix on Remix.Kwed.Org |

`PLAYED`, `TOP` and `COUNTRIES` use the plugin's own log, which starts when
the plugin was installed. `SLAY` and `INFO` show the station's figures, which
go back to when each song was added. `INFO` finds a song by name among the
recent plays and the log, or by the station's number (`SLAY INFO #5243`).

## The log

The Recently Played page lists the last 30 plays, about two hours. The
plugin reads it every `poll_seconds` (default 3 minutes), on the first
network only, and adds each new play to
`plays-<year>.jsonl` in that network's plugin folder
(`data/plugins/<first network>/slayradio/`), one JSON object a line:

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
    prefix: "!"                      # !slay in channels
    announce: ["#SLAYRadio"]         # optional: say each new song there
```

| Setting | Default | |
| --- | --- | --- |
| `poll_seconds` | 180 | how often the Recently Played page is read (60–1800) |
| `announce` | `[]` | channels where each new song is said, once, as it is logged |
| `results` | 3 | songs in an answer (1–5), as many as fit in the line; per channel |
| `per_channel_per_minute` | 6 | answers a minute in one channel; per channel |

Each person can use `SLAY` every 5 seconds.

## Being a good guest

slayradio.org's robots.txt allows bots everywhere but `/cgi-bin/`. The
plugin reads two of its normal pages: Recently Played (a few kilobytes,
every 3 minutes, kept for a minute for `SLAY` and `LAST`) and a song's page
for `SLAY`, `OTHERS` and `INFO` (kept for an hour), with Gemdrop's own user agent. It
uses none of the site's internal programming interfaces.
