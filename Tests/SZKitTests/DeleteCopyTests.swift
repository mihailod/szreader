import XCTest
@testable import SZKit

/// What the app promises before it destroys something.
///
/// These used to be a lint that read `LibraryView.swift` as text and guessed,
/// because the copy lived in the app target and nothing could call it. It
/// failed twice on its own formatting — a sentence wrapped across two lines
/// looked missing, and a ternary whose `?` sat after a newline looked
/// unconditional — and passed once while the thing it named was broken. Now
/// the sentences are simply asked for and read.
final class DeleteCopyTests: XCTestCase {

    // MARK: - Scope: what leaves this device, and what does not

    /// Deleting an issue is not a local act once the library syncs, and an
    /// alert that does not say so is asking somebody to agree to something it
    /// has not told them.
    func testDeletingAnIssueSaysItReachesTheOtherDevices() {
        let message = DeleteCopy.deleteMessage("Nasilje u Darkvudu", synced: true)
        XCTAssertTrue(message.contains("all other devices logged into this iCloud account"),
                      message)
    }

    /// And says nothing of the kind to somebody who is not signed in, for whom
    /// it would simply be false.
    func testDeletingAnIssueSaysNothingAboutDevicesWhenNotSyncing() {
        let message = DeleteCopy.deleteMessage("Nasilje u Darkvudu", synced: false)
        XCTAssertFalse(message.lowercased().contains("other devices"), message)
        XCTAssertFalse(message.lowercased().contains("icloud"), message)
    }

    func testDeletingSeveralIssuesSaysItReachesTheOtherDevices() {
        let message = DeleteCopy.deleteVisibleMessage(4, shipped: 0, wholeLibrary: false,
                                                      synced: true)
        XCTAssertTrue(message.contains("They will be also deleted from StreamZine apps"),
                      message)
    }

    func testDeletingOneVisibleIssueUsesTheSingular() {
        let message = DeleteCopy.deleteVisibleMessage(1, shipped: 0, wholeLibrary: false,
                                                      synced: true)
        XCTAssertTrue(message.contains("It will be also deleted"), message)
        XCTAssertFalse(message.contains("They will be also"), message)
    }

    /// The one that matters most, since it is the button that empties
    /// everything.
    func testDeletingTheLibrarySaysItReachesTheOtherDevices() {
        let message = DeleteCopy.deleteAllMessage(2_854, shipped: 0, synced: true)
        XCTAssertTrue(message.contains("all other devices logged into this iCloud account"),
                      message)
        XCTAssertTrue(message.contains("cannot be undone"), message)
    }

    func testDeletingTheLibrarySaysNothingAboutDevicesWhenNotSyncing() {
        let message = DeleteCopy.deleteAllMessage(2_854, shipped: 0, synced: false)
        XCTAssertFalse(message.lowercased().contains("icloud"), message)
    }

    /// Removing a **download** is a different scope: the file is this
    /// device's, the library keeps the title, and nothing leaves anywhere
    /// else. Claiming otherwise would frighten a reader out of reclaiming
    /// space.
    func testRemovingADownloadNeverMentionsOtherDevices() {
        for message in [DeleteCopy.removeDownloadMessage("Zagor"),
                        DeleteCopy.removeVisibleMessage(12, touchesASet: false),
                        DeleteCopy.removeVisibleMessage(12, touchesASet: true)] {
            XCTAssertFalse(message.lowercased().contains("other devices"), message)
            XCTAssertFalse(message.lowercased().contains("icloud"), message)
        }
    }

    /// The reader's own files sync nowhere at all — the folder on the device
    /// is the source.
    func testLocalFileDeletesNeverMentionOtherDevices() {
        for message in [DeleteCopy.deleteLocalFileMessage("Brodeckov izvjestaj"),
                        DeleteCopy.deleteLocalFilesMessage(3, bytes: 90_000_000)] {
            XCTAssertFalse(message.lowercased().contains("other devices"), message)
            XCTAssertFalse(message.lowercased().contains("icloud"), message)
        }
    }

    // MARK: - The sentences themselves

    /// A missing name must not leave a hole in the sentence.
    func testAnUnnamedIssueStillReads() {
        let message = DeleteCopy.deleteMessage(nil, synced: true)
        XCTAssertTrue(message.hasPrefix("Delete this issue from the library"), message)
        XCTAssertFalse(message.contains("“”"), message)
    }

    /// Never "comic": the library holds magazines too, and this copy left the
    /// app target where `UIWordingTests` was watching for it.
    func testTheCopyNeverSaysComic() {
        let all = [
            DeleteCopy.deleteMessage("x", synced: true),
            DeleteCopy.deleteMessage("x", synced: false),
            DeleteCopy.deleteVisibleMessage(3, shipped: 1, wholeLibrary: true, synced: true),
            DeleteCopy.deleteVisibleTitle(3),
            DeleteCopy.deleteAllMessage(3, shipped: 0, local: 2, synced: true),
            DeleteCopy.removeDownloadMessage("x"),
            DeleteCopy.removeVisibleTitle(3),
            DeleteCopy.removeVisibleMessage(3, touchesASet: true),
            DeleteCopy.deleteLocalFileMessage("x"),
            DeleteCopy.deleteLocalFilesMessage(2, bytes: 1_000),
            DeleteCopy.undeletableMessage(downloaded: true),
        ]
        for message in all {
            let lowered = message.lowercased()
            XCTAssertFalse(lowered.contains("comic") && !lowered.contains("magazine"), message)
        }
    }

    /// Delete Library warns that the shelf shown is the whole library, because
    /// "delete the ones shown" is otherwise a narrower thing than it sounds.
    func testDeletingEverythingShownSaysSo() {
        let narrowed = DeleteCopy.deleteVisibleMessage(3, shipped: 0, wholeLibrary: false,
                                                       synced: false)
        let everything = DeleteCopy.deleteVisibleMessage(3, shipped: 0, wholeLibrary: true,
                                                         synced: false)
        XCTAssertFalse(narrowed.contains("everything in the library"), narrowed)
        XCTAssertTrue(everything.contains("everything in the library"), everything)
    }

    /// Local files are asked about separately, and Delete Library says so
    /// rather than letting "resetting the app to empty" be a promise it does
    /// not keep.
    func testDeleteLibraryMentionsLocalFilesWhenThereAreSome() {
        XCTAssertTrue(DeleteCopy.deleteAllMessage(5, shipped: 0, local: 2)
            .contains("asked about next"))
        XCTAssertFalse(DeleteCopy.deleteAllMessage(5, shipped: 0, local: 0)
            .contains("asked about next"))
    }

    func testSizesReadAsTheShelfWritesThem() {
        XCTAssertEqual(ByteSize.short(900), "1KB", "a small file must not read as nothing")
        XCTAssertEqual(ByteSize.short(512_000), "512KB")
        XCTAssertEqual(ByteSize.short(90_000_000), "90MB")
    }
}

/// The size in the download-removal question.
///
/// "Remove the downloaded files" is a decision about space, and asking it
/// without the number makes the reader cancel, go and find the size, and come
/// back.
extension DeleteCopyTests {

    func testRemovingADownloadSaysWhatItFrees() {
        let message = DeleteCopy.removeDownloadMessage("Nasilje u Darkvudu",
                                                       bytes: 45_000_000)
        XCTAssertTrue(message.contains("“Nasilje u Darkvudu” (45MB)"), message)
    }

    func testASmallDownloadStillReadsAsSomething() {
        let message = DeleteCopy.removeDownloadMessage("Alef 01", bytes: 900)
        XCTAssertTrue(message.contains("(1KB)"), message)
    }

    /// A size that is not known is left out rather than guessed at: "(0KB)" is
    /// a wrong number and "(unknown size)" is a caveat nobody can act on.
    func testAnUnknownSizeIsNotMentioned() {
        let message = DeleteCopy.removeDownloadMessage("Alef 01", bytes: nil)
        XCTAssertFalse(message.contains("("), message)
        XCTAssertTrue(message.contains("the downloaded files for “Alef 01”."), message)
    }

    /// And with neither a name nor a size the sentence still reads.
    func testAnUnnamedDownloadOfUnknownSizeStillReads() {
        let message = DeleteCopy.removeDownloadMessage(nil, bytes: nil)
        XCTAssertTrue(message.hasPrefix("Remove the downloaded files for this issue."),
                      message)
    }

    /// Still says nothing about other devices: a download is this device's.
    func testTheSizeDidNotWidenTheScope() {
        let message = DeleteCopy.removeDownloadMessage("x", bytes: 45_000_000)
        XCTAssertFalse(message.lowercased().contains("icloud"), message)
    }
}

/// The sentence shown once per device when a library arrives with no files.
final class SyncCopyTests: XCTestCase {

    func testItNamesHowManyLinksCameBack() {
        XCTAssertEqual(SyncCopy.restoredLibraryMessage(count: 2_854),
                       "Your 2854 library links were restored from iCloud and are "
                     + "ready for individual re-download.")
    }

    /// Three agreements in one sentence — "link", "were", "are" — which is
    /// exactly the shape that reads wrong for one and nobody notices.
    func testOneLinkReadsAsOne() {
        XCTAssertEqual(SyncCopy.restoredLibraryMessage(count: 1),
                       "Your 1 library link was restored from iCloud and is "
                     + "ready for individual re-download.")
    }

    /// It promises links, not files. The whole point is that the reading
    /// material did not come with them.
    func testItDoesNotPromiseTheFiles() {
        let message = SyncCopy.restoredLibraryMessage(count: 12)
        XCTAssertTrue(message.contains("re-download"), message)
        XCTAssertFalse(message.lowercased().contains("downloaded and ready"), message)
    }

    func testItNeverSaysComic() {
        for count in [1, 2, 2_854] {
            let lowered = SyncCopy.restoredLibraryMessage(count: count).lowercased()
            XCTAssertFalse(lowered.contains("comic") && !lowered.contains("magazine"))
        }
    }
}
