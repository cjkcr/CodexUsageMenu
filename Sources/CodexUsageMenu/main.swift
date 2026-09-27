import AppKit
import Foundation

private enum AppLanguage: Equatable {
    case simplifiedChinese, traditionalChinese, english

    static func current() -> AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let code = preferred.lowercased()
        guard code.hasPrefix("zh") else { return .english }
        return code.contains("hant") || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk")
            || code.hasPrefix("zh-mo") ? .traditionalChinese : .simplifiedChinese
    }

    func text(_ simplified: String, _ traditional: String, _ english: String) -> String {
        switch self {
        case .simplifiedChinese: return simplified
        case .traditionalChinese: return traditional
        case .english: return english
        }
    }

    var locale: Locale {
        Locale(identifier: text("zh_CN", "zh_TW", "en_US"))
    }
}

private struct UsageWindow {
    let remaining: Int
    let resetsAt: Date?

    init?(_ value: [String: Any]?) {
        guard let value, let used = value["usedPercent"] as? NSNumber else { return nil }
        remaining = max(0, min(100, 100 - Int(used.doubleValue.rounded())))
        if let seconds = value["resetsAt"] as? NSNumber {
            resetsAt = Date(timeIntervalSince1970: seconds.doubleValue)
        } else {
            resetsAt = nil
        }
    }
}

private struct UsageSnapshot {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let resetCredits: Int?

    init(_ result: [String: Any]) {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let codex = (buckets?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any])
            ?? [:]
        fiveHour = UsageWindow(codex["primary"] as? [String: Any])
        weekly = UsageWindow(codex["secondary"] as? [String: Any])
        let credits = result["rateLimitResetCredits"] as? [String: Any]
        resetCredits = (credits?["availableCount"] as? NSNumber)?.intValue
    }
}

private enum UsageError: LocalizedError {
    case missingCodex
    case failedToStart(String)
    case noResponse
    case server(String)

    var errorDescription: String? {
        let language = AppLanguage.current()
        switch self {
        case .missingCodex:
            return language.text("未找到 Codex CLI。请先安装并登录 Codex。",
                                 "找不到 Codex CLI。請先安裝並登入 Codex。",
                                 "Codex CLI was not found. Install it and sign in first.")
        case .failedToStart(let message):
            return language.text("无法启动 Codex：", "無法啟動 Codex：", "Could not start Codex: ") + message
        case .noResponse:
            return language.text("Codex 用量查询超时或没有返回数据。",
                                 "Codex 用量查詢逾時或沒有回傳資料。",
                                 "The Codex usage request timed out or returned no data.")
        case .server:
            return language.text("Codex 用量查询失败。", "Codex 用量查詢失敗。",
                                 "The Codex usage request failed.")
        }
    }
}

private final class CodexUsageClient {
    private func executableURL() -> URL? {
        let candidates = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"
        ]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { "\($0)/codex" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    func fetch() throws -> UsageSnapshot {
        guard let executable = executableURL() else { throw UsageError.missingCodex }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() }
        catch { throw UsageError.failedToStart(error.localizedDescription) }

        let requests: [[String: Any]] = [
            ["method": "initialize", "id": 1, "params": ["clientInfo": [
                "name": "codex_usage_menu", "title": "Codex Usage Menu", "version": "1.0.0"
            ]]],
            ["method": "initialized", "params": [:]],
            ["method": "account/rateLimits/read", "id": 2]
        ]
        for request in requests {
            let data = try JSONSerialization.data(withJSONObject: request)
            input.fileHandleForWriting.write(data + Data([0x0A]))
        }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer {
            deadline.cancel()
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }

        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      (message["id"] as? NSNumber)?.intValue == 2 else { continue }
                if let result = message["result"] as? [String: Any] {
                    return UsageSnapshot(result)
                }
                let error = message["error"] as? [String: Any]
                throw UsageError.server((error?["message"] as? String) ?? "Codex 用量查询失败。")
            }
        }
        throw UsageError.noResponse
    }
}

private final class StatusContentView: NSView {
    private let codexIcon = Bundle.main.url(forResource: "codex-mark", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))
    private lazy var whiteCodexIcon: NSImage? = {
        guard let codexIcon else { return nil }
        let tinted = NSImage(size: codexIcon.size)
        tinted.lockFocus()
        codexIcon.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: codexIcon.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }()
    var usesWhiteForeground = false
    var previewBackground: NSColor?
    var fiveHour = "—" { didSet { needsDisplay = true } }
    var week = "—" { didSet { needsDisplay = true } }
    var resets = "—" { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let previewBackground {
            previewBackground.setFill()
            bounds.fill()
        }
        let columns: [(String, String, CGFloat, CGFloat)] = [
            ("5 H", fiveHour, 3, 39),
            ("WEEK", week, 45, 45)
        ]
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let foreground: NSColor = usesWhiteForeground ? .white : .black
        for (label, value, x, width) in columns {
            drawText(label, font: labelFont, color: foreground,
                     in: NSRect(x: x, y: 12, width: width, height: 8))
            drawText(value, font: valueFont, color: foreground,
                     in: NSRect(x: x, y: 1, width: width, height: 12))
        }
        drawText("↻\(resets)", font: NSFont.menuBarFont(ofSize: 0),
                 color: foreground, in: NSRect(x: 92, y: 3, width: 39, height: 18))
        (usesWhiteForeground ? whiteCodexIcon : codexIcon)?
            .draw(in: NSRect(x: 136, y: -1, width: 26, height: 26),
                  from: .zero, operation: .sourceOver, fraction: 1)
    }

    func templateImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        draw(bounds)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ])
    }

}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum DisplayState {
        case loading
        case usage(UsageSnapshot, Date)
        case failure(Error)
    }

    private let client = CodexUsageClient()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let fiveHourItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let weeklyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let creditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "", action: #selector(refreshNow), keyEquivalent: "r")
    private let quitItem = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "q")
    private let contentView = StatusContentView(frame: NSRect(x: 0, y: 0, width: 168, height: 24))
    private var language = AppLanguage.current()
    private var displayState: DisplayState = .loading
    private var refreshing = false
    private var timer: Timer?
    private var languageTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 168)
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.image = contentView.templateImage()
        }
        for item in [fiveHourItem, weeklyItem, creditsItem, updatedItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        refreshItem.target = self
        menu.addItem(refreshItem)
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        render()
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshNow() }
        languageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkLanguage()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(checkLanguage),
                                               name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkLanguage),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc private func checkLanguage() {
        let current = AppLanguage.current()
        guard current != language else { return }
        language = current
        render()
    }

    @objc private func refreshNow() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.client.fetch() }
            DispatchQueue.main.async {
                self.refreshing = false
                self.checkLanguage()
                switch result {
                case .success(let usage): self.displayState = .usage(usage, .now)
                case .failure(let error): self.displayState = .failure(error)
                }
                self.render()
            }
        }
    }

    private func render() {
        refreshItem.title = language.text("立即刷新", "立即重新整理", "Refresh now")
        quitItem.title = language.text("退出", "結束", "Quit")

        switch displayState {
        case .loading:
            contentView.fiveHour = "—"
            contentView.week = "—"
            contentView.resets = "—"
            fiveHourItem.title = language.text("5 小时：读取中…", "5 小時：讀取中…", "5 hours: loading…")
            weeklyItem.title = language.text("一周：读取中…", "一週：讀取中…", "Week: loading…")
            creditsItem.title = language.text("可用重置次数：读取中…", "可用重置次數：讀取中…",
                                              "Available resets: loading…")
            updatedItem.title = ""
            statusItem.button?.toolTip = language.text("Codex 剩余用量", "Codex 剩餘用量",
                                                       "Codex remaining usage")
        case .usage(let usage, let updatedAt):
            let five = usage.fiveHour.map { "\($0.remaining)%" } ?? "—"
            let week = usage.weekly.map { "\($0.remaining)%" } ?? "—"
            let credits = usage.resetCredits.map(String.init) ?? "—"
            contentView.fiveHour = five
            contentView.week = week
            contentView.resets = credits
            fiveHourItem.title = language.text("5 小时剩余：", "5 小時剩餘：", "5-hour remaining: ")
                + five + resetText(usage.fiveHour?.resetsAt)
            weeklyItem.title = language.text("一周剩余：", "一週剩餘：", "Weekly remaining: ")
                + week + resetText(usage.weekly?.resetsAt)
            creditsItem.title = language.text("可用重置次数：", "可用重置次數：", "Available resets: ") + credits
            updatedItem.title = language.text("更新于 ", "更新於 ", "Updated ")
                + formattedDate(updatedAt, dateStyle: .none, timeStyle: .short)
            statusItem.button?.toolTip = language.text("Codex 剩余用量 · 点击查看重置时间",
                                                       "Codex 剩餘用量 · 點擊查看重置時間",
                                                       "Codex remaining usage · Click to see reset times")
        case .failure(let error):
            contentView.fiveHour = "—"
            contentView.week = "—"
            contentView.resets = "—"
            fiveHourItem.title = language.text("用量读取失败", "用量讀取失敗", "Could not load usage")
            weeklyItem.title = error.localizedDescription
            creditsItem.title = language.text("可用重置次数：—", "可用重置次數：—",
                                              "Available resets: —")
            updatedItem.title = language.text("可点击“立即刷新”重试", "可點擊「立即重新整理」重試",
                                              "Choose Refresh now to retry")
            statusItem.button?.toolTip = error.localizedDescription
        }
        statusItem.button?.image = contentView.templateImage()
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        return language.text(" · 重置：", " · 重置：", " · Resets: ")
            + formattedDate(date, dateStyle: .short, timeStyle: .short)
    }

    private func formattedDate(_ date: Date, dateStyle: DateFormatter.Style,
                               timeStyle: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

@main
private enum CodexUsageMenu {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--render-preview") {
            for languageCode in ["en", "zh-Hans", "zh-Hant"] {
                for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                           ("dark", NSAppearance.Name.darkAqua)] {
                    let view = StatusContentView(frame: NSRect(x: 0, y: 0, width: 168, height: 24))
                    view.appearance = NSAppearance(named: appearance)
                    view.usesWhiteForeground = true
                    view.previewBackground = name == "light"
                        ? NSColor(calibratedRed: 0.49, green: 0.64, blue: 0.16, alpha: 1)
                        : NSColor(calibratedWhite: 0.16, alpha: 1)
                    view.fiveHour = "45%"
                    view.week = "91%"
                    view.resets = "1"
                    if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 672, pixelsHigh: 96,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0) {
                        bitmap.size = view.bounds.size
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath:
                                "build/status-preview-\(languageCode)-\(name).png"))
                        }
                    }
                }
            }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
