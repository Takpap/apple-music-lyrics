import Foundation

/// Calls `onChange` (debounced, on the main queue) when files in any of the
/// watched directories are created, renamed or rewritten. Editors such as
/// TextEdit save by replacing the file, which shows up as a directory write.
final class DirectoryWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(urls: [URL], onChange: @escaping () -> Void) {
        self.onChange = onChange
        for url in urls {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.schedule() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
