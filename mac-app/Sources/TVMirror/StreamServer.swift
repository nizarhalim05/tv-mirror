import Foundation
import Darwin

/// One play session's live video, kept as an ever-growing "file".
///
/// Older Sony TVs don't stream a video: they download it in pieces ("bytes 0-2,000,000",
/// then "2,000,000-4,000,000", ...), and each piece must carry on exactly where the last
/// one stopped. So the recent video is kept with its byte positions.
final class LiveFile {
    let generation: Int
    static let keep = 128 * 1024 * 1024        // about 2 minutes at 8 Mbit/s
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var offsets: [Int] = []
    private var first = 0
    private var startOffset = 0
    private var endOffset = 0
    private var closed = false
    var waitingForKeyframe = true              // a new "file" starts with a complete picture

    init(generation: Int) { self.generation = generation }

    var start: Int { condition.lock(); defer { condition.unlock() }; return startOffset }
    var end: Int { condition.lock(); defer { condition.unlock() }; return endOffset }

    func append(_ data: Data) {
        condition.lock()
        offsets.append(endOffset)
        chunks.append(data)
        endOffset += data.count
        while endOffset - startOffset > Self.keep && first < chunks.count - 1 {
            chunks[first] = Data()
            first += 1
            startOffset = offsets[first]
        }
        if first > 4096 {
            chunks.removeFirst(first)
            offsets.removeFirst(first)
            first = 0
        }
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Up to `max` bytes from `offset`, waiting for them if needed. Returns nil on timeout,
    /// empty data once the session has ended, and the offset actually used.
    func read(from offset: Int, max: Int, timeout: TimeInterval) -> (Data, Int)? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while endOffset <= offset && !closed {
            if !condition.wait(until: deadline) { return nil }
        }
        if endOffset <= offset { return (Data(), offset) }
        var position = Swift.max(offset, startOffset)
        let used = position
        var low = first, high = offsets.count - 1        // last chunk starting at or before it
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= position { low = mid } else { high = mid - 1 }
        }
        var out = Data()
        var i = low
        while i < chunks.count && out.count < max {
            let chunk = chunks[i]
            let skip = position - offsets[i]
            let take = Swift.min(chunk.count - skip, max - out.count)
            if take > 0 {
                let from = chunk.startIndex + skip
                out.append(chunk[from..<(from + take)])
                position += take
            }
            i += 1
        }
        return (out, used)
    }
}

/// A tiny web server on port 8090 that the TV downloads the video from.
final class StreamServer {
    let port: UInt16
    private let lock = NSLock()
    private var file: LiveFile?
    private var generation = 0
    private(set) var delivered = 0
    private static let fakeLength = 100 * 1024 * 1024 * 1024    // "a very long video" (100 GB)
    private static let features = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    init(port: UInt16 = 8090) { self.port = port }

    // MARK: Play sessions

    /// Starts a new "file" for the TV and returns its number (used in the link).
    func newFile() -> Int {
        lock.lock(); defer { lock.unlock() }
        file?.close()
        generation += 1
        file = LiveFile(generation: generation)
        return generation
    }

    func endFile() {
        lock.lock(); defer { lock.unlock() }
        file?.close()
        file = nil
    }

    /// New video from the muxer; `keyframe` = this chunk starts with a complete picture.
    func append(_ data: Data, keyframe: Bool) {
        lock.lock()
        let current = file
        lock.unlock()
        guard let current else { return }
        if current.waitingForKeyframe {
            guard keyframe else { return }
            current.waitingForKeyframe = false
        }
        current.append(data)
    }

    private var currentFile: LiveFile? {
        lock.lock(); defer { lock.unlock() }
        return file
    }

    // MARK: Network

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Discovery.TVError(description: "Couldn't open a network port.") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)   // any address
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw Discovery.TVError(description: "Port \(port) is in use (is another TV Mirror running?).")
        }
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                Thread.detachNewThread { self?.handle(client) }
            }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var sendBuffer: Int32 = 256 * 1024    // keep video from piling up unseen inside macOS
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        // Read the request
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 16_384 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return }
            request.append(contentsOf: buffer[0..<n])
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let text = String(data: request, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let who = peerName(fd)
        Log.write("\(who) \(method) \(target) range=\(headers["range"] ?? "-")")

        let components = URLComponents(string: target)
        let generation = components?.queryItems?.first { $0.name == "g" }?.value
        guard components?.path == "/screen.ts", method == "GET" || method == "HEAD",
              let live = currentFile, generation == nil || generation == String(live.generation) else {
            _ = sendAll(fd, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        // Which bytes does the TV want?
        var first = 0
        var last = Self.fakeLength - 1
        var ranged = false
        if let range = headers["range"], range.hasPrefix("bytes=") {
            ranged = true
            let pieces = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if let a = pieces.first, let value = Int(a) { first = Swift.min(value, Self.fakeLength - 1) }
            if pieces.count > 1, let value = Int(pieces[1]) { last = Swift.min(value, Self.fakeLength - 1) }
        }
        let length = Swift.max(0, last - first + 1)
        var head = ranged ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(first)-\(last)/\(Self.fakeLength)\r\n"
                          : "HTTP/1.1 200 OK\r\n"
        head += "Content-Length: \(length)\r\nAccept-Ranges: bytes\r\nContent-Type: video/mpeg\r\n"
        head += "transferMode.dlna.org: Streaming\r\ncontentFeatures.dlna.org: \(Self.features)\r\n"
        head += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        guard sendAll(fd, Data(head.utf8)), method == "GET" else { return }

        var sent = 0
        if first > live.end + 64 * 1024 * 1024 {
            // The TV peeks at "the end of the file" to work out how long the video is.
            // Give it the newest real video (empty filler makes it refuse to play).
            let cap = Swift.min(length, 4 * 1024 * 1024)
            var position = Swift.max(live.start, live.end - cap)
            position -= (position - live.start) % 188
            while sent < cap {
                guard let piece = live.read(from: position, max: Swift.min(256 * 1024, cap - sent), timeout: 5),
                      !piece.0.isEmpty, sendAll(fd, piece.0) else { break }
                sent += piece.0.count
                position = piece.1 + piece.0.count
            }
        } else {
            var position = first
            while sent < length {
                guard let piece = live.read(from: position, max: Swift.min(256 * 1024, length - sent), timeout: 15),
                      !piece.0.isEmpty, sendAll(fd, piece.0) else { break }
                sent += piece.0.count
                position = piece.1 + piece.0.count
                lock.lock(); delivered += piece.0.count; lock.unlock()
            }
        }
        Log.write("\(who) done: \(sent) bytes")
    }

    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = send(fd, base + offset, raw.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private func peerName(_ fd: Int32) -> String {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
