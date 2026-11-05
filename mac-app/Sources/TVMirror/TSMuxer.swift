import Foundation

/// Packs H.264 video and MP2 sound into an MPEG transport stream (the format TV
/// broadcasts use, and that older Sony TVs accept over DLNA): 188-byte packets.
final class TSMuxer {
    static let packetSize = 188
    static let pmtPID: UInt16 = 0x1000
    static let videoPID: UInt16 = 0x100
    static let audioPID: UInt16 = 0x101

    /// Called with each finished piece of stream; `keyframe` = it starts with a complete picture.
    var output: ((Data, Bool) -> Void)?
    private var continuity: [UInt16: UInt8] = [:]

    // MARK: Writing

    /// One encoded picture (Annex B, starting with an access unit delimiter).
    func writeVideo(_ frame: Data, pts: Int64, keyframe: Bool) {
        var out = Data()
        if keyframe {      // the stream map before every complete picture, so a TV can join there
            out.append(psiPacket(pid: 0, section: patSection()))
            out.append(psiPacket(pid: Self.pmtPID, section: pmtSection()))
        }
        let pes = pesPacket(streamID: 0xE0, payload: frame, pts: pts, bounded: false)
        out.append(packetize(pid: Self.videoPID, payload: pes, pcr: pts - 9000, randomAccess: keyframe))
        output?(out, keyframe)
    }

    /// One MP2 sound frame.
    func writeAudio(_ frame: Data, pts: Int64) {
        let pes = pesPacket(streamID: 0xC0, payload: frame, pts: pts, bounded: true)
        output?(packetize(pid: Self.audioPID, payload: pes, pcr: nil, randomAccess: false), false)
    }

    // MARK: Tables

    private func patSection() -> [UInt8] {
        var s: [UInt8] = [0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0x00, 0x00,
                          0x00, 0x01, 0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)]
        s += crc32(s)
        return s
    }

    private func pmtSection() -> [UInt8] {
        var s: [UInt8] = [0x02, 0xB0, 23, 0x00, 0x01, 0xC1, 0x00, 0x00,
                          0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF),   // PCR is on video
                          0xF0, 0x00]
        s += [0x1B, 0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]   // H.264
        s += [0x03, 0xE0 | UInt8(Self.audioPID >> 8), UInt8(Self.audioPID & 0xFF), 0xF0, 0x00]   // MPEG-1 audio
        s += crc32(s)
        return s
    }

    private func psiPacket(pid: UInt16, section: [UInt8]) -> Data {
        var p: [UInt8] = [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | nextContinuity(pid), 0x00]
        p += section
        p += [UInt8](repeating: 0xFF, count: Self.packetSize - p.count)
        return Data(p)
    }

    // MARK: PES and packets

    private func pesPacket(streamID: UInt8, payload: Data, pts: Int64, bounded: Bool) -> Data {
        var h: [UInt8] = [0x00, 0x00, 0x01, streamID]
        let length = bounded ? payload.count + 8 : 0
        h += [UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF), 0x80, 0x80, 5]
        h += timestamp(pts, prefix: 0x20)
        var pes = Data(h)
        pes.append(payload)
        return pes
    }

    private func timestamp(_ value: Int64, prefix: UInt8) -> [UInt8] {
        let t = UInt64(bitPattern: value) & 0x1_FFFF_FFFF
        return [prefix | UInt8((t >> 29) & 0x0E) | 1,
                UInt8((t >> 22) & 0xFF),
                UInt8((t >> 14) & 0xFE) | 1,
                UInt8((t >> 7) & 0xFF),
                UInt8((t << 1) & 0xFE) | 1]
    }

    private func packetize(pid: UInt16, payload: Data, pcr: Int64?, randomAccess: Bool) -> Data {
        var out = Data(capacity: (payload.count / 184 + 2) * Self.packetSize)
        var position = payload.startIndex
        var first = true
        while position < payload.endIndex {
            var adaptation: [UInt8]? = nil            // adaptation field, without its length byte
            if first && (pcr != nil || randomAccess) {
                var flags: UInt8 = 0
                var extra: [UInt8] = []
                if randomAccess { flags |= 0x40 }
                if let pcr {
                    flags |= 0x10
                    let base = UInt64(bitPattern: max(pcr, 0)) & 0x1_FFFF_FFFF
                    extra = [UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF),
                             UInt8((base >> 9) & 0xFF), UInt8((base >> 1) & 0xFF),
                             UInt8((base & 1) << 7) | 0x7E, 0x00]
                }
                adaptation = [flags] + extra
            }
            let remaining = payload.endIndex - position
            var room = 184 - (adaptation.map { $0.count + 1 } ?? 0)
            if remaining < room {                      // last packet: pad with stuffing bytes
                let stuffing = room - remaining
                if var a = adaptation {
                    a += [UInt8](repeating: 0xFF, count: stuffing)
                    adaptation = a
                } else if stuffing == 1 {
                    adaptation = []                    // just the length byte (0)
                } else {
                    adaptation = [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)
                }
                room = remaining
            }
            let control: UInt8 = adaptation == nil ? 0x10 : 0x30
            var packet: [UInt8] = [0x47, (first ? 0x40 : 0x00) | UInt8(pid >> 8), UInt8(pid & 0xFF),
                                   control | nextContinuity(pid)]
            if let a = adaptation { packet += [UInt8(a.count)] + a }
            var data = Data(packet)
            data.append(payload[position..<(position + room)])
            out.append(data)
            position += room
            first = false
        }
        return out
    }

    private func nextContinuity(_ pid: UInt16) -> UInt8 {
        let value = continuity[pid] ?? 0
        continuity[pid] = (value + 1) & 0x0F
        return value
    }

    // MARK: CRC-32 (MPEG-2)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = (c & 0x8000_0000) != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }

    private func crc32(_ bytes: [UInt8]) -> [UInt8] {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = (crc << 8) ^ Self.crcTable[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)] }
        return [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }
}
