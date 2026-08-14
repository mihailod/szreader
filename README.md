# StreamZine

Comics/magazines reader for iPad. For now it only supports
[StripZona](https://www.stripzona.com), a Serbian/ex-YU comics fan site.

You browse the forum inside the app, import a topic page, and its issues become
a searchable shelf — covers, series, hero, publisher and issue numbers, all read
off the page. Downloads and reading happen in the app.

## What it does

- **Imports a saved topic page** and turns its posts into library entries.
  Uploaders on the forum label issues five or six different ways; the parser
  handles each, and 44 real pages are kept as test fixtures so a change to one
  convention cannot quietly break another.
- **Finds cover art** from the page itself, from stripovi.com filenames that
  name their issue, or — where a post shows a grid of six covers above six
  issues — by cropping that sheet into tiles.
- **Downloads** from MediaFire, Mega and Pixeldrain, including split archives
  and sets where one archive holds a run of issues.
- **Reads** CBR, CBZ, RAR, ZIP, 7z and PDF. Portrait turns pages; landscape is
  one continuous scroll with a scrubber down each edge, so it works in either
  hand. It remembers where you stopped.
- **Search and filter** by title, hero, publisher, series or number, with
  read/unread state.

## Signing in

Some posts hide their links until you are logged in. You log in on StripZona's
own form, inside the app's web view — there is no login screen of its own, and
nothing here reads, stores or replays a password. Your typing goes from that
form to the site and nowhere else; no Keychain, no credential store.

The session cookie lives in WebKit's data store inside the app's sandboxed
container, which is why the login survives a relaunch and why removing the app
takes it with it.

## Tested against

44 saved StripZona topics — **2,435 issues, 2,316 with cover art** — are kept as
fixtures, and every one is checked on each build: how many links a page holds,
how many reach an issue, and that a run split over several forum pages reads as
one series.

| | Titles | Issues |
|---|---|---|
| **Bonelli** heroes | Zagor, Veliki Blek, Ken Parker, Mister No, Komandant Mark, Martin Mystere, Kit Teler, Kapetan Miki, Džudas | 1,259 |
| **SF and prose magazines** | Galaksija, Erotski Roman, Sirius, Alef, Roto Biblioteka X-100, Kosmoplov | 667 |
| **FIBRA** | Kolorka, Orka, and both Specijals | 249 |
| **Magnus & Bunker** | Alan Ford, Maxmagnus, Johnny Logan, Diabolik, Kriminal, Satanik | 148 |
| Other | Gigant, Asteriks, Korto Malteze | 112 |

Editions covered include Lunov Magnus Strip, Zlatna Serija, Super Strip
Biblioteka, Stripzona Scanlation, Libellus i Fibra and System Comics;
publishers include Bonelli, Dnevnik, Vjesnik, Politika, Dečje Novine,
Bookglobe, Slobodna Dalmacija and Fibra.

Cover art is complete for most of these. Two known gaps: **Ken Parker** (46% —
one of its four topics posts no artwork at all) and **Galaksija** (82%).

### Anything else

A topic that is written like one of the above should import the same way. One
that is not may import partially — missing links, missing cover art, or issues
skipped entirely — and it will do so quietly rather than reporting an error,
because there is no way to tell an unread convention from a post that simply
has nothing in it.

If a topic imports badly, saving its page into `spike/pages/` and running the
tests is the whole diagnosis: the counts say how many of its links were
understood.

## Building

Requires Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen). The app
target is generated from `project.yml`, so edit that rather than the project
file.

```sh
xcodegen generate
./scripts/sim.sh run        # build and run in the simulator
./scripts/device.sh         # build, install and launch on a connected iPad
swift test                  # SZKit's tests
```

`SZKit` holds everything that is not UI — parsing, the SQLite library, archive
and PDF decoding — and builds on macOS, which is why the tests run without a
simulator. `unrar` and the LZMA SDK are vendored under `Sources/CUnrar` and
`Sources/C7z`.

The test fixtures are saved forum pages in `spike/pages/`, which is gitignored:
the tests skip cleanly without them.

## Licence

[PolyForm Noncommercial 1.0.0](LICENSE). The app is a reader — it hosts nothing
and ships no content.
