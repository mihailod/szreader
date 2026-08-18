<table><tr>
<th>
  <img src=https://raw.githubusercontent.com/mihailod/szreader/refs/heads/master/App/Assets.xcassets/AppIcon.appiconset/icon_1024.png width=200>
</th>
<th>
  StreamZine for iOS<br><br>
  Comics & magazines reader that supports StripZona forum<br>
  <br>
  COMING SOON TO APPLE APP STORE!<br>
  (review in progress)<br>
  <br>
  Coming in V1.1: support for RetroSpec and Archive.org<br>
</th>
</tr>
</table>

<img src="screenshot.png" alt="Screenshot" width="350">

## New in 1.1 (work in progress)

* **A second source:** [RetroSpec](https://retrospec.elite.org/users/tomcat/yu/revije.php), Tomaž Kac's
archive of scanned ex-Yugoslav (1972-2001) computer magazines (Svet Kompjutera,
Računari, Moj Mikro, etc.) plus a dozen of computer books.
Unlike StripZona there is nothing to browse or import: the index is built offline from the site's
own pages and read straight into the shelf, where it searches, filters and sorts exactly like
everything else. Issues download individually, on request, from the archive itself.

* **A third source:** **[Archive.org](https://archive.org)**, the Internet Archive, which arrives two ways.
First, a small shipped index for the two ex-Yugoslav Amiga fanzines: A-Profy (July and August 1990)
and Amiga Bilten (September and October 1988). Second, **anything else searchable there**:
Import gains a second entry that opens archive.org's search inside the app; find an item,
and Import brings it onto the shelf.

* **Browser fencing** Both browser views (StripZona, Archive.org) are fenced to their own site.
The address line is read-only and links leading outside those domains are not followed.
(The app embeds a view of two sites; it is not a full web browser, App Store compliance.)

* **Sources can be switched on and off** in Settings, or from the empty shelf on a first run.
Switching one off hides it everywhere — shelf, search and filter menus — and never deletes
anything: what you have read and downloaded is exactly as you left it when you switch it back on.
RetroSpec and Archive.org start switched off, so the app opens on an empty shelf and asks rather
than arriving with hundreds of retro computer magazines a strictly comics lover might not care about.

---

## 1.0 Features

- **Imports a liked StripZona forum page** and turns its posts into library entries.
- **Finds cover art** from the page itself, or by resolving against stripovi.com.
- **Downloads** from mirrors (MediaFire, Mega, Pixeldrain), including split archives
  and sets where one archive holds a run of issues.
- **Reads** CBR, CBZ, RAR, ZIP, 7z and PDF. Portrait turns pages like Kindle; landscape is
  one continuous fit to width (for oversized content) scroll with a scrubber down each edge, so it works in either
  hand. It remembers where you stopped reading.
- **Search, filter, sort** by title, hero, publisher, series or number, with
  read/reading/unread and downloaded states.

> [StripZona](https://www.stripzona.com) is a Serbian/ex-YU comics fan site. You browse its forum
inside the app, import a topic page, and its issues become a searchable shelf — covers, series,
hero, publisher and issue numbers, all read off the page in a convenient Kindle-style reader.
Downloads and reading happen in the app.

---

## StripZona Support Details

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

In the meantime, a topic that is written like one of the above should import the same way.
One that is not may import partially — missing links, missing cover art, or issues
skipped entirely — and it will do so quietly rather than reporting an error,
because there is no way to tell an unread convention from a post that simply
has nothing in it.

Contact me to add support for your favorite hero in the next version.

----

## Development Notes

Building requires Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen). The app
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

Uploaders on the StripZona forum label issues in many ways; the parser learns
offline from corpus and tries to handle each.

The test fixtures are saved forum pages in `spike/pages/`, which is gitignored to protect the mirror links.
RetroSpec's fixtures are committed instead, under `Tests/Fixtures/retrospec/` — they are a public,
static archive carrying no private links, so those tests run on a fresh clone with no network.
Archive.org's are inline in the tests: trimmed copies of the real metadata responses for the items
the import was built against — a comic, a scanned magazine, a pack of thirteen, a game and a
single-image upload — so they need no network either.

If a topic imports badly, saving its page into `spike/pages/` and running the
tests is the whole diagnosis: the counts say how many of its links were
understood.

Both shipped indexes are rebuilt by hand — RetroSpec's when the site changes, Archive.org's when an
item is added to the list in `ArchiveOrgLibrary`:

```sh
swift run retrospec-build   # refetch, rebuild Sources/SZKit/Resources/retrospec-catalog.json
swift run archive-build     # refetch, rebuild Sources/SZKit/Resources/archive-catalog.json
```

They are Swift tools rather than scripts so that they use the same code the app runs and the tests
cover, and both refuse to write a catalogue that fails their own checks. `retrospec-build` caches
everything it fetches under `.retrospec-cache/`, so a rebuild asks the site for each of its ~1300
pages once; `archive-build` makes a dozen requests to archive.org's metadata API and caches nothing.

Adding an issue to the *shipped* archive.org index is a line in `ArchiveOrgLibrary.series` — its
identifier, in the run it belongs to — and another `swift run archive-build`. Everything else (the
scan's name and size, the page count, the cover, the title's month and year) comes from the item's
own metadata. That list stays hand-picked and small; anything else worth reading is imported from
the browser at runtime instead, which needs no rebuild and ships nothing.

---

## Licence

**Content:** the app is a reader — it hosts nothing and ships no content.

**Code:** © Mihailo Despotovic, 2026. [PolyForm Noncommercial 1.0.0](LICENSE).
