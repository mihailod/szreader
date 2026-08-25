# Development Notes

[← back to the README](README.md)

Building requires Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen). The app
target is generated from `project.yml`, so edit that rather than the project
file.

```sh
xcodegen generate
./scripts/sim.sh run        # build and run in the simulator
./scripts/device.sh         # build, install and launch on a connected iPad
swift test                  # SZKit's tests
```

`./scripts/sim.sh` also has `seed` (launch with the saved topic pages imported) and
`paste` (copy the Mac clipboard into the simulator). `./scripts/device.sh setup` records the
connected iPad in `.device`, and `no-launch` installs without bringing the app to the front.

The app's version lives in `project.yml` and nowhere else — `Info.plist` refers to
`$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` rather than holding literals.
The build number goes up for *every* App Store upload, including a re-upload of an
identical build.

## Layout

`SZKit` holds everything that is not UI — parsing, the SQLite library, archive
and PDF decoding — and builds on macOS, which is why the tests run without a
simulator. `unrar` and the LZMA SDK are vendored under `Sources/CUnrar` and
`Sources/C7z`. `BuildSupport` holds the caching fetcher the archive build tools share.

## Test fixtures

Saved pages under `Tests/Fixtures/`, one directory per source: `retrospec`, `bombjack`,
`batcave`, `comicbookplus`, `stripovi`, `atarimania`, `vintageapple`. They are public,
static pages carrying no private links, so those tests run on a fresh clone with no
network. Archive.org's are inline in the tests instead — trimmed copies of the real
metadata responses for the items the import was built against.

StripZona is the exception. Its fixtures are saved forum pages in `spike/pages/`, which is
gitignored to protect the mirror links. Uploaders there label issues in many ways; the parser
learns offline from that corpus and tries to handle each. If a topic imports badly, saving its
page into `spike/pages/` and running the tests is the whole diagnosis: the counts say how many
of its links were understood.

## Shipped catalogues

Sixteen JSON files under `Sources/SZKit/Resources/`, each seeded by a switch in Settings.
They are rebuilt by hand, and every tool refuses to write a catalogue that fails its own checks.

```sh
swift run retrospec-build      # retrospec-catalog.json
swift run archive-build        # archive-catalog.json
swift run bombjack-build       # bombjack-*.json (seven)
swift run atarimania-build     # atarimania-catalog.json
swift run vintageapple-build   # vintageapple-magazines.json, vintageapple-books.json
```

They are Swift tools rather than scripts so they use the same code the app runs and the tests
cover. All but `archive-build` cache what they fetch — `.retrospec-cache/`, `.bombjack-cache/`,
`.atarimania-cache/`, `.vintageapple-cache/` — so a second run costs nothing and `--no-network`
rebuilds from the cache alone. Deleting a cache directory is how you ask for fresh copies.
`archive-build` makes a dozen requests to archive.org's metadata API and caches nothing.

`vintageapple-build` takes `--group magazines|books` to write one shelf rather than both.

### Spectrum Computing

`spectrum-build` is the odd one. ZXDB is an *index* of where scans live, not a store of them:
it records a URL template per magazine which, expanded against an issue's own numbers, names
that issue's scan on archive.org. So the tool has modes:

```sh
swift run spectrum-build --probe       # what ZXDB holds; writes nothing
swift run spectrum-build --validate    # do the expanded masks resolve?
swift run spectrum-build --plan        # what a full build would ask for
swift run spectrum-build --build magazines|fanzines|books
```

It works from a 27 MB dump cached under `.zxdb-cache/`, and expands masks with `ZXDBMask`.
Only the identifier half of an expanded mask is trusted: the build asks each archive.org item
what it actually holds, which is where the real filename and the exact byte count come from.

### Adding an issue to the shipped archive.org index

A line in `ArchiveOrgLibrary.series` — its identifier, in the run it belongs to — and another
`swift run archive-build`. Everything else (the scan's name and size, the page count, the cover,
the title's month and year) comes from the item's own metadata. That list stays hand-picked and
small; anything else worth reading is imported from the browser at runtime instead, which needs
no rebuild and ships nothing.

## Adding a source

The pattern, in order:

1. **Parser in `SZKit`**, not beside the build tool — the shipped catalogue has to be produced by
   code the tests cover. Add fixtures under `Tests/Fixtures/<source>/`.
2. **Build tool** under `Sources/<Source>Build/`, using `BuildSupport.Fetcher`, writing a
   `ShippedCatalog` and validating it before writing.
3. **`IssueSite` case** with `display` and `catalogueResource`. A source split into several
   switches gets a `Group` enum in SZKit beside its parser, so a name, a resource filename and a
   switch label cannot drift apart — see `Spectrum.Group` and `VintageApple.Group`.
4. **`SourceCopy` entry** for the switch label, the one-line description and the credit.
   `SourceList` in `SourceToggle.swift` groups multi-switch sources under one heading.
5. **Add the download host to `DirectHost`.** This is the step that has been forgotten twice.
   `DirectHost` is scoped to a named allowlist on purpose, so an unrecognised forum link fails
   loudly rather than downloading an error page — and the consequence is that a catalogue whose
   host is missing produces `noHostFor` on *every issue in it*. Nothing else notices: the
   catalogue decodes, seeds and fills the shelf with rows that cannot be downloaded.
   `ShippedCatalogHostTests` now catches this, which is the only reason it is no longer a
   question of remembering.

Two things worth knowing before choosing a source. Seeding is fast — around 9,000 rows a second,
measured — so a catalogue of a few thousand does not need splitting for speed; BombJack's seven
exist because 18,219 rows took fifteen seconds, which iOS kills an app for during launch. And
split a source by *what the material is* or what it is worth, not by size: the Sinclair shelves
separate magazines from fanzines from books, and Vintage Apple separates magazines that
archive.org already holds from books that it does not.
