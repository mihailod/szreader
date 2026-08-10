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
            ]
        ),
        // Deliberately UIKit-free so the parsers run as fast Mac unit tests
        // against the same fixtures the Python spike was validated on.
        // Swift 6 language mode: data-race safety is enforced rather than
        // suggested. The database race that surfaced as "the library could not
        // be written to" was a non-Sendable Store captured into a background
        // Task — exactly what this rejects at compile time.
        .target(name: "SZKit", dependencies: ["CUnrar"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        // Still v5: the concurrency tests deliberately share one Store across
        // threads to prove the locking works, which mode 6 cannot see is safe.
        .testTarget(name: "SZKitTests", dependencies: ["SZKit"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ],
    cxxLanguageStandard: .cxx14
)
