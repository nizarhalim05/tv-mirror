import Foundation
import Darwin

/// A TV (or other DLNA player) on the network that can play a video from a link.
struct TV: Hashable {
    let name: String
    let host: String
    let controlURL: URL
}

/// Finding TVs (SSDP) and telling them what to play (UPnP AVTransport).
enum Discovery {
    static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"

    // MARK: Finding TVs

    /// Searches the local network for TVs. Blocking: call it off the main thread.
    static func search(timeout: TimeInterval = 4) -> [TV] {
        var tvs: [TV] = []
        var seen = Set<String>()
        for location in ssdpLocations(timeout: timeout).sorted() {
            guard let tv = loadDevice(location), !seen.contains(tv.controlURL.absoluteString) else { continue }
            seen.insert(tv.controlURL.absoluteString)
            tvs.append(tv)
        }
        Log.write("search found \(tvs.map { "\($0.name) (\($0.host))" })")
        return tvs
    }

    private static func ssdpLocations(timeout: TimeInterval) -> Set<String> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &addr.sin_addr)
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n"
            + "MX: 2\r\nST: \(avTransport)\r\n\r\n"
        let bytes = Array(message.utf8)
        for _ in 0..<3 {
            _ = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            usleep(100_000)
        }

        var locations = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0, let text = String(bytes: buffer[0..<n], encoding: .utf8) else { continue }
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                locations.insert(line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return locations
    }

    private static func loadDevice(_ location: String) -> TV? {
        guard let url = URL(string: location), let host = url.host,
              let data = fetch(URLRequest(url: url, timeoutInterval: 5)) else { return nil }
        let reader = DeviceDescription()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        guard let control = reader.controlURL else { return nil }
        let base = URL(string: reader.urlBase ?? "") ?? url
        guard let controlURL = URL(string: control, relativeTo: base)?.absoluteURL else { return nil }
        return TV(name: reader.friendlyName ?? "TV", host: host, controlURL: controlURL)
    }

    /// Reads a UPnP device description: name, URLBase and the AVTransport control URL.
    private final class DeviceDescription: NSObject, XMLParserDelegate {
        var friendlyName: String?
        var urlBase: String?
        var controlURL: String?
        private var text = ""
        private var serviceType = ""
        private var serviceControl = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "service" { serviceType = ""; serviceControl = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "friendlyName" where friendlyName == nil: friendlyName = value
            case "URLBase" where !value.isEmpty: urlBase = value
            case "serviceType": serviceType = value
            case "controlURL": serviceControl = value
            case "service":
                if serviceType.contains("AVTransport"), !serviceControl.isEmpty, controlURL == nil {
                    controlURL = serviceControl
                }
            default: break
            }
            text = ""
        }
    }

    // MARK: Telling the TV what to play

    struct TVError: Error, CustomStringConvertible {
        let description: String
    }

    static func play(_ tv: TV, url: String) throws {
        try? soap(tv, "Stop", [("InstanceID", "0")])
        let protocolInfo = "http-get:*:video/mpeg:DLNA.ORG_OP=01;DLNA.ORG_CI=0;"
            + "DLNA.ORG_FLAGS=01700000000000000000000000000000"
        let metadata = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>TV Mirror</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"\(protocolInfo)\">\(escape(url))</res></item></DIDL-Lite>"
        try soap(tv, "SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", url),
                                           ("CurrentURIMetaData", metadata)])
        try soap(tv, "Play", [("InstanceID", "0"), ("Speed", "1")])
        Log.write("told \(tv.name) to play \(url)")
    }

    static func stop(_ tv: TV) {
        try? soap(tv, "Stop", [("InstanceID", "0")])
    }

    @discardableResult
    private static func soap(_ tv: TV, _ action: String, _ args: [(String, String)]) throws -> String {
        let argXML = args.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(avTransport)\">\(argXML)</u:\(action)></s:Body></s:Envelope>"
        var request = URLRequest(url: tv.controlURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(avTransport)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        var status = 0
        guard let data = fetch(request, status: &status) else {
            throw TVError(description: "The TV didn't answer.")
        }
        let reply = String(data: data, encoding: .utf8) ?? ""
        if status >= 300 {
            throw TVError(description: "The TV refused \(action) (error \(status)).")
        }
        return reply
    }

    private static func fetch(_ request: URLRequest) -> Data? {
        var status = 0
        return fetch(request, status: &status)
    }

    private static func fetch(_ request: URLRequest, status: inout Int) -> Data? {
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        var code = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = data
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        done.wait()
        status = code
        return result
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// This Mac's address on the network the TV is on.
    static func localIP(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(9).bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &remote) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard ok == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
