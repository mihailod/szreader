// swift-tools-version:6.0
import PackageDescription

// unrar's compiled set, taken from its own makefile. The other .cpp files in
// Sources/CUnrar/unrar are #included into these and must NOT be compiled
// standalone, which is why the list is explicit rather than a directory scan.
let unrarSources: [String] = [
        "szunrar.cpp",
        "unrar/archive.cpp",
        "unrar/arcread.cpp",
        "unrar/blake2s.cpp",
        "unrar/cmddata.cpp",
        "unrar/consio.cpp",
        "unrar/crc.cpp",
        "unrar/crypt.cpp",
        "unrar/dll.cpp",
        "unrar/encname.cpp",
        "unrar/errhnd.cpp",
        "unrar/extinfo.cpp",
        "unrar/extract.cpp",
        "unrar/filcreat.cpp",
        "unrar/file.cpp",
        "unrar/filefn.cpp",
        "unrar/filestr.cpp",
        "unrar/find.cpp",
        "unrar/getbits.cpp",
        "unrar/global.cpp",
        "unrar/hash.cpp",
        "unrar/headers.cpp",
        "unrar/list.cpp",
        "unrar/match.cpp",
        "unrar/options.cpp",
        "unrar/pathfn.cpp",
        "unrar/qopen.cpp",
        "unrar/rar.cpp",
        "unrar/rarvm.cpp",
        "unrar/rawread.cpp",
        "unrar/rdwrfn.cpp",
        "unrar/resource.cpp",
        "unrar/rijndael.cpp",
        "unrar/rs16.cpp",
        "unrar/scantree.cpp",
        "unrar/secpassword.cpp",
        "unrar/sha1.cpp",
        "unrar/sha256.cpp",
        "unrar/smallfn.cpp",
        "unrar/strfn.cpp",
        "unrar/strlist.cpp",
        "unrar/system.cpp",
        "unrar/threadpool.cpp",
        "unrar/timefn.cpp",
        "unrar/ui.cpp",
        "unrar/unicode.cpp",
        "unrar/unpack.cpp",
        "unrar/volume.cpp",
]

// The LZMA SDK's own 7z decoder set, as named by its Util/7z makefile. Public
// domain (see lzma/LICENSE-lzma-sdk.txt). Decode only — nothing here writes an
// archive.
let sevenZipSources: [String] = [
    "sz7z.c",
        "lzma/7zAlloc.c",
        "lzma/7zArcIn.c",
        "lzma/7zBuf.c",
        "lzma/7zBuf2.c",
        "lzma/7zCrc.c",
        "lzma/7zCrcOpt.c",
        "lzma/7zDec.c",
        "lzma/7zFile.c",
        "lzma/7zStream.c",
        "lzma/Bcj2.c",
        "lzma/Bra.c",
        "lzma/Bra86.c",
        "lzma/BraIA64.c",
        "lzma/CpuArch.c",
        "lzma/Delta.c",
        "lzma/Lzma2Dec.c",
        "lzma/LzmaDec.c",
        "lzma/Ppmd7.c",
        "lzma/Ppmd7Dec.c",
]

let package = Package(
    name: "SZReader",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SZKit", targets: ["SZKit"])
    ],
    targets: [
        // Vendored unrar 7.0.9 behind a small C API (see include/szunrar.h).
        // RARDLL compiles out unrar's own main(); verified: the built library
        // exports the RAR* API and no main symbol.
        .target(
            name: "CUnrar",
            path: "Sources/CUnrar",
            sources: unrarSources,
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("unrar"),
                .define("RARDLL"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("RAR_SMP"),
                // unrar is upstream source kept byte-identical so it can be
                // re-vendored, so its warnings can never be fixed where they
                // are raised. There were 150 of them — five classes, all
                // house style rather than defects — against 32 from this
                // app's own code, which is the number that matters and which
                // they buried. Silenced for this target only, and named one
                // by one rather than `-w`: anything unrar does NOT already do
                // still warns, here and in szunrar.cpp beside it.
                .unsafeFlags([
                    "-Wno-logical-op-parentheses",
                    "-Wno-dangling-else",
                    "-Wno-shorten-64-to-32",
                    "-Wno-switch",
                    "-Wno-nontrivial-memcall",
                ]),
            ]
        ),
        // Deliberately UIKit-free so the parsers run as fast Mac unit tests
        // against the same fixtures the Python spike was validated on.
        // Swift 6 language mode: data-race safety is enforced rather than
        // suggested. The database race that surfaced as "the library could not
        // be written to" was a non-Sendable Store captured into a background
        // Task — exactly what this rejects at compile time.
        // Vendored the same way as unrar, and for the same reason: a comic is
        // whatever container the scanner used, and neither format is available
        // on iOS.
        .target(
            name: "C7z",
            path: "Sources/C7z",
            sources: sevenZipSources,
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("lzma")]
        ),
        // The shipped catalogues are resources rather than files in the app
        // target, so `Bundle.module` finds them from both the app and `swift
        // test` — a seed the tests cannot load is a seed nothing checks.
        .target(name: "SZKit", dependencies: ["CUnrar", "C7z"],
                resources: [.process("Resources")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        // Builds those catalogues. Neither is shipped or linked by the app:
        // they are run by hand, and they exist so the files the app reads are
        // produced by the same types the tests cover rather than by a script
        // beside them.
        .executableTarget(name: "retrospec-build", dependencies: ["SZKit"],
                          path: "Sources/RetroSpecBuild",
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "archive-build", dependencies: ["SZKit"],
                          path: "Sources/ArchiveBuild",
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "bombjack-build", dependencies: ["SZKit"],
                          path: "Sources/BombJackBuild",
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        // Unlike the three above, this one reports rather than builds: ZXDB is
        // an index of where scans live, not a store of them, and `--probe`
        // says how much of it is actually reachable before a catalogue is
        // written against it.
        .executableTarget(name: "spectrum-build", dependencies: ["SZKit"],
                          path: "Sources/SpectrumBuild",
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "atarimania-build", dependencies: ["SZKit"],
                          path: "Sources/AtarimaniaBuild",
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        // Still v5: the concurrency tests deliberately share one Store across
        // threads to prove the locking works, which mode 6 cannot see is safe.
        .testTarget(name: "SZKitTests", dependencies: ["SZKit"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ],
    cxxLanguageStandard: .cxx14
)
