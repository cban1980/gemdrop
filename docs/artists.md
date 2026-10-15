# The artists plugin

[contrib/plugins/artists.rb](../contrib/plugins/artists.rb) knows where C64
musicians and remixers come from, by [MusicBrainz](https://musicbrainz.org),
the open music database, and remembers what it found.

```
<zphinx> !country jeroen tel
<Linuks> Jeroen Tel: Netherlands (NL) · MusicBrainz: https://musicbrainz.org/artist/baccaa2d-40f9-49a5-9e9a-0ff27a4617c1
```

The [remix](remix.md) and [slayradio](slayradio.md) plugins use it:
`!remix` and `!slay` show countries as codes after the names
(`Jogeir Liljedahl [NO] & Tim Forsyth [GB] (Jeroen Tel [NL])`), and
`!slay countries` counts the plays by country.

## Commands

| Command | Does |
| --- | --- |
| `COUNTRY <artist>` | the artist's country, and where it comes from |
| `COUNTRY SET <artist> <code>` | (bot admins) sets it by hand, with a two-letter code (`SE`, `NO`, `GB` ...) |
| `COUNTRY UNSET <artist>` | (bot admins) back to MusicBrainz's answer |

## How a country is found

- The name is searched for on MusicBrainz. Only an exact match counts
  (case, spaces and punctuation aside, or one of the artist's aliases).
- **Namesakes:** when several artists share the name, the one MusicBrainz
  describes or tags as C64, SID, demoscene, remix, chiptune, game music,
  8-bit, tracker or Amiga is taken: `Wobbler` is the C64 remixer from Sweden,
  not the Norwegian prog band. If that doesn't settle it, the country stays
  unknown rather than a guess.
- Some artists are on MusicBrainz without a country, and some aren't there
  at all. Those can be set by hand (`COUNTRY SET Makke SE`); what an admin
  sets is never overwritten.
- Answers are kept in `data/plugins-shared/artists.json`, for every
  network. A country found is checked again after 180 days, a name not
  found after 30.

Other plugins never wait for MusicBrainz: they get what is already known
(`plugin("artists").country(name)`), and hand it names to find in the
background (`look_up(names)`), so the next answer has them.

## Being a good guest

MusicBrainz asks for at most one request a second, and a user agent that
says who is asking. The plugin keeps to one request a second for every
network together, and sends Gemdrop's user agent
(`Gemdrop/1.0 (+https://github.com/cban1980/gemdrop)`).

## Setting up

```
bin/gemdrop-docker plugin install contrib/plugins/artists.rb
```

```yaml
plugins:
  artists:
    prefix: "!"
    channels: ["#SLAYRadio"]
```
