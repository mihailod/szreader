import XCTest

/// What a delete confirmation promises.
///
/// Deleting stopped being a local act when the library started syncing: an
/// issue removed here goes from the reader's other devices too, bulk deletes
/// included. An alert that does not say so is asking somebody to agree to
/// something it has not told them — and the one place that matters is the
/// button marked "Delete Library".
///
/// A lint over the app's own source text, as `UIWordingTests` is, because the
/// copy lives in the app target and there is no test target for it.
final class DeleteWordingTests: XCTestCase {

    private static let source: String = {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/LibraryView.swift")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }()

    private func body(of function: String) throws -> String {
        let source = Self.source
        XCTAssertFalse(source.isEmpty, "LibraryView.swift not found")
        let start = try XCTUnwrap(source.range(of: "static func \(function)"),
                                  "no \(function)")
        let rest = source[start.upperBound...]
        // To the end of the function: these are short and end at the first
        // line that closes at four spaces.
        let end = try XCTUnwrap(rest.range(of: "\n    }"), "\(function) is not closed")
        // Whitespace collapsed, because these are formatted for reading and a
        // ternary wrapped across two lines is the same code as one on a single
        // line. Matching the raw text called a perfectly conditional sentence
        // unconditional, which is a test failing on its own formatting.
        return String(rest[..<end.lowerBound])
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Each of the three that delete issues has to be able to say it reaches
    /// the other devices, and has to be told whether it does.
    func testEveryIssueDeleteMessageCanSayItReachesOtherDevices() throws {
        for function in ["deleteMessage", "deleteVisibleMessage", "deleteAllMessage"] {
            let body = try self.body(of: function)
            XCTAssertTrue(body.contains("synced"),
                          "\(function) cannot tell whether deleting syncs")
            XCTAssertTrue(body.contains("other devices"),
                          "\(function) never mentions the reader's other devices")
        }
    }

    /// And it must be conditional. Saying it to somebody who is not signed
    /// into iCloud is simply false.
    func testTheClaimIsConditionalOnActuallySyncing() throws {
        for function in ["deleteMessage", "deleteVisibleMessage", "deleteAllMessage"] {
            let body = try self.body(of: function)
            let conditional = body.contains("synced ?") || body.contains("(synced")
            XCTAssertTrue(conditional,
                          "\(function) claims to reach other devices unconditionally")
        }
    }

    /// Removing a *download* is a different scope and must not claim
    /// otherwise: the file is this device's, the library keeps the title, and
    /// nothing leaves anywhere else.
    func testRemovingADownloadDoesNotClaimToReachOtherDevices() throws {
        for function in ["removeMessage", "removeVisibleMessage"] {
            guard Self.source.contains("static func \(function)") else { continue }
            let body = try self.body(of: function)
            XCTAssertFalse(body.contains("other devices"),
                           "\(function) says a download removal reaches other devices")
        }
    }

    /// Likewise the reader's own files, which sync nowhere at all.
    func testLocalFileDeletesDoNotClaimToReachOtherDevices() throws {
        for function in ["deleteLocalFileMessage", "deleteLocalFilesMessage"] {
            guard Self.source.contains("static func \(function)") else { continue }
            let body = try self.body(of: function)
            XCTAssertFalse(body.contains("other devices"),
                           "\(function) says a local file reaches other devices")
        }
    }
}
