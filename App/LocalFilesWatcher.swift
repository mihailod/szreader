import Foundation

/// Watches the folder the reader drags files into.
///
/// Without this the shelf only agrees with the folder at launch and on
/// returning to the front — which is exactly when the reader is *not*
/// looking, because the iPad is plugged into a computer with the app open in
/// front of them. Dragging four issues across in the Finder and watching
/// nothing happen is the whole feature failing to be the thing it is for.
///
/// A `DispatchSource` on the directory, not a timer. The kernel reports when
/// an entry is added, removed or renamed, so an idle app costs nothing and a
/// change is noticed at once.
final class LocalFilesWatcher {

    private let source: DispatchSourceFileSystemObject
    private let descriptor: CInt
    private let queue = DispatchQueue(label: "com.mihailod.szreader.local-files")
    private var pending: DispatchWorkItem?

    /// How long the folder must go quiet before the change is acted on.
    ///
    /// Short, because this is only coalescing the burst of events a batch of
    /// files produces as their directory entries appear — the wait for a file
    /// to finish *copying* is a separate question, answered by
    /// `LocalFiles.settled`, and this must not be mistaken for it.
    private static let quiet: TimeInterval = 0.4

    /// Nil when the folder cannot be opened for watching, which is not worth
    /// failing over: the scans at launch and on foreground still happen, and
    /// the app is exactly as correct as it was before, only slower to notice.
    init?(directory: URL, onChange: @escaping @Sendable () -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        descriptor = fd
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // A file arriving or leaving is a write to the directory. The
            // other two are the directory itself going away — the container
            // being replaced — after which there is nothing left to watch.
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { onChange() }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + Self.quiet, execute: work)
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    deinit {
        pending?.cancel()
        source.cancel()
    }
}
