<table><tr>
<th>
      <img src=https://raw.githubusercontent.com/mihailod/szreader/refs/heads/master/App/Assets.xcassets/AppIcon.appiconset/icon_1024.png width=200>

</th>
<th>
  StreamZine for iOS<br>
  comics & magazines reader<br>
  that supports<br>
  StripZona forum<br>
</th>
</tr>
</table>

## SOON ON APPLE APP STORE!

iPad shown and recommended (larger screen):

<img src="screenshot.png" alt="Screenshot" width="400" />

For now it only supports [StripZona](https://www.stripzona.com), a Serbian/ex-YU comics fan site. You browse its forum inside the app, import a topic page, and its issues become
a searchable shelf — covers, series, hero, publisher and issue numbers, all read off the page in a convenient Kindle-style reader. Downloads and reading happen in the app.

## What it does

- **Imports a saved topic page** and turns its posts into library entries.
  Uploaders on the forum label issues in many ways; the parser learns offline from corpus and tries to
  handle each.
- **Finds cover art** from the page itself, or resolving the name against stripovi.com.
- **Downloads** from mirrors (MediaFire, Mega, Pixeldrain), including split archives
  and sets where one archive holds a run of issues.
- **Reads** CBR, CBZ, RAR, ZIP, 7z and PDF. Portrait turns pages like Kindle; landscape is
  one continuous fit to width (for oversized content) scroll with a scrubber down each edge, so it works in either
  hand. It remembers where you stopped reading.
- **Search, filter, sort** by title, hero, publisher, series or number, with
  read/redaging/unread and downloaded states.

## StripZona Signing in

All posts hide their links until you are logged in and liked them. You log in on StripZona's
own form, inside the app's sandboxed web view (the reader doesn't know, store or replay your credentials).

## Tested against

| Category | Heros / Series |
|---|---|
| **Bonelli** | Zagor, Veliki Blek, Ken Parker, Mister No, Komandant Mark, Martin Mystere, Kit Teler, Kapetan Miki, Džudas |
| **Magnus & Bunker** | Alan Ford, Maxmagnus, Johnny Logan, Družina od vješala, Diabolik, Kriminal, Satanik |
| **FIBRA** | Kolorka, Orka, and both Specijals |
| **SF magazines** | Galaksija, Sirius, Alef, Roto Biblioteka X-100, Kosmoplov |
| **Other** | Gigant, Asteriks, Korto Malteze |

Editions covered include Lunov Magnus Strip, Zlatna Serija, Super Strip
Biblioteka, Stripzona Scanlation, Libellus i Fibra and System Comics;
publishers include Bonelli, Dnevnik, Vjesnik, Politika, Dečje Novine,
Bookglobe, Slobodna Dalmacija and Fibra.

Cover art is complete for most of these but there are some inevitable gaps / misses.

### Will it work for my favorite hero / series?

I will keep adding to the offline training corpus but I cannot claim 100% coverage.

In the meantime, a topic that is written like one of the above should import the same way. One
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

The test fixtures are saved forum pages in `spike/pages/`, which is gitignored to protect the mirror links.

## Licence

Content: the app is just a reader — it hosts nothing and ships no content.

Code: © Mihailo Despotovic, 2026. [PolyForm Noncommercial 1.0.0](LICENSE).
