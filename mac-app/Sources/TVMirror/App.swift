import AppKit
import SwiftUI
import VirtualDisplay

@main
struct TVMirrorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("TV Mirror", systemImage: model.isRunning ? "tv.fill" : "tv") {
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
        Divider()
        Button("Open TV Mirror window") { model.showWindow() }
        Button("Quit TV Mirror") { model.quit() }
    }
}

/// The TV Mirror window (opens at launch, so it's obvious the app is running even when
/// the menu bar is too full to show the icon).
struct ControlPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TV Mirror").font(.title2).bold()
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
            Divider()
            Text("TV Mirror also has a TV icon in the menu bar (top right). Closing this window "
                 + "keeps it running; open TV Mirror again to bring the window back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit TV Mirror") { model.quit() }
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

    private let server = StreamServer()
    private var session: MirrorSession?
    private var virtualDisplay: TVVirtualDisplay?
    private var preview: TVPreviewWindow?
    private var window: NSWindow?
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
            w.title = "TV Mirror"
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
            let display = CGMainDisplayID()
            let bounds = CGDisplayBounds(display)
            let height = 1080
            var width = Int((Double(height) * bounds.width / max(bounds.height, 1)).rounded())
            width -= width % 2
            await start(tv: tv, displayID: display, width: width, height: height, mode: .mirror)
        }
    }

    // MARK: Extra screen

    func useExtraScreen() {
        guard let tv = selectedTV else { return }
        Task {
            await stopEverything()
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
                        return
                    }
                    await self.start(tv: tv, displayID: displayID, width: 1920, height: 1080, mode: .extend)
                    guard self.mode == .extend else { return }
                    let preview = TVPreviewWindow(displayID: displayID, width: 1920, height: 1080)
                    self.previewVisible = preview.start()
                    self.preview = preview
                    self.status = "Showing the extra screen on \(tv.name). Move a window there with its "
                        + "green button > Move to TV Mirror Display."
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

    private func start(tv: TV, displayID: CGDirectDisplayID, width: Int, height: Int, mode: Mode) async {
        busy = true
        status = "Starting..."
        let session = MirrorSession(tv: tv, server: server, displayID: displayID, width: width, height: height)
        do {
            try await session.start()
            self.session = session
            self.mode = mode
            status = "Showing \(mode == .mirror ? "your screen" : "the extra screen") on \(tv.name)"
        } catch {
            await session.stop()
            virtualDisplay?.stop()
            virtualDisplay = nil
            if "\(error)".lowercased().contains("declin") || "\(error)".lowercased().contains("permission")
                || (error as NSError).domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
                status = "Allow Screen Recording for TV Mirror in System Settings, then try again."
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                status = "\(error)"
            }
            Log.write("start failed: \(error)")
        }
        busy = false
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
