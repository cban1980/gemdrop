# The remix plugin

[contrib/plugins/remix.rb](../contrib/plugins/remix.rb) searches
[Remix.Kwed.Org](https://remix.kwed.org) (RKO), the big archive of C64 music
remixes, and answers in one line:

```
<zphinx> !remix jeroen tel
<Linuks> RKO: 357 remixes of "jeroen tel" (https://remix.kwed.org/search/jeroen+tel) · best: The Galway Effect – Jogeir Liljedahl & Tim Forsyth (Jeroen Tel), Outstanding, 3:50, https://remix.kwed.org/remix/7387 · Dan Dare 3 – Tim Forsyth #7234 · Supremacy (Overprime mix) – SIDNIFY #5636
```

The line says what was found (with a link to all of it), then the first
remix in full: its title, arranger, the original's composer in brackets,
RKO's rating, length and page. The next ones (up to `results`) are short,
with their number, which `REMIX ID` takes. A line is at most 400 bytes:
what doesn't fit is left out.

## Commands

| Command | Answers |
| --- | --- |
| `REMIX <words>` | the best-rated remixes whose title, arranger or composer matches, and how many there are |
| `REMIX NEW [words]` | the newest remixes (matching the words, or on the whole site), with their dates |
| `REMIX TOP [week\|month\|alltime]` | RKO's "What's popular?" list (default: this week) |
| `REMIX RANDOM [words]` | one remix at random, matching or any, in detail |
| `REMIX ID <number\|link>` | one remix in detail: date, length, size, downloads, rating, and its original SID on DeepSID |

```
<zphinx> !remix id 7404
<Linuks> Ghosts'n Goblins (tsr remix) – tsr, original by Mark Cooksey · https://remix.kwed.org/remix/7404 · 2026-10-14 · 4:41 · Very Good · 190 downloads · 10.8 MB · SID: https://deepsid.chordian.net/?file=/MUSICIANS/C/Cooksey_Mark/Ghosts_n_Goblins.sid&subtune=2
```

A number on its own is searched for (`REMIX 1942` finds remixes of 1942);
use `REMIX ID` for a remix by its number.

**Finding things.** RKO matches the words as one phrase, punctuation and
all. When that finds nothing, the plugin tries the words without
punctuation (`glyn r. brown` finds Glyn R Brown), and then RKO's results
for the longest word, kept where every word is in the title, arranger or
composer (`ghosts'n goblins`). The latter reads at most three pages, so it
may say "at least".

## Setting up

```
bin/gemdrop-docker plugin install contrib/plugins/remix.rb
```

Commands work by private message (`/msg Linuks REMIX commando`), and in
channels with a prefix in `config.yml`:

```yaml
plugins:
  remix:
    prefix: "!"
    channels: ["#SLAYRadio"]      # optional: only these channels
```

| Setting | Default | |
| --- | --- | --- |
| `results` | 3 | remixes in an answer (1–5), as many as fit in the line; per channel |
| `title_length` | 70 | longer titles are cut with "…"; per channel |
| `per_channel_per_minute` | 6 | answers a minute in one channel; per channel |
| `cache_minutes` | 10 | how long a fetched page is kept |

Each person can use `REMIX` every 5 seconds.

## Being a good guest

RKO's robots.txt allows general bots. The plugin fetches its normal pages,
one or a few per command, with Gemdrop's own user agent
(`Gemdrop/1.0 (+https://github.com/cban1980/gemdrop)`), keeps them for
`cache_minutes`, and fetches nothing on its own.

Other C64 music sites don't allow bots to search them, so the plugin
doesn't: HVSC's site keeps bots out of its API, DeepSID's search is for
its own player, and CSDb's and Remix64's robots.txt keep bots out of
their searches. The SID links go to DeepSID, for listening there.
