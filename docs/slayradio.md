# The slayradio plugin

[contrib/plugins/slayradio.rb](../contrib/plugins/slayradio.rb) is about C64
remixes and what [SLAY Radio](https://www.slayradio.org) plays, in one
plugin:

- **What is on, as a remix:** which C64 tune the remix on air comes from and
  who wrote it, the remix on [Remix.Kwed.Org](https://remix.kwed.org) (RKO),
  and the station's other remixes of the same tune.
- **Remixes on RKO**, the big archive of C64 remixes: searching it, its
  newest and most popular, one at random or in detail.
- **A log** of everything the station plays, from its own Recently Played
  page: what was played, how often, the most played.
- **Where musicians come from**, by [MusicBrainz](https://musicbrainz.org).

Every answer is one line (at most 400 bytes; what doesn't fit is left out):

```
<zphinx> !slay
<Linuks> SLAY Radio now: Wobbler [SE] – Warhawk (There4am Remix) (02:57), started 0 min ago · a remix of Rob Hubbard [GB]'s Warhawk · https://remix.kwed.org/remix/6076 · RKO: Very Good, 2557 downloads · 26 other remixes of it on SLAY Radio: !slay others · SID: https://deepsid.chordian.net/?file=MUSICIANS%2FH%2FHubbard_Rob%2FWarhawk.sid&subtune=1 · played 188 times on SLAY since 2019 · rated 99.14%
<zphinx> !slay others
<Linuks> SLAY Radio has 26 other remixes of Warhawk (Rob Hubbard): Puffy64 – Warhawk 100% #6370 · The St. Albans Rob Hubbard Fan Club – Warhawk Of The Worlds 100% #5547 · Martin Dodd – Warhawk (Synthwave mix feat dr.blitzen) 100% #5341 · o2 – Warhawk 99.59% #903 · …
<zphinx> !slay remix
<Linuks> RKO: 30 remixes of Warhawk by Rob Hubbard (on SLAY Radio now: Wobbler – Warhawk (There4am Remix)) (https://remix.kwed.org/search/Warhawk) · best: Warhawk (Halcón de la guerra mix) – N-JOY (Rob Hubbard [GB]), Outstanding, 3:43, https://remix.kwed.org/remix/4710 · …
<zphinx> !slay remix jeroen tel
<Linuks> RKO: 357 remixes of "jeroen tel" (https://remix.kwed.org/search/jeroen+tel) · best: The Galway Effect – Jogeir Liljedahl [NO] & Tim Forsyth [GB] (Jeroen Tel [NL]), Outstanding, 3:50, https://remix.kwed.org/remix/7387 · Dan Dare 3 – Tim Forsyth #7234 · Supremacy (Overprime mix) – SIDNIFY #5636
```

It is all one command, `SLAY` (`!slay` in channels): `SLAY REMIX ...` for
Remix.Kwed.Org and `SLAY COUNTRY ...` for musicians. There is no `NP`: in
#SLAYRadio, `!np` belongs to `[S]`, the station's own bot.

## Commands

### What is on

| Command | Answers |
| --- | --- |
| `SLAY` (or `SLAY NOW`) | the remix on air: which C64 tune it remixes and whose, its RKO page, rating and downloads, how many other remixes of the tune the station has, the original SID, the station's plays and rating; or that a live show is on |
| `SLAY OTHERS` | the station's other remixes of the tune on air, best rated first, with their numbers |
| `SLAY REMIX` | RKO's best-rated remixes of the tune on air, also those the station doesn't have |

### Remixes on Remix.Kwed.Org

| Command | Answers |
| --- | --- |
| `SLAY REMIX <words>` | the best-rated remixes whose title, arranger or composer matches, and how many there are |
| `SLAY REMIX NEW [words]` | the newest remixes (matching, or on the whole site), with their dates |
| `SLAY REMIX TOP [week\|month\|alltime]` | RKO's "What's popular?" list (default: this week) |
| `SLAY REMIX RANDOM [words]` | one remix at random, matching or any, in detail |
| `SLAY REMIX ID <number\|link>` | one remix in detail: date, length, rating, downloads, size, and its original SID on DeepSID |

### What the station played

| Command | Answers |
| --- | --- |
| `SLAY LAST` | the last few songs played, with their times |
| `SLAY PLAYED <words>` | how often and when songs matching were played, from the log |
| `SLAY TOP [day\|week\|month\|all]` | the most played artists and songs in the log (default: the last week) |
| `SLAY COUNTRIES [day\|week\|month\|all]` | where the artists played come from: plays by country (a play by two artists counts for both) |
| `SLAY INFO <words\|#number>` | a song's whole history on SLAY Radio: the tune it remixes, plays since it was added, last played, rating, votes, requests, length, its remix on RKO |

### Where musicians come from

| Command | Answers |
| --- | --- |
| `SLAY COUNTRY <artist>` | the artist's country, and where it comes from |
| `SLAY COUNTRY SET <artist> <code>` | (bot admins) sets it by hand, with a two-letter code (`SE`, `NO`, `GB` ...) |
| `SLAY COUNTRY UNSET <artist>` | (bot admins) back to MusicBrainz's answer |

The `#numbers` after the station's songs are its song numbers, which
`SLAY INFO` takes; after RKO's remixes, RKO's numbers, which `SLAY REMIX
ID` takes. A number on its own is searched for (`SLAY REMIX 1942` finds
remixes of 1942).

## Where it comes from

**The tune behind what is on.** The station's page for each song links its
remix on RKO (rating, downloads, the original's composer), its original SID
on DeepSID (HVSC's path, so the tune's name and, failing RKO, its composer:
`MUSICIANS/H/Hubbard_Rob/Warhawk.sid` is Rob Hubbard's Warhawk), and its
"other remixes of the same subtune", with the station's ratings.

**Searching RKO.** RKO matches the words as one phrase, punctuation and all.
When that finds nothing, the plugin tries the words without punctuation
(`glyn r. brown` finds Glyn R Brown), and then RKO's results for the longest
word, kept where every word is in the title, arranger or composer
(`ghosts'n goblins`). The latter reads at most three pages, so it may say
"at least".

**Countries.** Names are looked up on MusicBrainz in the background (each
new play's artist as it is logged, and the names in answers), so answers
never wait and show codes once known (`Jeroen Tel [NL]`).

- Only an exact match counts (case, spaces and punctuation aside, or one of
  the artist's aliases).
- When several artists share a name, the one MusicBrainz describes or tags
  as C64, SID, demoscene, remix, chiptune, game music, 8-bit, tracker or
  Amiga is taken: `Wobbler` is the C64 remixer from Sweden, not the
  Norwegian prog band. If that doesn't settle it, the country stays unknown
  rather than a guess. Names like "Anonymous" aren't looked up.
- Artists MusicBrainz doesn't know, or knows without a country, can be set
  by hand (`SLAY COUNTRY SET Makke SE`); what an admin sets is never overwritten.
- Answers are kept in the plugin's shared data
  (`data/plugins-shared/slayradio.json`), for every network. A country found
  is checked again after 180 days, a name not found after 30.

**The log.** The Recently Played page lists the last 30 plays, about two
hours. The plugin reads it every `poll_seconds` (default 3 minutes), on the
first network only, and adds each new play to `plays-<year>.jsonl` in that
network's plugin folder (`data/plugins/<first network>/slayradio/`), one
JSON object a line:

```json
{"at":"2026-10-15T17:56:18Z","local":"2026-10-15 19:56:18","artist":"Electronscape","title":"Sanxion Loader","song":5243,"length":"03:58"}
```

`at` is UTC and `local` the station's own (Swedish) time; `song` is the
station's song number. Every network's instance reads the same files.
During a live show, the page lists the show ("SLAY Radio Live", song 1935)
and not its songs, so the log does too. If the bot is off for more than two
hours, the plays in between aren't logged. `PLAYED`, `TOP` and `COUNTRIES`
use the log, which starts when the plugin was installed; `SLAY` and `INFO`
show the station's own figures, which go back to when each song was added.

## Setting up

```
bin/gemdrop-docker plugin install contrib/plugins/slayradio.rb
```

```yaml
plugins:
  slayradio:
    prefix: "!"                 # !slay in channels
    channels: ["#SLAYRadio"]    # optional: only there
    private: false              # optional: not by /msg
    announce: ["#SLAYRadio"]    # optional: say each new song there
```

| Setting | Default | |
| --- | --- | --- |
| `poll_seconds` | 180 | how often the Recently Played page is read (60–1800) |
| `announce` | `[]` | channels where each new song is said, once, as it is logged |
| `results` | 3 | songs or remixes in an answer (1–5), as many as fit in the line; per channel |
| `title_length` | 70 | longer remix titles are cut with "…"; per channel |
| `per_channel_per_minute` | 6 | answers a minute in one channel, all commands together; per channel |
| `cache_minutes` | 10 | how long a page of RKO is kept |

Each person can use `SLAY` every 5 seconds.

## Being a good guest

- **slayradio.org:** its robots.txt allows bots everywhere but `/cgi-bin/`.
  The plugin reads two of its normal pages: Recently Played (a few
  kilobytes, every 3 minutes, kept for a minute) and a song's page (kept
  for an hour). It uses none of the site's internal programming interfaces.
- **Remix.Kwed.Org:** its robots.txt allows general bots. The plugin reads
  its normal pages, one or a few per command, kept for `cache_minutes`.
- **MusicBrainz:** it asks for at most one request a second; the plugin
  keeps to that for every network together.
- All with Gemdrop's own user agent
  (`Gemdrop/1.0 (+https://github.com/cban1980/gemdrop)`), and nothing
  fetched on its own except the Recently Played page and the lookups of
  names it has seen.

Other C64 music sites don't allow bots to search them, so the plugin
doesn't: HVSC's site keeps bots out of its API, DeepSID's search is for its
own player, and CSDb's and Remix64's robots.txt keep bots out of their
searches. The SID links go to DeepSID, for listening there.
