import Cocoa
import SwiftUI
import Combine
import AVKit
import ServiceManagement
import UserNotifications

// MARK: - FL511 endpoints

enum FL511 {
    // Public drawbridge list (same data the fl511.com map uses). Brickell Avenue Bridge is item 253.
    static let bridgeId = "253"
    static let bridgeListURL = URL(string: "https://fl511.com/List/GetData/Bridge?query=%7B%22columns%22%3A%5B%7B%22data%22%3Anull%2C%22name%22%3A%22%22%7D%5D%2C%22start%22%3A0%2C%22length%22%3A50%2C%22search%22%3A%7B%22value%22%3A%22brickell%22%7D%7D&lang=en-US")!

    // Brickell Bridge CCTV: camera image 5359. Stream needs a short lived token and a fl511 Referer.
    static let cameraImageId = "5359"
    static let streamBase = "https://dis-se1.divas.cloud:8200/chan-12074_h/index.m3u8"
    static let videoTokenURL = URL(string: "https://fl511.com/Camera/GetVideoUrl?imageId=\(cameraImageId)")!
    static let secureTokenURL = URL(string: "https://divas.cloud/VDS-API/SecureTokenUri/GetSecureTokenUriBySourceId")!
    static let snapshotURL = URL(string: "https://fl511.com/map/Cctv/\(cameraImageId)")!
    static let camerasPage = URL(string: "https://fl511.com/my511/cameras?start=0&length=10&order%5Bi%5D=1&order%5Bdir%5D=asc")!
    static let referer = "https://fl511.com/"

    /// Uncached GET with a browser User-Agent, which FL511 expects.
    static func get(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return req
    }
}

enum BridgeState: Equatable {
    case unknown, up, down

    var title: String {
        switch self {
        case .up: return "Bridge UP"
        case .down: return "Bridge DOWN"
        case .unknown: return "Status unknown"
        }
    }

    var dotColor: Color {
        switch self {
        case .up: return .red
        case .down: return .green
        case .unknown: return .gray
        }
    }

    var subtitle: String {
        switch self {
        case .up: return "Raised. Closed to traffic."
        case .down: return "Lowered. Open to traffic."
        case .unknown: return "Can't reach FL511 right now."
        }
    }
}

// MARK: - Bridge status polling

final class BridgeModel: ObservableObject {
    @Published var state: BridgeState = .unknown
    @Published var since: Date?
    @Published var lastChecked: Date?

    var onChange: ((BridgeState, BridgeState) -> Void)?
    private var timer: Timer?
    private var hasLoaded = false

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        URLSession.shared.dataTask(with: FL511.get(FL511.bridgeListURL)) { [weak self] data, _, _ in
            let parsed = data.flatMap(Self.parse)
            DispatchQueue.main.async { self?.apply(parsed) }
        }.resume()
    }

    private static func parse(_ data: Data) -> (BridgeState, Date?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else { return nil }
        let row = rows.first { ($0["DT_RowId"] as? String) == FL511.bridgeId }
            ?? rows.first { (($0["name"] as? String) ?? "").localizedCaseInsensitiveContains("Brickell") }
        guard let row, let status = (row["status"] as? String)?.lowercased() else { return nil }
        let state: BridgeState
        if status.contains("up") {
            state = .up
        } else if status.contains("down") {
            state = .down
        } else {
            state = .unknown
        }
        let since = (row["lastNotificationTime"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        return (state, since)
    }

    private func apply(_ parsed: (BridgeState, Date?)?) {
        lastChecked = Date()
        guard let (newState, newSince) = parsed else {
            // Keep the last known state on a transient failure.
            if !hasLoaded { state = .unknown }
            return
        }
        let old = state
        since = newSince
        if newState != old {
            state = newState
            if hasLoaded { onChange?(old, newState) }
        }
        hasLoaded = true
    }
}

// MARK: - Menu bar icon (drawn, animated)

enum BridgeIcon {
    static let size = NSSize(width: 26, height: 18)
    static let openAngle: CGFloat = 62

    /// progress 0 = deck down, 1 = leaves fully raised.
    static func image(progress: CGFloat, state: BridgeState) -> NSImage {
        let tint: NSColor? = state == .up ? NSColor.systemRed : nil
        let img = NSImage(size: size, flipped: false) { _ in
            let color = tint ?? .black
            color.setFill()
            color.setStroke()

            // Water line
            let water = NSBezierPath()
            water.lineWidth = 1.2
            water.move(to: NSPoint(x: 1, y: 2.5))
            var x: CGFloat = 1
            while x < 25 {
                water.curve(to: NSPoint(x: x + 4, y: 2.5),
                            controlPoint1: NSPoint(x: x + 1.3, y: 4),
                            controlPoint2: NSPoint(x: x + 2.7, y: 1))
                x += 4
            }
            water.stroke()

            // Piers with little towers
            NSBezierPath(rect: NSRect(x: 2, y: 4, width: 4, height: 6)).fill()
            NSBezierPath(rect: NSRect(x: 20, y: 4, width: 4, height: 6)).fill()
            NSBezierPath(rect: NSRect(x: 2.5, y: 10, width: 2, height: 3)).fill()
            NSBezierPath(rect: NSRect(x: 21.5, y: 10, width: 2, height: 3)).fill()

            // Bascule leaves pivoting at the inner pier edges
            let angle = openAngle * max(0, min(1, progress)) * .pi / 180
            let len: CGFloat = 7
            for (pivot, dir) in [(NSPoint(x: 6, y: 9.2), CGFloat(1)), (NSPoint(x: 20, y: 9.2), CGFloat(-1))] {
                let leaf = NSBezierPath()
                leaf.lineWidth = 2.2
                leaf.lineCapStyle = .round
                leaf.move(to: pivot)
                leaf.line(to: NSPoint(x: pivot.x + dir * len * cos(angle), y: pivot.y + len * sin(angle)))
                leaf.stroke()
            }

            if state == .unknown {
                let q = NSAttributedString(string: "?", attributes: [.font: NSFont.boldSystemFont(ofSize: 8), .foregroundColor: NSColor.black])
                q.draw(at: NSPoint(x: 11, y: 7))
            }
            return true
        }
        img.isTemplate = (tint == nil)
        return img
    }
}

final class IconAnimator {
    private weak var button: NSStatusBarButton?
    private var progress: CGFloat = 0
    private var target: CGFloat = 0
    private var state: BridgeState = .unknown
    private var timer: Timer?

    init(button: NSStatusBarButton) {
        self.button = button
        render()
    }

    func set(_ newState: BridgeState) {
        state = newState
        target = newState == .up ? 1 : 0
        timer?.invalidate()
        // ~1.2s raise/lower, 30 fps
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            let step: CGFloat = 1.0 / 36
            if abs(self.target - self.progress) <= step {
                self.progress = self.target
                t.invalidate()
            } else {
                self.progress += self.target > self.progress ? step : -step
            }
            self.render()
        }
        render()
    }

    private func render() {
        // Ease in-out so the leaves feel mechanical, not linear.
        let eased = progress * progress * (3 - 2 * progress)
        button?.image = BridgeIcon.image(progress: eased, state: state)
        button?.toolTip = "Brickell Bridge: \(state.title)"
    }
}

// MARK: - Live camera

final class CameraModel: ObservableObject {
    let player = AVPlayer()
    @Published var message: String? = "Loading live cam…"
    @Published var snapshot: NSImage?

    private var statusObs: NSKeyValueObservation?
    private var failObs: NSObjectProtocol?
    private var retries = 0
    private var active = false
    private var watchdog: Timer?

    init() {
        player.isMuted = true
        // FL511 starts a fresh transcode per viewer, so playback sits right at the live edge.
        // AVPlayer's own stall handling never resumes there; the watchdog below manages the buffer instead.
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func start() {
        active = true
        retries = 0
        message = "Loading live cam…"
        loadSnapshot()
        loadStream()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        active = false
        watchdog?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObs = nil
        if let failObs { NotificationCenter.default.removeObserver(failObs) }
    }

    private func loadSnapshot() {
        URLSession.shared.dataTask(with: FL511.get(FL511.snapshotURL)) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async { self?.snapshot = img }
        }.resume()
    }

    /// GetVideoUrl -> {token, sourceId, systemSourceId}; POST that to divas.cloud -> "?token=..." suffix.
    private func loadStream() {
        fetchTokenSuffix { [weak self] suffix in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                guard let suffix, let url = URL(string: FL511.streamBase + suffix) else {
                    return self.fail("Live cam unavailable. Showing latest snapshot.")
                }
                let asset = AVURLAsset(url: url, options: [
                    "AVURLAssetHTTPHeaderFieldsKey": ["Referer": FL511.referer, "Origin": "https://fl511.com"],
                ])
                let item = AVPlayerItem(asset: asset)
                self.observe(item)
                self.player.replaceCurrentItem(with: item)
            }
        }
    }

    private func fetchTokenSuffix(_ done: @escaping (String?) -> Void) {
        URLSession.shared.dataTask(with: FL511.get(FL511.videoTokenURL)) { data, _, _ in
            guard let data, (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return done(nil) }
            var post = URLRequest(url: FL511.secureTokenURL, timeoutInterval: 10)
            post.httpMethod = "POST"
            post.httpBody = data
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            post.setValue(FL511.referer, forHTTPHeaderField: "Referer")
            URLSession.shared.dataTask(with: post) { data, _, _ in
                let raw = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
                done(raw?.hasPrefix("?") == true ? raw : nil)
            }.resume()
        }.resume()
    }

    /// Hold until ~5s is buffered ahead, play, and pause again if we catch up to the live edge.
    private func tick() {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let now = player.currentTime().seconds
        let bufferedEnd = item.loadedTimeRanges.map { $0.timeRangeValue.end.seconds }.max() ?? 0
        let ahead = bufferedEnd - now
        if player.rate == 0, ahead >= 5 {
            player.play()
            message = nil
        } else if player.rate > 0, ahead < 0.3 {
            player.pause()
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusObs = item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .failed { self?.retry() }
            }
        }
        if let failObs { NotificationCenter.default.removeObserver(failObs) }
        failObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.retry()
        }
    }

    // Tokens expire; on any failure grab a fresh one and reload.
    private func retry() {
        guard active else { return }
        retries += 1
        guard retries <= 3 else { return fail("Live cam unavailable. Showing latest snapshot.") }
        message = "Reconnecting…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.loadStream() }
    }

    private func fail(_ text: String) {
        message = text
        loadSnapshot()
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = true
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

// MARK: - Popover UI

struct PopoverView: View {
    @ObservedObject var bridge: BridgeModel
    @ObservedObject var camera: CameraModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(bridge.state.dotColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brickell Avenue Bridge · \(bridge.state.title)").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            ZStack {
                Color.black
                if let snap = camera.snapshot, camera.message != nil {
                    Image(nsImage: snap).resizable().aspectRatio(contentMode: .fit)
                }
                PlayerView(player: camera.player).opacity(camera.message == nil ? 1 : 0)
                if let msg = camera.message, !msg.isEmpty {
                    Text(msg).font(.caption).padding(6)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(8)
                }
            }
            .frame(width: 384, height: 216)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Open FL511 Cameras") { NSWorkspace.shared.open(FL511.camerasPage) }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var subtitle: String {
        guard let since = bridge.since, bridge.state != .unknown else { return bridge.state.subtitle }
        let f = DateFormatter()
        f.timeStyle = .short
        let mins = Int(Date().timeIntervalSince(since) / 60)
        let ago: String
        if mins < 1 {
            ago = "just now"
        } else if mins < 60 {
            ago = "\(mins) min ago"
        } else {
            ago = "\(mins / 60)h \(mins % 60)m ago"
        }
        return "\(bridge.state.subtitle) Since \(f.string(from: since)) (\(ago))."
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var animator: IconAnimator!
    private let popover = NSPopover()
    private let bridge = BridgeModel()
    private let camera = CameraModel()
    private var stateSink: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover)
        button.target = self
        animator = IconAnimator(button: button)

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(bridge: bridge, camera: camera))

        stateSink = bridge.$state.sink { [weak self] state in self?.animator.set(state) }
        bridge.onChange = { _, new in Self.notify(new) }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        bridge.start()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            bridge.poll()
            camera.start()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        camera.stop()
    }

    private static func notify(_ state: BridgeState) {
        guard state != .unknown else { return }
        let content = UNMutableNotificationContent()
        content.title = "Brickell Bridge is \(state == .up ? "UP" : "DOWN")"
        content.body = state.subtitle
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
