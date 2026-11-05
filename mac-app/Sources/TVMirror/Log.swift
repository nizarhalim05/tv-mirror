import Foundation

/// Writes a simple log to ~/Library/Logs/TVMirror.log, for troubleshooting.
enum Log {
    private static let queue = DispatchQueue(label: "tvmirror.log")
    private static let handle: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TVMirror.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)   // a fresh log each launch
        return try? FileHandle(forWritingTo: url)
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { handle?.write(line.data(using: .utf8) ?? Data()) }
    }
}
