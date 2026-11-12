import AppKit
import CoreVideo
import ScreenCaptureKit
import SwiftUI
import VirtualDisplay

@main
struct TVMirrorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("TellyBeam", systemImage: model.isRunning ? "tv.fill" : "tv") {
            MenuContent(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.status)
        Divider()
        if model.tvs.isEmpty {
            Text("No TV found yet")
        } else {
            Picker("TV", selection: $model.selectedName) {
                ForEach(model.tvs, id: \.name) { tv in Text(tv.name).tag(tv.name) }
            }
        }
        Button("Search for TVs again") { model.search() }
        Divider()
        Button("Show my screen on the TV") { model.showMyScreen() }
            .disabled(model.selectedTV == nil || model.busy)
        Button("Use the TV as an extra screen") { model.useExtraScreen() }
            .disabled(model.selectedTV == nil || model.busy)
        if model.mode == .extend {
            Button(model.previewVisible ? "Hide mini screen" : "Show mini screen") { model.toggleMiniScreen() }
        }
        if model.isRunning {
            Button("Catch up (if the TV falls behind)") { model.catchUp() }
            Button("Stop") { model.stop() }
        }
        if model.needsPermission {
            Divider()
            Button("Open Screen Recording settings") { model.openScreenRecordingSettings() }
            Button("Restart TellyBeam") { model.restart() }
            Button("Reset permission (if it keeps asking)") { model.resetPermission() }
        }
        Divider()
        Button("Open TellyBeam window") { model.showWindow() }
        Button("Quit TellyBeam") { model.quit() }
    }
}

/// The TellyBeam window (opens at launch, so it's obvious the app is running even when
/// the menu bar is too full to show the icon).
struct ControlPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TellyBeam").font(.title2).bold()
            Text(model.status)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.tvs.isEmpty {
                Text("No TV found yet")
            } else {
                Picker("TV", selection: $model.selectedName) {
                    ForEach(model.tvs, id: \.name) { tv in Text(tv.name).tag(tv.name) }
                }
                .pickerStyle(.menu)
            }
            Button("Search for TVs again") { model.search() }
            Divider()
            Button("Show my screen on the TV") { model.showMyScreen() }
                .disabled(model.selectedTV == nil || model.busy)
            Button("Use the TV as an extra screen") { model.useExtraScreen() }
                .disabled(model.selectedTV == nil || model.busy)
            if model.mode == .extend {
                Button(model.previewVisible ? "Hide mini screen" : "Show mini screen") { model.toggleMiniScreen() }
            }
            if model.isRunning {
                HStack {
                    Button("Catch up (if the TV falls behind)") { model.catchUp() }
                    Button("Stop") { model.stop() }
                }
            }
            if model.needsPermission {
                Divider()
                Text("Screen Recording permission").bold()
                Text("1. Turn on TellyBeam in Screen & System Audio Recording.\n"
                     + "2. Click Restart TellyBeam (closing the window isn't enough).\n"
                     + "Still asking after that? Click Reset permission, allow it once more, then restart.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Settings") { model.openScreenRecordingSettings() }
                    Button("Restart TellyBeam") { model.restart() }
                        .keyboardShortcut(.defaultAction)
                    Button("Reset permission") { model.resetPermission() }
                }
            }
            Divider()
            Text("TellyBeam also has a TV icon in the menu bar (top right). Closing this window "
                 + "keeps it running; open TellyBeam again to bring the window back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit TellyBeam") { model.quit() }
        }
        .padding(20)
        .frame(width: 400)
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Mode { case mirror, extend }

    @Published var tvs: [TV] = []
    @Published var selectedName = ""
    @Published var status = "Starting..."
    @Published var mode: Mode?
    @Published var previewVisible = false
    @Published var busy = false
    @Published var needsPermission = false

    private let server = StreamServer()
    private var session: MirrorSession?
    private var virtualDisplay: TVVirtualDisplay?
    private var preview: TVPreviewWindow?
    private var window: NSWindow?
    private var watchdog: Task<Void, Never>?
    private var askedForPermission = false     // macOS's own prompt only once per launch
    private static let showWindowNotice = Notification.Name("io.github.nizarhalim05.tvmirror.show")

    var isRunning: Bool { mode != nil }
    var selectedTV: TV? { tvs.first { $0.name == selectedName } ?? tvs.first }

    init() {
        // Already running? Ask that copy to show its window, and quit this one.
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(Self.showWindowNotice, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            others.first?.activate(options: [])
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showWindowNotice, object: nil,
                                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showWindow() }
        }
        signal(SIGPIPE, SIG_IGN)
        do {
            try server.start()
        } catch {
            status = "\(error)"
        }
        search()
        DispatchQueue.main.async { self.showWindow() }
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "TellyBeam"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: ControlPanel(model: self))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func search() {
        status = "Looking for TVs on your Wi-Fi..."
        Task.detached {
            let found = Discovery.search()
            await MainActor.run {
                self.tvs = found
                if !found.contains(where: { $0.name == self.selectedName }) {
                    self.selectedName = found.first?.name ?? ""
                }
                if found.isEmpty {
                    self.status = "No TV found. Is it on, and on the same Wi-Fi?"
                } else if self.mode == nil {
                    self.status = "Ready"
                }
            }
        }
    }

    // MARK: Show my screen

    func showMyScreen() {
        guard let tv = selectedTV else { return }
        Task {
            await stopEverything()
            guard await checkPermission() else { return }
            let display = CGMainDisplayID()
            let bounds = CGDisplayBounds(display)
            let height = 1080
            var width = Int((Double(height) * bounds.width / max(bounds.height, 1)).rounded())
            width -= width % 2
            await start(tv: tv, displayID: display, width: width, height: height, mode: .mirror,
                        success: "Showing your screen on \(tv.name)")
        }
    }

    // MARK: Extra screen

    func useExtraScreen() {
        guard let tv = selectedTV else { return }
        Task {
            await stopEverything()
            // Check before creating the screen, so it doesn't appear and vanish again
            guard await checkPermission() else { return }
            busy = true
            status = "Creating the extra screen... If macOS asks how to use it, choose Extend."
            let display = TVVirtualDisplay(width: 1920, height: 1080)
            virtualDisplay = display
            display.start(withTimeout: 120) { [weak self] displayID, message in
                guard let self else { return }
                Task { @MainActor in
                    guard displayID != 0 else {
                        self.busy = false
                        self.virtualDisplay = nil
                        self.status = message ?? "Couldn't create the extra screen."
                        Log.write("extra screen failed: \(message ?? "-")")
                        return
                    }
                    Log.write("extra screen online: \(displayID)")
                    let success = "Showing the extra screen on \(tv.name). Move a window there with its "
                        + "green button > Move to TellyBeam Display."
                    guard await self.start(tv: tv, displayID: displayID, width: 1920, height: 1080,
                                           mode: .extend, success: success),
                          let session = self.session else { return }
                    let preview = TVPreviewWindow(displayID: displayID, width: 1920, height: 1080)
                    self.previewVisible = preview.start()
                    self.preview = preview
                    session.onPreviewFrame = { [weak preview] pixels in
                        guard let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
                        DispatchQueue.main.async { preview?.showSurface(surface) }
                    }
                }
            }
        }
    }

    func toggleMiniScreen() {
        guard let preview else { return }
        if preview.isVisible { preview.hide() } else { preview.show() }
        previewVisible = preview.isVisible
    }

    // MARK: Running

    /// Starts recording and tells the TV to play. Returns false if it didn't start.
    @discardableResult
    private func start(tv: TV, displayID: CGDirectDisplayID, width: Int, height: Int, mode: Mode,
                       success: String) async -> Bool {
        busy = true
        status = "Starting..."
        let session = MirrorSession(tv: tv, server: server, displayID: displayID, width: width, height: height)
        do {
            try await session.start()
        } catch {
            await session.stop()
            virtualDisplay?.stop()
            virtualDisplay = nil
            busy = false
            Log.write("start failed: \(error)")
            if error is ScreenPermissionError {
                askForPermission()
            } else {
                let reason = error is Discovery.TVError ? String(describing: error) : error.localizedDescription
                status = "Couldn't start: \(reason)"
            }
            return false
        }
        self.session = session
        self.mode = mode
        needsPermission = false
        busy = false
        status = "Connecting to \(tv.name)... the TV takes a few seconds to start."
        watch(session, tv: tv, success: success)
        return true
    }

    /// Only says "Showing" once the TV is really downloading the picture, and explains
    /// what's wrong when macOS sends no picture or the TV never asks for it.
    private func watch(_ session: MirrorSession, tv: TV, success: String) {
        watchdog?.cancel()
        let startBytes = server.deliveredBytes
        watchdog = Task { [weak self] in
            var waited = 0.0
            var warnedNoPicture = false
            while !Task.isCancelled && waited < 30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 0.5
                guard let self, self.session === session else { return }
                let frames = session.framesRecorded
                let bytes = self.server.deliveredBytes - startBytes
                if frames > 0 && bytes > 0 {
                    Log.write("TV is downloading: \(bytes) bytes after \(waited) s, \(frames) pictures")
                    self.status = success
                    return
                }
                if frames == 0 && waited >= 4 && !warnedNoPicture {
                    warnedNoPicture = true
                    Log.write("no pictures from macOS after \(waited) s")
                    self.needsPermission = true
                    self.status = "macOS isn't giving TellyBeam any picture, so the TV will stay blank. "
                        + "This usually means Screen Recording is blocked: click Reset permission, allow "
                        + "TellyBeam again, then click Restart TellyBeam."
                }
            }
            guard let self, !Task.isCancelled, self.session === session else { return }
            let frames = session.framesRecorded
            Log.write("after 30 s: \(frames) pictures, TV downloaded \(self.server.deliveredBytes - startBytes) bytes")
            if frames == 0 { return }    // already explained above
            self.status = "\(tv.name) hasn't fetched the picture. Check the TV is on the same Wi-Fi and "
                + "not showing an error, then click Catch up. If your Mac's firewall is on, allow "
                + "TellyBeam to accept incoming connections (System Settings > Network > Firewall)."
        }
    }

    // MARK: Screen Recording permission

    /// True if TellyBeam can record now. Otherwise explains what to do.
    private func checkPermission() async -> Bool {
        if await ScreenSource.canRecord() {
            needsPermission = false
            return true
        }
        Log.write("screen recording not allowed (preflight says \(CGPreflightScreenCaptureAccess()))")
        askForPermission()
        return false
    }

    private func askForPermission() {
        needsPermission = true
        if !askedForPermission {
            // macOS's own "allow screen recording" message. It only appears once, so the
            // next time the Settings page is opened directly instead of asking again.
            askedForPermission = true
            CGRequestScreenCaptureAccess()
        } else {
            openScreenRecordingSettings()
        }
        status = "TellyBeam needs Screen Recording permission. Turn on TellyBeam in System Settings > "
            + "Privacy & Security > Screen & System Audio Recording, then click Restart TellyBeam."
        showWindow()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quits and opens TellyBeam again: macOS only applies a new Screen Recording
    /// permission to a freshly started app. (Opening TellyBeam while it's still running
    /// just brings back this copy, which is why "quit and reopen" often didn't work.)
    func restart() {
        Task {
            await stopEverything()
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                                  "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
            do {
                try relaunch.run()
            } catch {
                status = "Couldn't restart by itself. Click Quit TellyBeam, then open it again."
                return
            }
            Log.write("restarting")
            NSApplication.shared.terminate(nil)
        }
    }

    /// Clears TellyBeam's Screen Recording entry. Needed when System Settings shows TellyBeam
    /// switched on but macOS still says no: the entry belongs to an older download of the
    /// app (each new build has a new signature), so switching it on does nothing.
    func resetPermission() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "io.github.nizarhalim05.tvmirror"]
        do {
            try reset.run()
            reset.waitUntilExit()
            Log.write("tccutil reset ScreenCapture: \(reset.terminationStatus)")
        } catch {
            Log.write("tccutil failed: \(error)")
        }
        needsPermission = true
        askedForPermission = true
        CGRequestScreenCaptureAccess()
        openScreenRecordingSettings()
        status = "Permission cleared. Turn on TellyBeam in the Settings window (add it with + if it's not "
            + "listed), then click Restart TellyBeam."
    }

    func catchUp() {
        guard let session else { return }
        Task.detached {
            do { try session.playOnTV() } catch { Log.write("catch up failed: \(error)") }
        }
    }

    func stop() {
        Task { await stopEverything(); status = "Stopped" }
    }

    private func stopEverything() async {
        watchdog?.cancel()
        watchdog = nil
        session?.onPreviewFrame = nil
        preview?.stop()
        preview = nil
        previewVisible = false
        if let session { await session.stop() }
        session = nil
        virtualDisplay?.stop()
        virtualDisplay = nil
        mode = nil
    }

    func quit() {
        Task {
            await stopEverything()
            NSApplication.shared.terminate(nil)
        }
    }
}
