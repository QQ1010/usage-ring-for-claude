// Usage Ring for Claude（非官方工具，與 Anthropic 無關）：在 Mac 上常駐顯示 claude.ai Settings > Usage 的用量。
// - 選單列：小圓環 + Current session %
// - 懸浮圓環：永遠浮在最上層（任何 app、桌面、全螢幕都看得到），可拖曳，hover 看詳情，點擊開啟用量設定
// 資料來源：app 內建的 claude.ai 登入（WebKit），用同一個 session 呼叫網頁版用量頁面所用的 API。
import AppKit
import ServiceManagement
import WebKit

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let projectURL = URL(string: "https://github.com/QQ1010/usage-ring-for-claude")!
let settingsURL = URL(string: "https://claude.ai/settings/usage")!
let loginURL = URL(string: "https://claude.ai/login")!
// 輕量的 claude.ai 同源頁面，讓背景 WebView 能以登入身分 fetch API
let anchorURL = URL(string: "https://claude.ai/api/organizations")!
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
let pollInterval: TimeInterval = 60
let ringSize: CGFloat = 40

// MARK: - 資料

struct Window {
    let utilization: Double // 0–100
    let resetsAt: Date?
}

struct Usage {
    var session: Window?      // five_hour：Current session
    var weekly: Window?       // seven_day：Weekly · All models
    var weeklyOpus: Window?
    var weeklySonnet: Window?
}

enum UsageState {
    case loading
    case signedOut
    case failed(String)
    case ok(Usage, Date)
}

func parseWindow(_ any: Any?) -> Window? {
    guard let d = any as? [String: Any], let u = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
    var reset: Date?
    if let s = d["resets_at"] as? String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        reset = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    return Window(utilization: u, resetsAt: reset)
}

func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    let mins = Int((date.timeIntervalSinceNow / 60).rounded())
    if mins <= 0 { return "即將重置" }
    let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
    if d > 0 { return "\(d) 天 \(h) 小時後重置" }
    if h > 0 { return "\(h) 小時 \(m) 分後重置" }
    return "\(m) 分後重置"
}

func color(for pct: Double) -> NSColor {
    pct >= 90 ? .systemRed : pct >= 70 ? .systemOrange : .systemGreen
}

// MARK: - 抓取（在 claude.ai 同源的隱藏 WebView 裡 fetch，沿用登入 cookie）

final class UsageFetcher: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: config)
        webView.customUserAgent = safariUA
        super.init()
        webView.navigationDelegate = self
        reload()
    }

    func reload() {
        ready = false
        webView.load(URLRequest(url: anchorURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { markReady() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { markReady() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { markReady() }

    private func markReady() {
        ready = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    @MainActor
    func waitReady() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 先拿組織列表，再找出有用量資料的那個組織
    @MainActor
    func fetch() async -> UsageState {
        await waitReady()
        let js = """
        const get = async (path) => {
          const r = await fetch(path, { credentials: 'include', headers: { 'Accept': 'application/json' } });
          return { status: r.status, body: r.ok ? await r.json() : null };
        };
        const orgs = await get('/api/organizations');
        if (orgs.status === 401 || orgs.status === 403) return { state: 'signedOut' };
        if (!orgs.body) return { state: 'error', message: 'organizations ' + orgs.status };
        const list = Array.isArray(orgs.body) ? orgs.body : [];
        const lastActive = (document.cookie.match(/(?:^|; )lastActiveOrg=([^;]+)/) || [])[1];
        list.sort((a, b) => (b.uuid === lastActive) - (a.uuid === lastActive));
        let last = 'no organization';
        for (const org of list) {
          const u = await get('/api/organizations/' + org.uuid + '/usage');
          if (u.body && (u.body.five_hour || u.body.seven_day)) return { state: 'ok', usage: u.body, org: org.name || '' };
          last = 'usage ' + u.status;
        }
        return { state: 'error', message: last };
        """
        do {
            let raw = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
            guard let result = raw as? [String: Any], let state = result["state"] as? String else {
                return .failed("無法解析回應")
            }
            switch state {
            case "signedOut":
                return .signedOut
            case "ok":
                let u = result["usage"] as? [String: Any] ?? [:]
                return .ok(Usage(session: parseWindow(u["five_hour"]),
                                 weekly: parseWindow(u["seven_day"]),
                                 weeklyOpus: parseWindow(u["seven_day_opus"]),
                                 weeklySonnet: parseWindow(u["seven_day_sonnet"])), Date())
            default:
                return .failed(result["message"] as? String ?? "未知錯誤")
            }
        } catch {
            // 頁面可能被導去登入或 Cloudflare 驗證：重新載入，下次再試
            reload()
            return .failed("連線失敗，稍後重試")
        }
    }
}

// MARK: - 圓環繪製

func drawRing(in rect: NSRect, percent: Double?, lineWidth: CGFloat, track: NSColor) {
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
    let t = NSBezierPath()
    t.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    t.lineWidth = lineWidth
    track.setStroke()
    t.stroke()
    guard let pct = percent else { return }
    let p = min(max(pct, 0), 100)
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * p / 100, clockwise: true)
    arc.lineWidth = lineWidth
    arc.lineCapStyle = .round
    color(for: p).setStroke()
    arc.stroke()
}

func menuBarImage(percent: Double?) -> NSImage {
    let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        drawRing(in: rect.insetBy(dx: 1, dy: 1), percent: percent, lineWidth: 2.6,
                 track: NSColor.labelColor.withAlphaComponent(0.25))
        return true
    }
    img.isTemplate = false
    return img
}

final class RingView: NSView {
    var percent: Double? { didSet { needsDisplay = true } }
    var mark: String? { didSet { needsDisplay = true } } // 非數字狀態：「…」「!」「登入」
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onMoved: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private var downPoint: NSPoint?
    private var dragged = false

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 4)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: rect).fill()
        drawRing(in: rect.insetBy(dx: 3, dy: 3), percent: percent, lineWidth: 4, track: .tertiaryLabelColor)

        let text = mark ?? percent.map { "\(Int($0.rounded()))" } ?? "…"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: text.count > 2 ? 9 : 11, weight: .semibold),
            .foregroundColor: mark == "!" ? NSColor.systemRed : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        onHover?(false)
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + dx, y: window.frame.origin.y + dy))
        downPoint = now
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
        downPoint = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKNavigationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var ring: RingView!
    var tip: NSPanel!
    var tipLabel: NSTextField!
    var fetcher: UsageFetcher!
    var loginWindow: NSWindow?
    var state: UsageState = .loading
    var lastUsage: (Usage, Date)?

    var showFloating: Bool {
        get { UserDefaults.standard.object(forKey: "showFloating") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showFloating") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        panel = makePanel(size: NSSize(width: ringSize, height: ringSize))
        ring = RingView(frame: NSRect(x: 0, y: 0, width: ringSize, height: ringSize))
        ring.onClick = { [weak self] in self?.ringClicked() }
        ring.onHover = { [weak self] on in on ? self?.showTip() : self?.tip.orderOut(nil) }
        ring.onMoved = { [weak self] in self?.savePosition() }
        ring.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        panel.contentView = ring
        restorePosition()
        if showFloating { panel.orderFrontRegardless() }

        tip = makePanel(size: NSSize(width: 260, height: 100))
        tipLabel = NSTextField(labelWithString: "")
        tipLabel.font = .systemFont(ofSize: 12)
        tipLabel.maximumNumberOfLines = 0
        let box = NSVisualEffectView()
        box.material = .popover
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.addSubview(tipLabel)
        tip.contentView = box

        fetcher = UsageFetcher()
        render()
        refreshNow()
        Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        // 醒來時立刻更新
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshNow), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func makePanel(size: NSSize) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar // 高於一般視窗，切到任何 app 都看得到
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    // MARK: 更新

    @objc func refreshNow() {
        Task { @MainActor in
            let s = await fetcher.fetch()
            if case .ok(let u, let at) = s { lastUsage = (u, at) }
            state = s
            render()
            if case .ok = s, let w = loginWindow {
                w.close()
                loginWindow = nil
            }
        }
    }

    func render() {
        let pct = lastUsage?.0.session?.utilization
        switch state {
        case .signedOut:
            ring.percent = nil
            ring.mark = "登入"
            statusItem.button?.title = " 登入"
        case .failed where lastUsage == nil:
            ring.percent = nil
            ring.mark = "!"
            statusItem.button?.title = " !"
        case .loading where lastUsage == nil:
            ring.percent = nil
            ring.mark = nil
            statusItem.button?.title = " …"
        default:
            ring.percent = pct
            ring.mark = pct == nil ? "–" : nil
            statusItem.button?.title = pct.map { " \(Int($0.rounded()))%" } ?? " –"
        }
        statusItem.button?.image = menuBarImage(percent: pct)
        if tip.isVisible { showTip() }
    }

    func detailLines() -> [String] {
        var lines: [String] = []
        if let (u, at) = lastUsage {
            func add(_ title: String, _ w: Window?) {
                guard let w else { return }
                let r = resetText(w.resetsAt)
                lines.append("\(title)：\(Int(w.utilization.rounded()))% 已使用" + (r.isEmpty ? "" : "（\(r)）"))
            }
            add("Current session", u.session)
            add("Weekly · All models", u.weekly)
            add("Weekly · Opus", u.weeklyOpus)
            add("Weekly · Sonnet", u.weeklySonnet)
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            lines.append("更新於 \(f.string(from: at))")
        }
        switch state {
        case .signedOut: lines.append("尚未登入 claude.ai：點擊圓環登入")
        case .failed(let m): lines.append("⚠︎ 更新失敗：\(m)")
        case .loading where lastUsage == nil: lines.append("讀取中…")
        default: break
        }
        return lines
    }

    func showTip() {
        tipLabel.stringValue = (detailLines() + ["點擊開啟用量設定 · 可拖曳 · 右鍵選單"]).joined(separator: "\n")
        let pad: CGFloat = 10
        let fit = tipLabel.sizeThatFits(NSSize(width: 320, height: 1000))
        tipLabel.frame = NSRect(x: pad, y: pad, width: fit.width, height: fit.height)
        let size = NSSize(width: fit.width + pad * 2, height: fit.height + pad * 2)
        let rf = panel.frame
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        var x = rf.minX - size.width - 6
        if x < screen.minX { x = rf.maxX + 6 }
        var y = rf.maxY - size.height
        if y < screen.minY { y = rf.minY }
        tip.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        tip.orderFrontRegardless()
    }

    // MARK: 選單

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu().items.forEach { item in
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for line in detailLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item("開啟用量設定", #selector(openSettings)))
        menu.addItem(item("立即更新", #selector(refreshNow), key: "r"))
        menu.addItem(.separator())
        let floating = item("顯示懸浮圓環", #selector(toggleFloating))
        floating.state = showFloating ? .on : .off
        menu.addItem(floating)
        let login = item("登入時自動開啟", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("登入 claude.ai…", #selector(showLogin)))
        menu.addItem(.separator())
        let about = NSMenuItem(title: "Usage Ring for Claude \(appVersion) · 非官方工具，與 Anthropic 無關", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(item("專案網頁（GitHub）", #selector(openProjectPage)))
        menu.addItem(item("結束", #selector(NSApplication.terminate(_:)), key: "q"))
        return menu
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return i
    }

    // MARK: 動作

    func ringClicked() {
        if case .signedOut = state { showLogin() } else { openSettings() }
    }

    @objc func openProjectPage() {
        NSWorkspace.shared.open(projectURL)
    }

    @objc func openSettings() {
        tip.orderOut(nil)
        NSWorkspace.shared.open(settingsURL)
    }

    @objc func toggleFloating() {
        showFloating.toggle()
        if showFloating { panel.orderFrontRegardless() } else { panel.orderOut(nil); tip.orderOut(nil) }
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "無法設定登入時自動開啟"
            alert.informativeText = "\(error.localizedDescription)\n可改到「系統設定 > 一般 > 登入項目」手動加入。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// 登入視窗：使用者自己在 claude.ai 登入；登入後 cookie 存在 app 的 WebKit 資料裡
    @objc func showLogin() {
        tip.orderOut(nil)
        if let w = loginWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = safariUA
        web.navigationDelegate = self
        web.load(URLRequest(url: loginURL))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "登入 claude.ai — Usage Ring for Claude（非官方）"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        loginWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // 登入頁跳轉離開 /login 後，讓背景抓取重新載入並更新
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.window === loginWindow, let url = webView.url,
              url.host?.hasSuffix("claude.ai") == true, !url.path.hasPrefix("/login") else { return }
        fetcher.reload()
        refreshNow()
    }

    // MARK: 位置

    func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "origin")
    }

    func restorePosition() {
        if let s = UserDefaults.standard.string(forKey: "origin") {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -10, dy: -10).contains(p) }) {
                panel.setFrameOrigin(p)
                return
            }
        }
        let v = NSScreen.main!.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.maxX - ringSize - 24, y: v.maxY - ringSize - 24))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
