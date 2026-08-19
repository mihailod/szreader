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
