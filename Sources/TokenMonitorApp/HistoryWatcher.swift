import Darwin
import Foundation

@MainActor
final class HistoryWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceTask: Task<Void, Never>?
    private let onChange: @MainActor () -> Void

    init(paths: [URL], onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            let descriptor = open(path.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.scheduleDebouncedChange() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        debounceTask?.cancel()
        sources.forEach { $0.cancel() }
    }

    private func scheduleDebouncedChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
