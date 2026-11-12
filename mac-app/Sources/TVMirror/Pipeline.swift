import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

/// macOS hasn't let TellyBeam record the screen (Screen Recording permission).
struct ScreenPermissionError: Error, CustomStringConvertible {
    var description: String { "Screen Recording isn't allowed for TellyBeam." }
}

/// Records one screen with ScreenCaptureKit and keeps the latest picture.
final class ScreenSource: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var frames = 0
    private var onFrameHandler: ((CVPixelBuffer) -> Void)?
    private let queue = DispatchQueue(label: "tvmirror.capture")

    var latestFrame: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// How many pictures macOS has delivered so far (0 = nothing is being recorded).
    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    /// Called on the capture queue with every new picture (used by the mini screen).
    var onFrame: ((CVPixelBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return onFrameHandler }
        set { lock.lock(); onFrameHandler = newValue; lock.unlock() }
    }

    /// Asks ScreenCaptureKit for the screens. Unlike CGPreflightScreenCaptureAccess (which
    /// macOS only updates when the app restarts, and which goes wrong when an old copy of
    /// the app is still listed in System Settings), this is what recording actually needs.
    static func shareableContent() async throws -> SCShareableContent {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.write("shareable content failed: \(error)")
            if (error as? SCStreamError)?.code == .userDeclined
                || (error as NSError).domain == SCStreamError.errorDomain {
                throw ScreenPermissionError()
            }
            throw error
        }
        if content.displays.isEmpty { throw ScreenPermissionError() }   // what macOS gives when not allowed
        return content
    }

    static func canRecord() async -> Bool {
        do { _ = try await shareableContent(); return true } catch { return false }
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        let content = try await Self.shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            Log.write("display \(displayID) not in \(content.displays.map { $0.displayID })")
            throw Discovery.TVError(description: "Couldn't find that screen to record.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 6
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
        } catch {
            Log.write("start capture failed: \(error)")
            if (error as? SCStreamError)?.code == .userDeclined { throw ScreenPermissionError() }
            throw error
        }
        self.stream = stream
        Log.write("recording display \(displayID) at \(width)x\(height)")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        lock.lock(); latest = nil; frames = 0; onFrameHandler = nil; lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        lock.lock()
        latest = pixels
        frames += 1
        let handler = onFrameHandler
        lock.unlock()
        handler?(pixels)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("capture stopped: \(error)")
    }
}

/// Encodes pictures to H.264 with the Mac's video chip, and pads every picture to the
/// same size: older TVs wait for a fixed amount of data before playing, so a still
/// screen (tiny pictures) would otherwise make them wait for many seconds.
final class H264Encoder {
    private var session: VTCompressionSession?
    let fps: Int32
    let bytesPerFrame: Int
    var onFrame: ((Data, Int64, Bool) -> Void)?    // picture (Annex B), timestamp (90 kHz), keyframe

    init?(width: Int32, height: Int32, fps: Int32, bitrate: Int) {
        self.fps = fps
        bytesPerFrame = bitrate / 8 / Int(fps)
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height,
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { return nil }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: Int(Double(bitrate) * 0.8)))
        let limits = [NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ pixels: CVPixelBuffer, index: Int64, pts90k: Int64, forceKeyframe: Bool) {
        guard let session else { return }
        let options = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels,
                                        presentationTimeStamp: CMTime(value: index, timescale: fps),
                                        duration: CMTime(value: 1, timescale: fps),
                                        frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.deliver(sample, pts90k: pts90k)
        }
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private func deliver(_ sample: CMSampleBuffer, pts90k: Int64) {
        guard CMSampleBufferDataIsReady(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)

        var out = Data([0, 0, 0, 1, 0x09, 0xF0])            // access unit delimiter
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {                            // picture settings (SPS, PPS)
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer {
                    out.append(contentsOf: [0, 0, 0, 1])
                    out.append(pointer, count: size)
                }
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var raw = Data(count: length)
        let copied = raw.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return }
        var position = 0                                    // 4-byte lengths -> start codes
        while position + 4 <= raw.count {
            let size = Int(raw[position]) << 24 | Int(raw[position + 1]) << 16
                | Int(raw[position + 2]) << 8 | Int(raw[position + 3])
            position += 4
            guard size > 0, position + size <= raw.count else { break }
            let type = raw[position] & 0x1F
            if type != 9 {                                  // skip the encoder's own delimiters
                out.append(contentsOf: [0, 0, 0, 1])
                out.append(raw[position..<(position + size)])
            }
            position += size
        }
        let fill = bytesPerFrame - out.count - 6            // filler data, thrown away by the TV
        if fill > 0 {
            out.append(contentsOf: [0, 0, 0, 1, 0x0C])
            out.append(Data(repeating: 0xFF, count: fill))
            out.append(0x80)
        }
        onFrame?(out, pts90k, keyframe)
    }
}

/// One mirroring session: records a screen, encodes, packs it and feeds the web server.
final class MirrorSession {
    let tv: TV
    let server: StreamServer
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let fps = 30
    let bitrate = 8_000_000

    private let source = ScreenSource()
    private var encoder: H264Encoder?

    /// Pictures recorded so far; stays 0 if macOS isn't really letting TellyBeam record.
    var framesRecorded: Int { source.frameCount }

    /// Every new picture, for the mini screen (called on the capture queue).
    var onPreviewFrame: ((CVPixelBuffer) -> Void)? {
        get { source.onFrame }
        set { source.onFrame = newValue }
    }
    private let muxer = TSMuxer()
    private let queue = DispatchQueue(label: "tvmirror.pipeline")
    private var timer: DispatchSourceTimer?
    private var startTime = DispatchTime.now()
    private var frameIndex: Int64 = 0
    private var audioPTS: Int64 = 0
    private var forceKeyframe = true
    private static let startOffset: Int64 = 126_000          // timestamps start at 1.4 s
    private static let silence = Data(base64Encoded: "//3kBJlmZndmiHdmdnZ3+22/2tkRAAAAAACqqqqqqqqqqqqvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvn/f9/3/f9/379+/fv379+/fv3333333ve97379+/fv3333333ve973333ve+++973333333//f/9//3ve973ve973ve//7//v/+//7//v/+973ve7u7uti2Pmv+/7/v+/7/v379+/fv379+/fvvvvvvve973v379+/fvvvvvvve973vvvve999973vvvvvvv/+//7//ve973ve973ve9//3//f/9//3//f/973ve93d3dbFsfNf9/3/f9/3/fv379+/fv379+/ffffffe973vfv379+/ffffffe973vfffe977773vfffffff/9//3//e973ve973ve97//v/+//7//v/+//73ve97u7u62LY+a/7/v+/7/v+/fv379+/fv379+++++++973ve/fv379+++++++973ve+++973333ve++++++//7//v/+973ve973ve973//f/9//3//f/9//3ve973d3d1sWx81/3/f9/3/f9+/fv379+/fv37999999973ve9+/fv37999999973ve999973vvvve9999999//3//f/973ve973ve973v/+//7//v/+//7//ve973u7u7rYtj5r/v+/7/v+/79+/fv379+/fv377777773ve979+/fv377777773ve977773vfffe97777777//v/+//73ve973ve973vf/9//3//f/9//3//e973vd3d3WxbHzX/f9/3/f9/379+/fv379+/fv3333333ve97379+/fv3333333ve973333ve+++973333333//f/9//3ve973ve973ve//7//v/+//7//v/+973ve7u7uti2Pmv+/7/v+/7/v379+/fv379+/fvvvvvvve973v379+/fvvvvvvve973vvvve999973vvvvvvv/+//7//ve973ve973ve9//3//f/9//3//f/973ve93d3dbFsfNf9/3/f9/3/fv379+/fv379+/ffffffe973vfv379+/ffffffe973vfffe977773vfffffff/9//3//e973ve973ve97//v/+//7//v/+//73ve97u7u62LY+a/7/v+/7/v+/fv379+/fv379+++++++973ve/fv379+++++++973ve+++973333ve++++++//7//v/+973ve973ve973//f/9//3//f/9//3ve973d3d1sWx81/3/f9/3/f9+/fv379+/fv37999999973ve9+/fv37999999973ve999973vvvve9999999//3//f/973ve973ve973v/+//7//v/+//7//ve973u7u7rYtj5r/v+/7/v+/79+/fv379+/fv377777773ve979+/fv377777773ve977773vfffe97777777//v/+//73ve973ve973vf/9//3//f/9//3//e973vd3d3WxbHzQ")!

    init(tv: TV, server: StreamServer, displayID: CGDirectDisplayID, width: Int, height: Int) {
        self.tv = tv
        self.server = server
        self.displayID = displayID
        self.width = width
        self.height = height
    }

    func start() async throws {
        try await source.start(displayID: displayID, width: width, height: height, fps: fps)
        guard let encoder = H264Encoder(width: Int32(width), height: Int32(height),
                                        fps: Int32(fps), bitrate: bitrate) else {
            await source.stop()
            throw Discovery.TVError(description: "Couldn't start the video encoder.")
        }
        self.encoder = encoder
        let muxer = self.muxer
        let queue = self.queue
        let server = self.server
        muxer.output = { data, keyframe in server.append(data, keyframe: keyframe) }
        encoder.onFrame = { frame, pts, keyframe in
            queue.async { muxer.writeVideo(frame, pts: pts, keyframe: keyframe) }
        }
        startTime = DispatchTime.now()
        audioPTS = Self.startOffset
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        try playOnTV()
    }

    /// Sends a picture 30 times a second, repeating the last one when the screen hasn't
    /// changed (macOS only delivers new pictures when something on screen changes).
    private func tick() {
        let elapsed = Int64(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds)
        let pts = Self.startOffset + elapsed * 9 / 100_000          // nanoseconds -> 90 kHz
        while audioPTS <= pts {                                      // silent sound, 24 ms per frame
            muxer.writeAudio(Self.silence, pts: audioPTS)
            audioPTS += 2160
        }
        guard let pixels = source.latestFrame, let encoder else { return }
        let key = forceKeyframe || frameIndex % Int64(fps) == 0
        forceKeyframe = false
        encoder.encode(pixels, index: frameIndex, pts90k: pts, forceKeyframe: key)
        frameIndex += 1
    }

    /// Starts a fresh "file" and tells the TV to play it (also used to catch up).
    func playOnTV() throws {
        let generation = server.newFile()
        queue.async { self.forceKeyframe = true }
        guard let ip = Discovery.localIP(toward: tv.host) else {
            throw Discovery.TVError(description: "Couldn't work out this Mac's network address.")
        }
        try Discovery.play(tv, url: "http://\(ip):\(server.port)/screen.ts?g=\(generation)")
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        await source.stop()
        encoder?.invalidate()
        encoder = nil
        server.endFile()
        Discovery.stop(tv)
    }
}
