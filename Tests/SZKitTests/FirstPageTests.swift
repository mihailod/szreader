import XCTest
@testable import SZKit

/// Page one, without paying for the rest of the comic.
///
/// The reader's path unpacks a RAR or a 7z whole, on purpose, because it is
/// about to ask for page two. A Quick Look thumbnail never asks for page two,
/// and the extension it runs in has neither the memory nor the seconds to
/// unpack 300 MB for a 64-point picture. What is tested here is that the
/// narrow path really is narrow: the right page comes out, and nothing is left
/// behind.
///
/// Each fixture holds two entries — `00-info.nfo` and `01-page.jpg`, in that
/// order — so an implementation that simply took the archive's first entry
/// would decode the text file and fail. The image is 60x90, portrait, which is
/// what tells a decoded page apart from anything else that might come back.
final class FirstPageTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("firstpage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func write(_ base64: String, as name: String) throws -> URL {
        let data = try XCTUnwrap(Data(base64Encoded: base64
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")))
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private var work: URL {
        scratch.appendingPathComponent("work", isDirectory: true)
    }

    // MARK: - The page comes out

    func testFirstPageOfEveryContainer() throws {
        for (name, base64) in [("test.cbz", cbzFixtureBase64),
                               ("test.cbr", cbrFixtureBase64),
                               ("test.cb7", cb7FixtureBase64)] {
            let url = try write(base64, as: name)
            let image = try XCTUnwrap(FirstPage.render(of: url, maxPixelSize: 32,
                                                       scratch: work),
                                      "\(name) yielded no page")
            // 60x90 reduced to a long edge of 32. Portrait, and decoded at the
            // size asked for rather than full size — the `.nfo` sitting ahead
            // of it in every one of these archives decodes as nothing at all.
            XCTAssertEqual(image.height, 32, "\(name) ignored maxPixelSize")
            XCTAssertLessThan(image.width, image.height, "\(name) is not the page")
        }
    }

    // MARK: - Nothing left behind

    /// The guarantee the whole file exists for. A thumbnail that leaves its
    /// page on disk is a cache of full-size scans growing in a directory
    /// nobody looks at — which is the cost this path was written to avoid.
    func testTheScratchDirectoryIsNotLeftBehind() throws {
        for (name, base64) in [("test.cbr", cbrFixtureBase64),
                               ("test.cb7", cb7FixtureBase64)] {
            let url = try write(base64, as: name)
            XCTAssertNotNil(FirstPage.render(of: url, maxPixelSize: 32, scratch: work))
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path),
                           "\(name) left its extraction behind")
        }
    }

    // MARK: - Files that hold no page

    /// A real archive with nothing in it a page could be. Not an error worth
    /// reporting — a caller drawing a thumbnail wants its fallback icon.
    func testAnArchiveOfTextYieldsNothing() throws {
        let url = try write(rarFixtureBase64, as: "text-only.cbr")
        XCTAssertNil(FirstPage.render(of: url, maxPixelSize: 32, scratch: work))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testSomethingThatIsNotAComicYieldsNothing() throws {
        let url = scratch.appendingPathComponent("notes.cbz")
        try Data("this is not an archive".utf8).write(to: url)
        XCTAssertNil(FirstPage.render(of: url, maxPixelSize: 32, scratch: work))
    }
}

// Built by hand with zip/rar/7z, each holding "00-info.nfo" then a 60x90
// "01-page.jpg". The RAR is solid (`rar a -s`), which is the case the single
// entry extraction has to survive: entry N costs everything ahead of it, and
// entry zero is what that makes cheap.
private let cbzFixtureBase64 = """
    UEsDBAoAAAAAAGxvGl03OhL4CwAAAAsAAAALAAAAMDAtaW5mby5uZm9ub3QgYSBwYWdlClBLAwQU\
    AAAACABsbxpd2qQABhUEAAANBQAACwAAADAxLXBhZ2UuanBn+3/j/wMGAS83TzcGRkYGBkYgZPh/\
    m8GZgZeTi5uLg5ebi5uPj5dfWEFUWEhIWF1GTlxBT9PQQE9TV8fYysvO2MzNXEfXIdzRzccvKDjI\
    yC4qMSogwSswyB9kCCMfH5+woLCaqKiav6muqT/J4P8BBkEOhigGG2ZGJQYmQUZmQcb/Rxjkge5k\
    ZQQDBihgZGJmYWVj5wA6GqhgqwADEyMzMxMLMysrCwtQthYoz8AiyCqkaOjIJhyYyK5UKGLUOHEh\
    h7LTxoOiQRc/qBgnFTVxcomJS0hKqaqpa2hqmZiamVtYWjm7uLq5e3h6BYeEhoVHREYlp6SmpWdk\
    ZhWXlJaVV1RWNbe0trV3dHZNmjxl6rTpM2bOWrR4ydJly1esXLVp85at27bv2Lnr0OEjR48dP3Hy\
    1KXLV65eu37j5q2Hjx4/efrs+YuXrz5++vzl67fvP37+AvmLkYGZEQaw+ksQ6C8mFhZmFnaQvxiZ\
    ykEKBFlYFQ3ZhBwD2RMLhZWMGjlEnCYu3HiQU9k46INoUtFFLjEVk4eqH0FeA/uMOI81keUzuMcQ\
    /rrFwMPMCIw8ZkEGe4bDi7remMgK++6++GDHjm33td/duX0jncc9+W1catbFxXKZ8uFRWzLdZ7nL\
    u1ax/1Gusv/zq/6J+38GKfuH0hf/Mzy//J9Byf7HdfNvrXrnf/2ccz9++c3/DPHG51+sd/jP0JIP\
    VDnf/0/Hf4bH7iiat2iW1V8/Y7fff/O/fenzL0bLqW/atuFKctcle10exY47/pbK+y9tfL1pzpVH\
    S3bNLZg1J2R6wHqHD/v/dH/b/8H+L8/1+dcXVMT/c/0d/0P+X1t2v8E/oa//GYwny/8xff0vbatI\
    YJzhE1aRQAcZ/177J/rifwvkfwmH28eyI/PiHVv/8fhX8/7RaK1ib/3P8CR+63+Gxv8ML9L2/NvL\
    fOg/wyf9W/8ZDvxn+GIckSZ/KG7/s8T+f1Iga6K6NNZLfGLq0ljAp35s/ifx7n87+P9yrp6/rhmZ\
    t34B0Aw29b1t/0Sc0MyLq49rfFj/U/xt/YP6X5JrjPkf6sd/Njj+n4G36j/DzLWuIuE9lYyuIgHs\
    wo/9f3If/c8Qw/6v5er5646o3AuJ9c3C9w7XcykiG7feHjmkrkm2f5i+/ueM5P8MbXvrz1xb1KV9\
    zKZhUZcGc+fH5X9aH/1nWMf8n8Ep6/nrBWj8Fwb7D3a+T9zfKrBaMP6es0Sf9O6OCyWhExrsea5W\
    aadNvnNzyXfd+sxX9p//M5T+Z6if/Sfj3+Ur9c//vf73n8H8x9UozSL3DTuVb2z9u3zFf4bzf6//\
    /Zf/cfFv/0Bgkvi9/vef+49DMxZPsm2eZNupPi+7nb/QZNIGCdYbG48vN5UVCVXN7fI6/v8mAFBL\
    AQIeAwoAAAAAAGxvGl03OhL4CwAAAAsAAAALAAAAAAAAAAEAAACkgQAAAAAwMC1pbmZvLm5mb1BL\
    AQIeAxQAAAAIAGxvGl3apAAGFQQAAA0FAAALAAAAAAAAAAAAAACkgTQAAAAwMS1wYWdlLmpwZ1BL\
    BQYAAAAAAgACAHIAAAByBAAAAAA=
    """

private let cbrFixtureBase64 = """
    UmFyIRoHAQAJ78hvCwEFBwQGAQGAgIAAO+LoBikCAwuzCASNCqSDAtqkAAaAGwELMDEtcGFnZS5q\
    cGcKAxOsU49qe0PiBsu6LwRHBkVjIy81Bn9hJCHRDoh7BOi2kOihASlAsCjblT06EI0xWAWiVipG\
    InVcUCpekcc9pQh0Sq1QVLRFBAUq1bAKAltRloWgrlzCw6YBTKdTQaNWAWlJCT2YUhsnwcofJf4/\
    mbu85u883z3fPc5/RbznN3zznm83m7+3fM3N+O/Lf45bgrcYRrionexIhIkIIDL4Le2JDiNDKzM7\
    MyNAOztLS0NQrm2itjYKb2bk3Oe3en9+1HzbHN3FQZzcxMFtnyEj4WJ9D0o3fRu4gz6E/F+xFRka\
    eYE5ILlpFMCvDa2vB6BfIE9//0t6ohhkEPibwmSdRGIwSJgy3riGl+RKkl0E8eEmImUKsZZkX5uv\
    DWbWAoB4mxFCZUqUKL+331/eIUMFWx0f4VjFjEJZ1mjO4nfk+tkdoaw6zbGplG1OezwuSF15Tc3u\
    Di7vBt5evLgIHcwXmbrdw/nRESd8/exW+38d6cfwPUPyPtSUnKSstL+7N8PicXjcecnp9FQUNFRo\
    6Sl+X5vnpuZzaerrK37Ptrud9332PRsrO0/K16XTt7jr9i5uv1/b97y9vr/AT4OFh4+Rk5X8d3Lz\
    P572dn6Hg8Oj4tJSqYJIIsmS/3S7sx46BMAkFCy6w5cVgGMANAkMbZCxhZDNCuuoyGYYErVMrscj\
    VDbqJgTG1gMd3zmCZ1p/0T3k6vvV3yEnDELk9UxGAyIgwlxVo/6gNoL6PUTY1ra2mK9/3idvBlC5\
    2R78hJS6ascpY1Hn7KWO0501EThZW7TgytUPlHVojiNj7JMG2Xeg7qNpJ4LRRbe7VKajFQV2EFFA\
    cu8xJCBvPzC8KpPK6II5J3X3Vk9cQdP2YNKe6JH6SlSm9VyN2NpX30ijvBnwu6UWIe3TslvLDNsa\
    i+yK3p/TM09Rv6aLA2UJVfK0UqgZYXT1Keq4yAiI00GkaIoODy34hs8IGDlKaVwOaRJ2ZmMkH/KK\
    6yE2Z74Rsp9blkyaVCx43rltdKghURBc97zQreUQJSIL/lILMITq5mSf5kWxO3DhnvuGudUG8Bzg\
    SZq3kEvdQ8shxYfAfRvKRvz2II1TSbuanPbuURatSxl59T0J7XSpKpeXGM3bUBBmG2JZIDyE7jjq\
    W7vj4w6pw/A41Y76g0H66DqaJwH5v4xBmP+DjkgjFlhck8pZ+wFP1ixE/f3aeF2E3aQjzwvcuB2Z\
    01xWkG8n9LAcKFRTJFPMkQuKC2H7OBVo3u53nICLyTo86uVosgK3QJg8NL5ebVbGfMfkvWo/8QpU\
    TXzzCDuQ7f8Wy6lF2puO+PkDF7+ce5OlxMKt8T4PLd4bQAZwwYf6FcqRe3w+WRmkBLBaV+feuEdr\
    +k7YNmsrucFC7WJ1hExnVmmejA8O9NJpq8XJjpWspPNntZRm/q4NC1TUBSV7eVwbC6roHaGY539t\
    HFXS3CCLG3BsKQIDC44ABIsApIMCNzoS+MAbAQswMC1pbmZvLm5mbwoDE6xTj2rAPzIHRxYL9yYm\
    3NC5zKGUkmYdd1ZRAwUEAA==
    """

private let cb7FixtureBase64 = """
    N3q8ryccAARHWcmkWQQAAAAAAAAiAAAAAAAAAPl2v/LgBRcD5V0ANxvK6iVLhFhtz6cqFd1tTqQ2\
    NUAVGbqzkVj9HR6kmjhS/BYd+j+sNqOWZiO8sA90Qs+7FcnqdkUF74XTqbIppJUwIVYvvAvDRsfM\
    YgjH58hdaIKkqEY056BbR9QR6CuOChRT4r/uzchEOeAnNuT5BS40s68m9zzXTypFf1MWVkvHFf5A\
    tf1x3Shnz9H0iPOYoC/JCwg/s9i7Z5nRv74aS3uiBeg+o9cc98Mrb2Iuff2xr8CNH8nVJaiLSQ+3\
    2x5WaXez+D8FMuSmCbxqDq0xF1rBdPFrqx4TnNUaHsPNHbX/LldZexrXXW9uNiJNL5nYqSX1obo/\
    CDQe2Z2qPe0vuNM7r1ksH9uyAKky6bDUqGOohsZanglrdiDX3HJsii2bawqcaTF22GIxC6zI9gfy\
    AvWRb5aCCcdtasAtUTVKWLTmonBIBryCHos4f7EGlhh6tdOVFAu8Ddakz8Smk76VMkrmJl2S8Wi5\
    of5fZT9QoQlBUlZeKSQ2OUVAwA0kCoweGmJ/JrpPnptNCIJ+m52nwvu8ABF/cfQ4pj20vLVFV4Va\
    srSK/mqwIMLlmiPAiRZdzAfH9a7pOWuM8yWZijqYI464o+f1d3hQDQTF7ey7AASyHepQ3FoOK5NY\
    pX9twn+NRxXAV/AomkwMSoYcq+gFKk9sfUnKMNhEiiGaT12+JjUGst3idAn2QnjsLcvuBGh9Qi3C\
    drA+PZ2i9PvAzNOQ3JXOuccdjZWEkzySbhYJPfwW8v5jlLUpYUJhHDI1YX1E0efiC+P8Xr0FtY3/\
    PCZSux05o2P/POvKkISGXN7kUTrkzszBYBuhUp/3Vyu8/rA9nSmWFXFsUvVsDrvXGOwxrDRoNjOj\
    pstkloFHhYJIGuW2uWEfeyJCRXp3stp+i4l/TRFzFfE+b0NekUBia+oFkZ1dm4tPVVy0xlJg0la0\
    iiXRz6WqS0If/bB9pA855fRPMbYPV9iogFKxNOsmOqOg2praKhb3+AIJYErUFrVj1ryw5bNumWls\
    QdBVwzqWSWoSdHz2RG2SMN9f+kJXRfy8s9/U00SBDEqkic3kjRKscqZ4NDTQQXml5qR65EJjn5Zw\
    qo9zshpgxpZhB+WGQeOCgKZ5ohAFcT3ASCG2upidewIbe7N1eAg1A/ggISqUWTZ26Rf9EzGi6m6Y\
    nYHGX7EcIX+qud/0XlmBh4ZBjVdd6ECh2WFCo0tFKbzmmx7se48dXHhD5kTG1XeuC46Icp0KcneO\
    KUIrxQGzJqZgzROmaGFBRxQXrAgcwlm2533V4zC+eL6s7lSeKC76/EIbJFgFxMkhrTl4xE2LiOTI\
    XDwU6UV9wS30gAAAAIEzB64P1VMTSSclR1cF0xyjWCJFIljnFG4cPaxbY1P9fzXlhFsCzs0rc1w6\
    gS455NmHkvxsOI9CPZzlJQvvAbQpFmocshVogzeDzW/UCbrijIvsiE0NRdBL1GwLAjb2IY3uetSt\
    JwCUAAAXBoPtAQlsAAcLAQABIwMBAQVdABAAAAyAhgoBVznS1gAA
    """
