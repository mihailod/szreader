import XCTest
@testable import SZKit

/// What the reader is told when a file they handed over never arrived.
///
/// Worth testing for the reason `DeleteCopyTests` gives: this wording lives in
/// the kit precisely so it can be read back rather than eyeballed in the file
/// that shows it. What it has to get right is that **nothing is on the shelf**
/// — the failure these describe leaves no row, no tile and no folder entry, so
/// a message that merely says something went wrong leaves the reader looking
/// for an issue that was never written.
final class ImportCopyTests: XCTestCase {

    /// The list of formats is derived, not typed, so adding one to
    /// `LocalFiles` cannot leave the sentence a format behind.
    func testAcceptedFormatsNamesEveryReadableExtension() {
        let sentence = ImportCopy.acceptedFormats
        for ext in LocalFiles.readableExtensions {
            XCTAssertTrue(sentence.contains(ext.uppercased()),
                          "\(ext) is accepted but the reader is never told so")
        }
        XCTAssertTrue(sentence.contains(" or "), "reads as a list, not a sentence")
    }

    /// The refusal a reader can act on says what to hand over instead.
    func testUnsupportedSaysWhatWouldHaveWorked() {
        let message = ImportCopy.unsupportedMessage("Notes.epub")
        XCTAssertTrue(message.contains("Notes.epub"))
        XCTAssertTrue(message.contains("CBZ"), "never says what this app does open")
        XCTAssertFalse(message.lowercased().contains("comic"),
                       "say \u{201C}issue\u{201D} \u{2014} the shelf holds magazines too")
    }

    /// Both failures say the file is not on the shelf, which is the fact the
    /// reader cannot see for themselves.
    func testEveryRefusalSaysTheFileIsNotOnTheShelf() {
        let messages = [
            ImportCopy.unsupportedMessage("A.epub"),
            ImportCopy.refusedMessage("B.cbz"),
            ImportCopy.refusedMessage("C.cbz", reason: "the disk is full"),
            ImportCopy.refusedMessage(["D.cbz", "E.cbz"], of: 5),
        ]
        for message in messages {
            XCTAssertTrue(message.contains("not taken in")
                          || message.contains("not on the shelf"),
                          "does not say the file never arrived: \(message)")
        }
    }

    /// A reason is carried when there is one and not promised when there is
    /// not.
    func testTheReasonIsOptionalRatherThanInvented() {
        XCTAssertTrue(ImportCopy.refusedMessage("B.cbz", reason: "the disk is full")
            .contains("the disk is full"))
        let silent = ImportCopy.refusedMessage("B.cbz")
        XCTAssertFalse(silent.lowercased().contains("unknown"),
                       "an absent reason was dressed up as one")
        XCTAssertFalse(silent.hasSuffix("\n\n"), "left a hole where the reason goes")
    }

    /// The batch names the files rather than counting them, so the reader does
    /// not have to work out which of eleven did not make it.
    func testABatchNamesWhatWasRefused() {
        let message = ImportCopy.refusedMessage(["A.cbz", "B.cbr"], of: 7)
        XCTAssertTrue(message.contains("A.cbz"))
        XCTAssertTrue(message.contains("B.cbr"))
        XCTAssertTrue(message.contains("2 of 7"))
        XCTAssertEqual(ImportCopy.refusedTitle(2), "Some files were not taken in")
    }

    /// One refused file out of a batch reads as one file, not as a list of
    /// one — and takes the singular heading.
    func testOneRefusedFileIsNotAListOfOne() {
        let message = ImportCopy.refusedMessage(["A.cbz"], of: 4)
        XCTAssertEqual(message, ImportCopy.refusedMessage("A.cbz"))
        XCTAssertFalse(message.contains("1 of 4"))
        XCTAssertEqual(ImportCopy.refusedTitle(1), ImportCopy.refusedTitle)
    }

    /// An alert cannot hold a hundred names, and the ones it drops are
    /// counted rather than quietly lost.
    func testALongListIsCappedAndTheRestCounted() {
        let names = (1...20).map { "File \($0).cbz" }
        let message = ImportCopy.refusedMessage(names, of: 40, listing: 8)
        XCTAssertTrue(message.contains("File 8.cbz"))
        XCTAssertFalse(message.contains("File 9.cbz"))
        XCTAssertTrue(message.contains("and 12 more"))
    }
}
