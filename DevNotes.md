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

## The source that is a folder

Local Files is a source in every way the shelf cares about — a row, a cover, a place in
the filters — and unlike any other in where the file comes from. There is no catalogue, no
mirror and nothing to download: the app's `Documents` directory *is* the source, and the
library is a view of it.

`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` in `project.yml` are what put
that folder in front of the reader — the Finder's Files list over a cable, "On My iPad" in
the Files app — and `CFBundleDocumentTypes` is what lets AirDrop, the share sheet and Open
With hand a file over.

Four of the seven formats have no type of their own on iOS. That is checked rather than
assumed: `MobileCoreTypes.bundle` inside the iOS runtime declares `pdf`, `zip` and `7z`, and
neither `rar` nor any of the comic-book spellings. An extension nothing declares gets a
throwaway `dyn.…` identifier that no app can be matched against, so the missing four are
declared here or they cannot be opened at all.

The two declaration keys are not interchangeable. `cbz`/`cbr`/`cb7` are **exported** — nobody
owns them the way a vendor owns its own format, and these are this app's spellings of them,
named after the bundle id because that is the one prefix another app cannot collide with.
They conform to `public.data`, not `public.archive`: a `.cbr` is as often a zip as a rar, and
the sniff happens when the file is opened. `rar` is **imported**, because RARLAB owns
`com.rarlab.rar-archive` and this is a declaration of somebody else's type, written so the app
defers to a real archiver's if one is ever installed beside it. It was referenced by the
document types before it was declared anywhere, which bound nothing — a plain `.rar` did not
open, and nothing said so. Both document-type entries also carry `CFBundleTypeRole: Viewer`;
an entry without a role is one Launch Services may skip, and the app views issues rather than
editing them.

Each comic-book format gets a document-type entry of its own, and the icons are the only
reason for the split: `CFBundleTypeIconFiles` belongs to the entry, so three formats sharing
one entry can only share one icon. `scripts/document-icons.py` draws them from the app icon's
own sampled colours — the starburst on blue, with the format where the "SZ" is, and the open
book dropped because it is the first thing to turn to mush at 64 points. The PNGs are
committed because the build needs them; the script is there so they can be redrawn rather
than edited by hand. They are named twice, as `CFBundleTypeIconFiles` here and
`UTTypeIconFiles` on the declarations, because which key iOS actually reads is undocumented
and the forum thread asking ends without an answer. The `Alternate` entry deliberately has no
icon: putting StreamZine's artwork on every zip on the device would be claiming in pictures
what the rank gives up in words.

### Drawing the cover in the Files app

iOS has no thumbnailer for comic archives, so a `.cbz` in Files gets a flat document icon —
unless some installed app supplies one, which any app may. That is worth understanding before
changing any of this: the picture a reader sees of *their own comics* otherwise belongs to
whichever other reader they happen to have installed, and disappears when they delete it.
Measured, not assumed: a freshly made `.zip` of images draws the generic archive icon while
the same file named `.cbz` drew a page, which is what proves the preview is type-driven and
comes from an app.

`SZReaderThumbnail` is our own, a `QLThumbnailProvider` over the three types the app owns.
Not offered for `pdf`, `zip`, `rar` or `7z` — iOS already draws PDFs, and thumbnailing every
zip on the device is the overreach `Alternate` gives up.

The thing to understand before touching it is **why it does not use `ComicDocument`**.

`ComicDocument` is built so that page *two* is cheap: RAR and 7z unpack themselves whole on
open, because a reader is about to ask for the rest. A thumbnail wants one page, once, from a
file it will never open again — and it runs in an extension with a fraction of an app's
memory and a few seconds to live, asked afresh for every file scrolled past. Unpacking a
300 MB `.cbr` there is not a slow right answer; it is the wrong one.

So `FirstPage` is the other path, and the solid-archive argument that shapes `ComicDocument`
is what makes it possible rather than what blocks it: entry N costs everything ahead of it,
which is exactly why entry *zero* is the one entry a solid archive gives up cheaply. Zip
needed nothing — `ZipReader` already mmaps and inflates one entry. RAR and 7z each needed one
new function in our own C shim (`szunrar_extract_first_image`, `sz7z_extract_first_image`),
not a patch to vendored upstream. Both skip non-image entries by extension, because a `.nfo`
or a `ComicInfo.xml` ahead of the scans is common and deciding by content would mean
extracting the `.nfo` to discover it is one. `FirstPageTests` covers all three containers with
a solid RAR among them, and goes red in two places if that extension filter is removed.

Two things not to break: the scratch directory is deleted on every exit, or a thumbnail cache
of full-size scans grows where nobody looks; and each request gets its own scratch, because a
folder of comics means many of these at once and a shared one would have them deleting each
other's page mid-decode.

Two traps this cost real time to find, both of which look identical from the outside — a blank
tile of the right shape, nothing in the log, no crash:

* **`QLThumbnailReply` has two initialisers that differ only in the arity of their block.**
  `drawing:` hands over a Core Graphics context; `currentContextDrawing:` sets up a UIKit one
  and passes nothing. A trailing closure taking one argument silently selects the first, so
  `UIImage.draw(in:)` inside it paints into no current context at all — successfully, and on
  to a blank bitmap. The fix is to draw through the context directly, which also disposes of
  the flip question: the block is Core Graphics' own coordinate system, so a CGImage drawn
  into it comes out upright. The label is written out at the call site for that reason.
* **Quick Look caches per item, and a failure caches too.** Re-testing the same filename after
  a fix keeps showing the old blank result through rebuilds *and* reboots, which reads exactly
  like the fix not working. Copy to a new name to force a real request. That is what finally
  separated "the extension is broken" from "the extension was broken an hour ago".

The extension logs to subsystem `com.mihailod.szreader.thumbnail`, and that stays. A process
launched on demand and killed straight after cannot be attached to in any convenient way, and
both traps above were invisible until it could say what it was doing:

    xcrun simctl spawn booted log show --last 5m --info \
        --predicate 'subsystem == "com.mihailod.szreader.thumbnail"'

Verified on the simulator, which is the better oracle here precisely because it has no other
comic reader installed — any preview it draws is unambiguously ours. All three containers,
`.cb7` included: `asked … max=84x84 scale=2.0` then `drew … page=112x168 reply=56x84`, which
is the page's own aspect filling the requested box. The inset look in the Files grid is that
app's document-tile framing, not the reply under-filling.

One project-level consequence. The version moved from the app target up to project `settings`
once the extension existed: iOS refuses to install a bundle whose extension disagrees with it
about `CFBundleVersion`, and the App Store rejects the upload. Two targets reading one number
is the only arrangement that ships.

`LSHandlerRank` is split across two entries, and the split is the whole of what decides
whether an AirDropped issue opens here or is parked in Files for the reader to hand over
themselves. `Owner` for the three comic-book extensions — nobody owns those the way a vendor
owns its own format, and on a device with this app installed they are this app's. `Alternate`
for `pdf`, `zip`, `rar` and `7z`, which belong to Books, to Files and to whatever archiver is
installed; becoming the device's default handler for every zip is not a comics reader's
business. Two things here not to go looking for a fix to: macOS AirDrop sends to a *device*
and has no way to name an app on the other end, so which app it lands in is the receiving
iPad's decision alone; and LaunchServices caches these registrations, so a rank change can
take a reboot to show up.

### The four ways in

A file reaches the folder over a cable, from AirDrop or the share sheet, from Open With in
Files, or dragged onto the shelf from Files in the next pane over. Only the first needs no
code: the rest arrive at `AppModel.adoptLocalFile` (via `onOpenURL`) or `adoptDropped`, and
both funnel into `take`, which copies the file in and lets the ordinary scan put it on the
shelf. Copied rather than read where it lies — a file opened in place belongs to whoever
handed it over, and iCloud can evict it or the other app delete it out from under a row that
has no way to notice.

Two traps in that path, both of which look like nothing is wrong:

* **`Documents/Inbox` is not `Documents`.** iOS drops a hand-over into an Inbox folder that
  nothing ever empties, so a file taken in from there has to be *moved*, not copied. Deciding
  which is `LocalFiles.isInInbox`, and it resolves symlinks on both sides before comparing:
  `FileManager` names the container `/var/mobile/…` while the URL handed over names the same
  file `/private/var/mobile/…`, `/var` being a symlink to `/private/var`. The `hasPrefix` this
  started as was false for every file it was asked about — everything appeared to work, and a
  second copy of every AirDropped issue accumulated out of sight.
  `testInboxIsRecognisedThroughASymlink` is the guard, and it goes red without the fix.
* **A dropped file is a promise, not a file.** `loadInPlaceFileRepresentation` hands over a URL
  that stops resolving the moment its completion handler returns, so `take` is `nonisolated`
  and synchronous and runs *there*. Hopping to the main actor first and copying afterwards
  copies nothing.

### Import ▸ From Device

The fourth way in, and the one that exists because of a limitation nothing in this app can
declare away: **iOS routes an AirDropped document to the Files app's Downloads folder**, not to
whichever app claims the type. `Owner` rank does not change it and no Info.plist key asks for
it — the receiving device decides. Which left a reader holding a comic on their own iPad with
no route to the shelf except the share sheet, if they thought to look there. From Device is
that route: a `fileImporter` onto anywhere in Files, Downloads included.

It copies and never moves, which is the whole difference from the Inbox case in `take` — those
files are the reader's, sitting where they put them, and Downloads is somewhere they may go
back to. One scan for the batch, because picking eleven issues is one thing happening.

Two consequences worth knowing:

* **The Import button is always a menu now.** It used to have three shapes — a plain button
  for one source, another for none, a menu otherwise — on the reasoning that one source is not
  a choice. From Device never depends on a source being switched on, so there are always at
  least two ways in and the special cases went away. The "no importable sources" explanation
  moved into the menu as its own entry rather than being what the button did.
* **`fileImporter` is a presentation modifier.** It sits on its own `Color.clear` background
  like the alerts do, for the reason this file has had to learn more than once: SwiftUI honours
  one presentation per view, and put beside the settings sheet it is not a bug you see — it is
  a menu item that silently does nothing.

`LocalFiles.scan` lists the folder, flat, and `Store.reconcileLocalFiles` brings the rows into
line with it. Three things about that are worth knowing before changing any of it:

* **The filename is the identity** — it is the row's `code`. Not the path: the container's
  absolute path changes on reinstall, and every row would be a stranger after one. The path is
  rewritten from every scan, which is what heals it.
* **A file still being copied is not a row yet.** The folder is watched
  (`LocalFilesWatcher`, a `DispatchSource` on the directory), and a large issue's directory
  entry appears at the *start* of its copy — so the first thing a scan sees of a 300 MB file is
  a few megabytes. `LocalFiles.settled` holds one back until its mtime has aged or its size
  stops moving, and `reconcileLocalFiles(_:present:)` takes the names on disk separately from
  the files being written, so a mid-copy replacement does not delete the row it is replacing.
* **Removals are as real as arrivals.** A file dragged to the Trash takes its row, its
  unpacked pages and its captured cover with it. The cover matters more than its few kilobytes:
  SQLite hands the next row the id of a deleted one, so a stale `covers/<id>.jpg` becomes the
  artwork of an issue that no longer exists, sitting on top of one that does.

### Whose file is it

`LibraryPaths.owns` is the rule that keeps the app off the reader's own files, and it exists
because three pieces of code that had always been right became dangerous the moment a recorded
path could point outside the comics root:

* `discardArchives` deletes an archive once its pages are out — against a local file that is
  the reader's file, deleted out of the Finder, along with any sibling sharing a stem.
* `AppModel.removeFromDisk` deleted a file *and the folder it sits in*. For a download that
  folder is `comics/<id>`; for a local file it is `Documents`.
* Every bulk delete reaches files through the `download` table. Remove All, Remove Visible,
  Delete Visible and Delete Library now all pass over `site = 'local'` (`Store.notLocal`), and
  the counts in their warnings were corrected to match. `deleteLocalIssues` is the one path
  that removes them, and the app asks about it by name and by size after Delete Library.

Anything new that deletes, moves or unpacks a recorded path has to ask `owns` first.
`LocalFilesTests` covers the reconciler and the settle rule, and `testOpeningALocalFileNeverDeletesIt`
is the guard on the first of those three — it goes red without it.

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
