import AppKit
import Darwin
import Foundation

private enum AppNotifications {
    static let showDashboard = Notification.Name("local.codex.usage-menu.show-dashboard")
}

private final class SingleInstanceGuard {
    private let descriptor: Int32

    init?() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexUsageMenu", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let path = directory.appendingPathComponent("instance.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

enum AppLanguage: Equatable {
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

struct UsageWindow {
    let remaining: Int
    let resetsAt: Date?

    init(remaining: Int, resetsAt: Date?) {
        self.remaining = max(0, min(100, remaining))
        self.resetsAt = resetsAt
    }

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

struct UsageSnapshot {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let resetCredits: Int?
    var quotaBuckets: [GeminiQuota] = []
    var usesWeeklyFallback: Bool { !quotaBuckets.isEmpty && fiveHour == nil && weekly != nil }
    var displayedFiveHour: UsageWindow? { usesWeeklyFallback ? weekly : fiveHour }

    init(geminiQuotas: [GeminiQuota], selectedGroup: String? = nil) {
        quotaBuckets = geminiQuotas
        let selected = geminiQuotas.filter { quota in
            selectedGroup == nil ? quota.isPrimaryGemini : quota.groupName == selectedGroup
        }
        fiveHour = selected.filter { $0.windowID == "5h" }
            .min(by: { $0.fraction < $1.fraction })?.window
        weekly = selected.filter { $0.windowID == "weekly" }
            .min(by: { $0.fraction < $1.fraction })?.window
        resetCredits = nil
    }

    func selectingAGYModel(_ id: String?) -> UsageSnapshot {
        guard let id else { return self }
        let option = AGYModelOption.options(from: quotaBuckets).first { $0.id == id }
        // A missing saved model must show unavailable data, never silently another pool.
        return UsageSnapshot(geminiQuotas: quotaBuckets, selectedGroup: option?.groupName ?? "")
    }

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
            return language.text("未找到 Codex CLI。请在菜单中选择 Codex CLI，或先安装并登录。",
                                 "找不到 Codex CLI。請在選單中選擇 Codex CLI，或先安裝並登入。",
                                 "Codex CLI was not found. Choose it from the menu, or install and sign in.")
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
    static let preferredExecutablePathKey = "CodexCLIExecutablePath"

    func executableURL() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates: [URL] = []

        if let preferred = UserDefaults.standard.string(forKey: Self.preferredExecutablePathKey) {
            candidates.append(URL(fileURLWithPath: preferred))
        }

        let applicationRoots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                                home.appendingPathComponent("Applications", isDirectory: true)]
        for root in applicationRoots {
            for name in ["ChatGPT.app", "Codex.app"] {
                let app = root.appendingPathComponent(name, isDirectory: true)
                candidates.append(app.appendingPathComponent(
                    "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
                candidates.append(app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex"))
            }
        }

        let homeBinDirectories = [".local/bin", ".codex/bin", ".npm-global/bin", ".bun/bin",
                                  ".volta/bin", ".asdf/shims", ".mise/shims", "Library/pnpm"]
        candidates += homeBinDirectories.map {
            home.appendingPathComponent($0, isDirectory: true).appendingPathComponent("codex")
        }
        let nvmVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(at: nvmVersions,
                                                               includingPropertiesForKeys: nil) {
            candidates += versions.map { $0.appendingPathComponent("bin/codex") }
        }

        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .map(URL.init(fileURLWithPath:))
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex") }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    func fetch() throws -> UsageSnapshot {
        guard let executable = executableURL() else { throw UsageError.missingCodex }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        let searchPaths = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin",
                           "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (searchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
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

private enum CodexActivity {
    private static let recentSessionInterval: TimeInterval = 5 * 60

    static func hasRecentSession(at now: Date = .now) -> Bool {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        guard let files = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
            let age = now.timeIntervalSince(modified)
            if age >= 0 && age < recentSessionInterval { return true }
        }
        return false
    }
}

private enum StatusDisplayMode: Int, CaseIterable {
    case automatic, full, compact, iconOnly

    var width: CGFloat {
        switch self {
        case .automatic, .full: return 135
        case .compact: return 104
        case .iconOnly: return 24
        }
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .automatic: return language.text("自动", "自動", "Automatic")
        case .full: return language.text("完整", "完整", "Full")
        case .compact: return language.text("紧凑", "緊湊", "Compact")
        case .iconOnly: return language.text("仅图标", "僅圖示", "Icon only")
        }
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
    var provider: UsageProvider = .codex
    var showsWeeklyFallback = false
    var usesWhiteForeground = false
    var previewBackground: NSColor?
    var displayMode: StatusDisplayMode = .full { didSet { needsDisplay = true } }
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
        if displayMode == .iconOnly {
            drawProviderIcon(in: NSRect(x: 1, y: 1, width: 22, height: 22))
            return
        }
        let compact = displayMode == .compact
        // Compact coordinates are based on visible glyph bounds: the three gaps between
        // 5 H, WEEK, reset credits, and the icon render at 8 points in the 104-point image.
        let columns: [(String, String, CGFloat, CGFloat)] = compact
            ? [(provider.firstLabel + (showsWeeklyFallback ? "*" : ""), fiveHour, 0, 29), (provider.secondLabel, week, 30.75, 35)]
            : [(provider.firstLabel + (showsWeeklyFallback ? "*" : ""), fiveHour, 3, 32), (provider.secondLabel, week, 41.75, 34)]
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let foreground: NSColor = usesWhiteForeground ? .white : .black
        for (label, value, x, width) in columns {
            drawText(label, font: labelFont, color: foreground,
                     in: NSRect(x: x, y: 12, width: width, height: 8), alignment: .left)
            drawText(value, font: valueFont, color: foreground,
                     in: NSRect(x: x, y: 1, width: width, height: 12), alignment: .left)
        }
        if provider == .codex {
        drawText("↻\(resets)", font: compact ? NSFont.systemFont(ofSize: 11, weight: .medium)
                                           : NSFont.menuBarFont(ofSize: 0),
                 color: foreground, in: compact ? NSRect(x: 56, y: -1, width: 25, height: 18)
                                                : NSRect(x: 74.75, y: 0, width: 27, height: 18))
        }
        let iconX: CGFloat = provider == .codex ? (compact ? 78.5 : 106.75) : (compact ? 58 : 78)
        drawProviderIcon(in: NSRect(x: iconX, y: compact ? -0.375 : -1.25,
                                   width: compact ? 22 : 24, height: compact ? 22 : 24))
    }

    private func drawProviderIcon(in rect: NSRect) {
        if provider == .codex {
            (usesWhiteForeground ? whiteCodexIcon : codexIcon)?.draw(in: rect,
                from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        (usesWhiteForeground ? NSColor.white : NSColor.black).setFill()
        let r = rect.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.midX, y: r.maxY))
        path.curve(to: NSPoint(x: r.maxX, y: r.midY),
                   controlPoint1: NSPoint(x: r.midX + 2, y: r.midY + 2),
                   controlPoint2: NSPoint(x: r.midX + 2, y: r.midY + 2))
        path.curve(to: NSPoint(x: r.midX, y: r.minY),
                   controlPoint1: NSPoint(x: r.midX + 2, y: r.midY - 2),
                   controlPoint2: NSPoint(x: r.midX + 2, y: r.midY - 2))
        path.curve(to: NSPoint(x: r.minX, y: r.midY),
                   controlPoint1: NSPoint(x: r.midX - 2, y: r.midY - 2),
                   controlPoint2: NSPoint(x: r.midX - 2, y: r.midY - 2))
        path.curve(to: NSPoint(x: r.midX, y: r.maxY),
                   controlPoint1: NSPoint(x: r.midX - 2, y: r.midY + 2),
                   controlPoint2: NSPoint(x: r.midX - 2, y: r.midY + 2))
        path.close()
        path.fill()
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

    private func drawText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect,
                          alignment: NSTextAlignment = .center) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ])
    }

}

private final class DashboardMetricCard: NSView {
    let titleField = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    let valueField = NSTextField(labelWithString: "—")

    init(title: String, symbolName: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 10, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 14),
            symbolView.heightAnchor.constraint(equalToConstant: 14)
        ])

        let heading = NSStackView(views: [symbolView, titleField])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6
        valueField.font = .monospacedDigitSystemFont(ofSize: 25, weight: .semibold)
        valueField.textColor = .labelColor
        let content = NSStackView(views: [heading, valueField])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.74).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.42).cgColor
    }
}

private final class MenuInfoView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.toolTip = newValue.isEmpty ? nil : newValue
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        label.textColor = .labelColor
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let displayModePreferenceKey = "StatusDisplayMode"
    private static let activityCheckInterval: TimeInterval = 15
    private static let activeRefreshInterval: TimeInterval = 30
    private static let inactiveRefreshInterval: TimeInterval = 10 * 60

    private enum DisplayState {
        case loading
        case usage(UsageSnapshot, Date)
        case failure(Error)
    }

    private let client = CodexUsageClient()
    private let geminiClient = GeminiUsageClient()
    private let providerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var providerOptions: [NSMenuItem] = []
    private let modelsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let modelSelectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let dashboardModel = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dashboardModelLabel = NSTextField(labelWithString: "")
    private let dashboardModelHint = NSTextField(labelWithString: "")
    private let dashboardModelRow = NSStackView()
    private let agyModelMonitor = AGYModelMonitor()
    private var currentAGYModelName = AGYModelMonitor.readModel()
    private var followsAGYModel: Bool {
        UserDefaults.standard.object(forKey: "AGYFollowCurrentModel") as? Bool ?? true
    }
    private var selectedAGYModelID: String? {
        if followsAGYModel {
            return AGYModelOption.matching(currentAGYModelName, in: agyModelOptions)?.id ?? "unavailable-current-model"
        }
        return UserDefaults.standard.string(forKey: "AGYSelectedModel")
    }
    private var agyModelOptions: [AGYModelOption] {
        if case .usage(let usage, _) = displayState {
            return AGYModelOption.options(from: usage.quotaBuckets)
        }
        return []
    }
    private var selectedAGYModel: AGYModelOption? {
        if let id = selectedAGYModelID { return agyModelOptions.first { $0.id == id } }
        return agyModelOptions.first { $0.groupName.lowercased() == "gemini models" }
    }
    private var presentedState: DisplayState {
        guard provider == .gemini, case .usage(let usage, let date) = displayState else { return displayState }
        return .usage(usage.selectingAGYModel(selectedAGYModelID), date)
    }
    private let dashboardProvider = NSSegmentedControl(labels: ["Codex", "Gemini"], trackingMode: .selectOne, target: nil, action: nil)
    private let dashboardTitle = NSTextField(labelWithString: "Codex Usage")
    private var provider: UsageProvider {
        UsageProvider(rawValue: UserDefaults.standard.integer(forKey: "UsageProvider")) ?? .codex
    }
    private var states: [UsageProvider: DisplayState] = [:]
    private var refreshingProviders: Set<UsageProvider> = []
    private var refreshDates: [UsageProvider: Date] = [:]
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let fiveHourItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let weeklyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let creditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fiveHourInfo = MenuInfoView()
    private let weeklyInfo = MenuInfoView()
    private let creditsInfo = MenuInfoView()
    private let updatedInfo = MenuInfoView()
    private let refreshItem = NSMenuItem(title: "", action: #selector(refreshNow), keyEquivalent: "r")
    private let displayModeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var displayModeOptions: [NSMenuItem] = []
    private let chooseCLIItem = NSMenuItem(title: "", action: #selector(chooseCLI), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "q")
    private let contentView = StatusContentView(frame: NSRect(x: 0, y: 0, width: 168, height: 24))
    private var dashboardWindow: NSWindow?
    private let dashboardStatus = NSTextField(wrappingLabelWithString: "")
    private let dashboardPlacement = NSTextField(wrappingLabelWithString: "")
    private let dashboardMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dashboardModeLabel = NSTextField(labelWithString: "")
    private let dashboardRefreshButton = NSButton(title: "", target: nil, action: nil)
    private let dashboardChooseCLIButton = NSButton(title: "", target: nil, action: nil)
    private let dashboardHelp = NSTextField(wrappingLabelWithString: "")
    private let dashboardStatusDot = NSView()
    private let dashboardFiveHour = DashboardMetricCard(title: "5 H", symbolName: "clock")
    private let dashboardWeek = DashboardMetricCard(title: "WEEK", symbolName: "calendar")
    private let dashboardResets = DashboardMetricCard(title: "RESETS", symbolName: "arrow.clockwise")
    private var language = AppLanguage.current()
    private var displayState: DisplayState = .loading
    private var activityCheckInFlight = false
    private var activityTimer: Timer?
    private var preferredDisplayMode: StatusDisplayMode {
        StatusDisplayMode(rawValue: UserDefaults.standard.integer(forKey: Self.displayModePreferenceKey))
            ?? .automatic
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        statusItem.autosaveName = "CodexUsageMenuStatusItem"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        }
        menu.autoenablesItems = false
        for (item, infoView) in zip(
            [fiveHourItem, weeklyItem, creditsItem, updatedItem],
            [fiveHourInfo, weeklyInfo, creditsInfo, updatedInfo]
        ) {
            item.view = infoView
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(modelsItem)
        menu.addItem(.separator())
        let providerMenu = NSMenu()
        for provider in UsageProvider.allCases {
            let item = NSMenuItem(title: provider.title, action: #selector(selectProvider(_:)), keyEquivalent: "")
            item.target = self
            item.tag = provider.rawValue
            providerMenu.addItem(item)
            providerOptions.append(item)
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)
        menu.addItem(modelSelectionItem)
        let displayMenu = NSMenu()
        for mode in StatusDisplayMode.allCases {
            let item = NSMenuItem(title: "", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            displayMenu.addItem(item)
            displayModeOptions.append(item)
        }
        displayModeItem.submenu = displayMenu
        menu.addItem(displayModeItem)
        refreshItem.target = self
        menu.addItem(refreshItem)
        chooseCLIItem.target = self
        menu.addItem(chooseCLIItem)
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        agyModelMonitor.onChange = { [weak self] model in
            guard let self else { return }
            self.currentAGYModelName = model
            if self.provider == .gemini && self.followsAGYModel { self.render() }
        }
        agyModelMonitor.check()
        render()
        showDashboard()
        refreshNow()
        let timer = Timer(timeInterval: Self.activityCheckInterval, repeats: true) { [weak self] _ in
            self?.refreshIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(checkLanguage),
                                               name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkLanguage),
                                               name: UserDefaults.didChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(checkLanguage),
            name: Notification.Name("AppleLanguagePreferencesChangedNotification"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showDashboardNotification),
            name: AppNotifications.showDashboard, object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    @objc private func showDashboardNotification() {
        showDashboard()
    }

    private func showDashboard() {
        if let dashboardWindow {
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Codex Usage Menu"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.center()
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        window.contentView = backdrop

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false

        let appIcon = NSImageView(image: NSApplication.shared.applicationIconImage)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            appIcon.widthAnchor.constraint(equalToConstant: 38),
            appIcon.heightAnchor.constraint(equalToConstant: 38)
        ])
        let title = dashboardTitle
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        dashboardStatus.font = .systemFont(ofSize: 11, weight: .regular)
        dashboardStatus.textColor = .secondaryLabelColor
        dashboardStatus.maximumNumberOfLines = 1
        let titleStack = NSStackView(views: [title, dashboardStatus])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "v\(version)")
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        versionLabel.textColor = .tertiaryLabelColor
        let header = NSStackView(views: [appIcon, titleStack, headerSpacer, versionLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 11
        root.addArrangedSubview(header)

        dashboardProvider.target = self
        dashboardProvider.action = #selector(selectDashboardProvider(_:))
        dashboardProvider.setAccessibilityLabel(language.text("用量来源", "用量來源", "Usage provider"))
        root.addArrangedSubview(dashboardProvider)

        dashboardModel.font = .systemFont(ofSize: 12)
        dashboardModel.target = self
        dashboardModel.action = #selector(selectDashboardAGYModel(_:))
        dashboardModel.translatesAutoresizingMaskIntoConstraints = false
        dashboardModel.widthAnchor.constraint(equalToConstant: 245).isActive = true
        dashboardModelLabel.font = .systemFont(ofSize: 12, weight: .medium)
        dashboardModelRow.orientation = .horizontal
        dashboardModelRow.alignment = .centerY
        dashboardModelRow.spacing = 12
        dashboardModelRow.addArrangedSubview(dashboardModelLabel)
        dashboardModelRow.addArrangedSubview(dashboardModel)
        root.addArrangedSubview(dashboardModelRow)
        dashboardModelHint.font = .systemFont(ofSize: 10)
        dashboardModelHint.textColor = .secondaryLabelColor
        root.addArrangedSubview(dashboardModelHint)

        let metrics = NSStackView(views: [dashboardFiveHour, dashboardWeek, dashboardResets])
        metrics.orientation = .horizontal
        metrics.distribution = .fillEqually
        metrics.spacing = 10
        metrics.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([metrics.heightAnchor.constraint(equalToConstant: 86)])
        root.addArrangedSubview(metrics)

        let settings = NSBox()
        settings.boxType = .custom
        settings.cornerRadius = 12
        settings.borderWidth = 0.5
        settings.borderColor = .separatorColor.withAlphaComponent(0.45)
        settings.fillColor = .controlBackgroundColor.withAlphaComponent(0.68)
        settings.translatesAutoresizingMaskIntoConstraints = false
        let modeSpacer = NSView()
        modeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dashboardMode.font = .systemFont(ofSize: 12, weight: .medium)
        dashboardMode.target = self
        dashboardMode.action = #selector(selectDashboardMode(_:))
        dashboardMode.translatesAutoresizingMaskIntoConstraints = false
        dashboardMode.widthAnchor.constraint(equalToConstant: 108).isActive = true
        dashboardRefreshButton.target = self
        dashboardRefreshButton.action = #selector(refreshNow)
        dashboardRefreshButton.bezelStyle = .rounded
        dashboardRefreshButton.image = NSImage(systemSymbolName: "arrow.clockwise",
                                                accessibilityDescription: "Refresh")
        dashboardRefreshButton.imagePosition = .imageLeading
        dashboardChooseCLIButton.target = self
        dashboardChooseCLIButton.action = #selector(chooseCLI)
        dashboardChooseCLIButton.bezelStyle = .rounded
        let settingsRow = NSStackView(views: [dashboardModeLabel, modeSpacer, dashboardMode,
                                              dashboardRefreshButton, dashboardChooseCLIButton])
        settingsRow.orientation = .horizontal
        settingsRow.alignment = .centerY
        settingsRow.spacing = 9
        settingsRow.translatesAutoresizingMaskIntoConstraints = false
        settings.contentView?.addSubview(settingsRow)
        if let settingsContent = settings.contentView {
            NSLayoutConstraint.activate([
                settingsRow.leadingAnchor.constraint(equalTo: settingsContent.leadingAnchor, constant: 13),
                settingsRow.trailingAnchor.constraint(equalTo: settingsContent.trailingAnchor, constant: -13),
                settingsRow.centerYAnchor.constraint(equalTo: settingsContent.centerYAnchor),
                settings.heightAnchor.constraint(equalToConstant: 48)
            ])
        }
        root.addArrangedSubview(settings)

        dashboardStatusDot.wantsLayer = true
        dashboardStatusDot.layer?.cornerRadius = 4
        dashboardStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dashboardStatusDot.widthAnchor.constraint(equalToConstant: 8),
            dashboardStatusDot.heightAnchor.constraint(equalToConstant: 8)
        ])
        dashboardPlacement.font = .systemFont(ofSize: 11, weight: .medium)
        dashboardPlacement.textColor = .secondaryLabelColor
        dashboardPlacement.maximumNumberOfLines = 1
        let statusRow = NSStackView(views: [dashboardStatusDot, dashboardPlacement])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 7
        root.addArrangedSubview(statusRow)

        dashboardHelp.font = .systemFont(ofSize: 10.5)
        dashboardHelp.textColor = .tertiaryLabelColor
        dashboardHelp.maximumNumberOfLines = 2
        root.addArrangedSubview(dashboardHelp)

        backdrop.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 45),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            metrics.widthAnchor.constraint(equalTo: root.widthAnchor),
            settings.widthAnchor.constraint(equalTo: root.widthAnchor),
            dashboardHelp.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        dashboardWindow = window
        updateDashboard()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func selectDashboardMode(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: Self.displayModePreferenceKey)
        render()
    }

    private func updateDashboard() {
        guard dashboardWindow != nil else { return }
        dashboardWindow?.title = "Codex Usage Menu \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
        dashboardTitle.stringValue = provider.title + " Usage"
        dashboardProvider.setAccessibilityLabel(language.text("用量来源", "用量來源", "Usage provider"))
        dashboardProvider.selectedSegment = provider.rawValue
        dashboardFiveHour.titleField.stringValue = provider.firstLabel
        dashboardWeek.titleField.stringValue = provider.secondLabel
        dashboardResets.isHidden = provider == .gemini
        updateAGYModelControls()
        switch presentedState {
        case .loading:
            dashboardFiveHour.valueField.stringValue = "—"
            dashboardWeek.valueField.stringValue = "—"
            dashboardResets.valueField.stringValue = "—"
            dashboardStatus.stringValue = language.text("正在同步用量…", "正在同步用量…", "Syncing usage…")
        case .usage(let usage, let updatedAt):
            dashboardFiveHour.valueField.stringValue = usage.displayedFiveHour.map { "\($0.remaining)%" } ?? "—"
            if usage.usesWeeklyFallback {
                dashboardFiveHour.titleField.stringValue = "5 H*"
                dashboardModelHint.stringValue += language.text(
                    " · 仅周额度，5 H* 同步显示周额度", " · 僅週額度，5 H* 同步顯示週額度",
                    " · Weekly only; 5 H* mirrors weekly quota")
            }
            dashboardWeek.valueField.stringValue = usage.weekly.map { "\($0.remaining)%" } ?? "—"
            dashboardResets.valueField.stringValue = usage.resetCredits.map(String.init) ?? "—"
            dashboardStatus.stringValue = language.text("更新于 ", "更新於 ", "Updated ")
                + formattedDate(updatedAt, dateStyle: .none, timeStyle: .short)
        case .failure(let error):
            dashboardFiveHour.valueField.stringValue = "—"
            dashboardWeek.valueField.stringValue = "—"
            dashboardResets.valueField.stringValue = "—"
            dashboardStatus.stringValue = error.localizedDescription
        }
        dashboardMode.removeAllItems()
        dashboardMode.addItems(withTitles: StatusDisplayMode.allCases.map { $0.title(in: language) })
        dashboardMode.selectItem(at: preferredDisplayMode.rawValue)
        if let buttonWindow = statusItem.button?.window,
           let screen = buttonWindow.screen,
           let safeArea = screen.auxiliaryTopRightArea,
           buttonWindow.frame.minX < safeArea.minX {
            dashboardPlacement.stringValue = language.text(
                "菜单栏空间不足，请关闭其他项目腾出空间",
                "選單列空間不足，請關閉其他項目騰出空間",
                "Menu bar space is limited — close other items to make room"
            )
            dashboardStatusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        } else {
            dashboardPlacement.stringValue = language.text(
                "菜单栏运行中", "選單列執行中", "Running in the menu bar"
            )
            dashboardStatusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        }
        dashboardModeLabel.stringValue = language.text("菜单栏显示", "選單列顯示", "Menu bar display")
        dashboardRefreshButton.title = language.text("刷新", "重新整理", "Refresh")
        dashboardRefreshButton.toolTip = language.text("立即刷新用量", "立即重新整理用量", "Refresh usage now")
        dashboardChooseCLIButton.title = language.text("选择 ", "選擇 ", "Choose ") + (provider == .codex ? "CLI…" : "agy…")
        dashboardChooseCLIButton.isHidden = provider == .codex ? client.executableURL() != nil : geminiClient.executableURL() != nil
        dashboardRefreshButton.isEnabled = !refreshingProviders.contains(provider)
        dashboardHelp.stringValue = language.text(
            "关闭窗口后仍会在菜单栏运行。需要窗口时，从“应用程序”再次打开。",
            "關閉視窗後仍會在選單列執行。需要視窗時，從「應用程式」再次開啟。",
            "Closing this window keeps the menu bar item running. Reopen it from Applications."
        )
    }

    private func refreshIfDue() {
        agyModelMonitor.check()
        guard !activityCheckInFlight else { return }
        activityCheckInFlight = true
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let selectedProvider = provider
        let codexIsForeground = bundleID == "com.openai.codex" || bundleID == "com.openai.chatgpt"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let active = selectedProvider == .codex
                ? (codexIsForeground || CodexActivity.hasRecentSession())
                : GeminiUsageClient.hasRecentSession()
            DispatchQueue.main.async {
                guard let self else { return }
                self.activityCheckInFlight = false
                guard self.provider == selectedProvider,
                      let lastRefreshStartedAt = self.refreshDates[selectedProvider] else { return }
                let interval = active ? Self.activeRefreshInterval : Self.inactiveRefreshInterval
                if Date.now.timeIntervalSince(lastRefreshStartedAt) >= interval - 1 {
                    self.refreshNow()
                }
            }
        }
    }

    @objc private func applicationActivated() { refreshIfDue() }

    @objc private func screenParametersChanged() { render() }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: Self.displayModePreferenceKey)
        render()
    }

    @objc private func checkLanguage() {
        let current = AppLanguage.current()
        guard current != language else { return }
        language = current
        render()
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        changeProvider(UsageProvider(rawValue: sender.tag) ?? .codex)
    }

    @objc private func selectDashboardProvider(_ sender: NSSegmentedControl) {
        changeProvider(UsageProvider(rawValue: sender.selectedSegment) ?? .codex)
    }

    private func changeProvider(_ selected: UsageProvider) {
        guard selected != provider else { return }
        UserDefaults.standard.set(selected.rawValue, forKey: "UsageProvider")
        displayState = states[selected] ?? .loading
        render()
        refreshNow()
    }

    @objc private func selectAGYModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        changeAGYModel(id)
    }

    @objc private func selectDashboardAGYModel(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        changeAGYModel(id)
    }

    private func changeAGYModel(_ id: String) {
        UserDefaults.standard.set(id == "auto", forKey: "AGYFollowCurrentModel")
        if id != "auto" { UserDefaults.standard.set(id, forKey: "AGYSelectedModel") }
        agyModelMonitor.check()
        render()
    }

    private func updateAGYModelControls() {
        let visible = provider == .gemini
        modelSelectionItem.isHidden = !visible
        dashboardModelRow.isHidden = !visible
        dashboardModelHint.isHidden = !visible
        guard visible else { return }
        let label = language.text("模型/额度", "模型/額度", "Model / quota")
        let options = agyModelOptions
        let selection = selectedAGYModel
        let selectedID = selectedAGYModelID ?? selection?.id
        let name = (followsAGYModel ? currentAGYModelName : selection?.name)
            ?? language.text("所选模型不可用", "所選模型無法使用", "Selected model unavailable")
        let automatic = language.text("自动跟随 agy", "自動跟隨 agy", "Follow agy automatically")
        modelSelectionItem.title = label + ": " + (followsAGYModel ? automatic + " · " : "") + name
        dashboardModelLabel.stringValue = label
        dashboardModel.setAccessibilityLabel(label)
        dashboardModel.removeAllItems()
        let submenu = NSMenu()
        let autoItem = NSMenuItem(title: automatic, action: #selector(selectAGYModel(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = "auto"
        autoItem.state = followsAGYModel ? .on : .off
        submenu.addItem(autoItem)
        submenu.addItem(.separator())
        dashboardModel.addItem(withTitle: automatic)
        dashboardModel.lastItem?.representedObject = "auto"
        for option in options {
            let item = NSMenuItem(title: option.name, action: #selector(selectAGYModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            item.state = !followsAGYModel && option.id == selectedID ? .on : .off
            submenu.addItem(item)
            dashboardModel.addItem(withTitle: option.name)
            dashboardModel.lastItem?.representedObject = option.id
            if !followsAGYModel && option.id == selectedID { dashboardModel.select(dashboardModel.lastItem) }
        }
        if followsAGYModel { dashboardModel.selectItem(at: 0) }
        if !followsAGYModel && !options.contains(where: { $0.id == selectedID }) {
            dashboardModel.insertItem(withTitle: name, at: 0)
            dashboardModel.item(at: 0)?.isEnabled = false
            dashboardModel.selectItem(at: 0)
        }
        dashboardModel.isEnabled = true
        modelSelectionItem.submenu = submenu
        modelSelectionItem.isEnabled = true
        if let selection, selection.isShared {
            dashboardModelHint.stringValue = language.text("共享额度：", "共享額度：", "Shared quota: ") + selection.groupName
        } else {
            dashboardModelHint.stringValue = selection?.groupName ?? language.text("刷新后获取可用模型", "重新整理後取得可用模型", "Refresh to load available models")
        }
        if followsAGYModel {
            dashboardModelHint.stringValue = name + " · " + (selection == nil
                ? language.text("未匹配到额度池", "未匹配到額度池", "No matching quota pool")
                : dashboardModelHint.stringValue)
        }
    }

    @objc private func refreshNow() {
        let selected = provider
        guard !refreshingProviders.contains(selected) else { return }
        refreshingProviders.insert(selected)
        refreshDates[selected] = .now
        render()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try selected == .codex ? self.client.fetch() : self.geminiClient.fetch() }
            DispatchQueue.main.async {
                self.refreshingProviders.remove(selected)
                let state: DisplayState
                switch result {
                case .success(let usage): state = .usage(usage, .now)
                case .failure(let error): state = .failure(error)
                }
                self.states[selected] = state
                if self.provider == selected { self.displayState = state }
                self.checkLanguage()
                self.render()
            }
        }
    }

    @objc private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = language.text("请选择可执行文件：", "請選擇執行檔：", "Choose executable: ") + (provider == .codex ? "codex" : "agy")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = language.text("所选文件无法执行", "所選檔案無法執行",
                                              "The selected file is not executable")
            alert.runModal()
            return
        }
        UserDefaults.standard.set(url.path, forKey: provider == .codex
            ? CodexUsageClient.preferredExecutablePathKey : GeminiUsageClient.preferredExecutablePathKey)
        refreshNow()
    }

    private func render() {
        contentView.provider = provider
        contentView.showsWeeklyFallback = false
        updateDisplayMode()
        providerItem.title = language.text("用量来源：", "用量來源：", "Usage provider: ") + provider.title
        for (choice, item) in zip(UsageProvider.allCases, providerOptions) {
            item.state = choice == provider ? .on : .off
        }
        refreshItem.isEnabled = !refreshingProviders.contains(provider)
        creditsItem.isHidden = provider == .gemini
        modelsItem.isHidden = true
        modelsItem.title = language.text("agy 各额度池", "agy 各額度池", "agy quota pools")
        displayModeItem.title = language.text("菜单栏显示", "選單列顯示", "Menu bar display")
        for (mode, item) in zip(StatusDisplayMode.allCases, displayModeOptions) {
            item.title = mode.title(in: language)
            item.state = mode == preferredDisplayMode ? .on : .off
        }
        refreshItem.title = language.text("立即刷新", "立即重新整理", "Refresh now")
        chooseCLIItem.title = language.text("选择 ", "選擇 ", "Choose ") + (provider == .codex ? "Codex" : "agy") + " CLI…"
        chooseCLIItem.isHidden = provider == .codex ? client.executableURL() != nil : geminiClient.executableURL() != nil
        quitItem.title = language.text("退出", "結束", "Quit")

        switch presentedState {
        case .loading:
            contentView.fiveHour = "—"
            contentView.week = "—"
            contentView.resets = "—"
            fiveHourInfo.text = language.text("5 小时：读取中…", "5 小時：讀取中…", "5 hours: loading…")
            weeklyInfo.text = language.text("一周：读取中…", "一週：讀取中…", "Week: loading…")
            creditsInfo.text = language.text("可用重置次数：读取中…", "可用重置次數：讀取中…",
                                             "Available resets: loading…")
            updatedInfo.text = ""
            statusItem.button?.toolTip = language.text("Codex 剩余用量", "Codex 剩餘用量",
                                                       "Codex remaining usage")
        case .usage(let usage, let updatedAt):
            contentView.showsWeeklyFallback = usage.usesWeeklyFallback
            let five = usage.displayedFiveHour.map { "\($0.remaining)%" } ?? "—"
            let week = usage.weekly.map { "\($0.remaining)%" } ?? "—"
            let credits = usage.resetCredits.map(String.init) ?? "—"
            contentView.fiveHour = five
            contentView.week = week
            contentView.resets = credits
            fiveHourInfo.text = language.text("5 小时剩余：", "5 小時剩餘：", "5-hour remaining: ")
                + five + resetText(usage.fiveHour?.resetsAt)
            weeklyInfo.text = language.text("一周剩余：", "一週剩餘：", "Weekly remaining: ")
                + week + resetText(usage.weekly?.resetsAt)
            creditsInfo.text = language.text("可用重置次数：", "可用重置次數：", "Available resets: ") + credits
            updatedInfo.text = language.text("更新于 ", "更新於 ", "Updated ")
                + formattedDate(updatedAt, dateStyle: .none, timeStyle: .short)
            statusItem.button?.toolTip = language.text("Codex 剩余用量 · 点击查看重置时间",
                                                       "Codex 剩餘用量 · 點擊查看重置時間",
                                                       "Codex remaining usage · Click to see reset times")
        case .failure(let error):
            contentView.fiveHour = "—"
            contentView.week = "—"
            contentView.resets = "—"
            fiveHourInfo.text = language.text("用量读取失败", "用量讀取失敗", "Could not load usage")
            weeklyInfo.text = error.localizedDescription
            creditsInfo.text = language.text("可用重置次数：—", "可用重置次數：—",
                                             "Available resets: —")
            updatedInfo.text = language.text("可点击“立即刷新”重试", "可點擊「立即重新整理」重試",
                                             "Choose Refresh now to retry")
            statusItem.button?.toolTip = error.localizedDescription
        }
        if provider == .gemini {
            switch presentedState {
            case .loading:
                fiveHourInfo.text = "5 H: " + language.text("读取中…", "讀取中…", "Loading…")
                weeklyInfo.text = "WEEK: " + language.text("读取中…", "讀取中…", "Loading…")
            case .usage(let usage, _):
                let firstLabel = usage.usesWeeklyFallback
                    ? language.text("5 H*（同周额度）：", "5 H*（同週額度）：", "5 H* (weekly quota): ")
                    : "5 H: "
                fiveHourInfo.text = firstLabel + (usage.displayedFiveHour.map { "\($0.remaining)%" } ?? "—") + resetText(usage.displayedFiveHour?.resetsAt)
                weeklyInfo.text = "WEEK: " + (usage.weekly.map { "\($0.remaining)%" } ?? "—") + resetText(usage.weekly?.resetsAt)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for quota in usage.quotaBuckets {
                    let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    let info = MenuInfoView()
                    info.frame.size.width = 400
                    info.text = quota.groupName + " · " + quota.windowID + ": \(quota.window.remaining)%" + resetText(quota.resetsAt)
                    row.view = info
                    row.isEnabled = false
                    submenu.addItem(row)
                }
                modelsItem.submenu = submenu
                modelsItem.isHidden = usage.quotaBuckets.isEmpty
            case .failure: break
            }
            let modelName = selectedAGYModel?.name ?? language.text("所选模型不可用", "所選模型無法使用", "Selected model unavailable")
            statusItem.button?.toolTip = "agy · " + modelName + " · 5 H / WEEK"
            if let selection = selectedAGYModel, selection.isShared {
                statusItem.button?.toolTip? += " · " + selection.groupName
            }
            if case .usage(let usage, _) = presentedState, usage.usesWeeklyFallback {
                statusItem.button?.toolTip? += language.text(
                    " · 5 H* 同步显示周额度（此模型无独立 5 小时额度）",
                    " · 5 H* 同步顯示週額度（此模型無獨立 5 小時額度）",
                    " · 5 H* mirrors weekly quota; no separate five-hour quota")
            }
            if case .failure(let error) = presentedState { statusItem.button?.toolTip = error.localizedDescription }
        }
        statusItem.button?.image = contentView.templateImage()
        updateDashboard()
    }

    private func updateDisplayMode() {
        let mode: StatusDisplayMode
        if preferredDisplayMode == .automatic {
            let screen = statusItem.button?.window?.screen ?? NSScreen.main
            let width = screen?.frame.width ?? 1680
            if screen?.auxiliaryTopRightArea != nil || width < 1280 {
                mode = .iconOnly
            } else if width < 1600 {
                mode = .compact
            } else {
                mode = .full
            }
        } else {
            mode = preferredDisplayMode
        }
        let width: CGFloat = provider == .gemini && mode != .iconOnly
            ? (mode == .compact ? 84 : 108) : mode.width
        guard contentView.displayMode != mode || statusItem.length != width else { return }
        contentView.displayMode = mode
        contentView.setFrameSize(NSSize(width: width, height: 24))
        statusItem.length = width
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

#if !USAGE_TESTS
@main
private enum CodexUsageMenu {
    static func main() {
        if CommandLine.arguments.contains("--diagnose-gemini") {
            do {
                let usage = try GeminiUsageClient().fetch()
                for quota in usage.quotaBuckets {
                    print("\(quota.groupName) · \(quota.windowID): \(quota.window.remaining)%")
                }
            } catch {
                fputs((error.localizedDescription + "\n"), stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose-cli") {
            print(CodexUsageClient().executableURL()?.path ?? "Codex CLI not found")
            return
        }
        if CommandLine.arguments.contains("--render-preview") {
            for provider in UsageProvider.allCases {
            for languageCode in ["en", "zh-Hans", "zh-Hant"] {
                for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                           ("dark", NSAppearance.Name.darkAqua)] {
                    for mode in [StatusDisplayMode.full, .compact, .iconOnly] {
                        let width: CGFloat = provider == .gemini && mode != .iconOnly
                            ? (mode == .compact ? 84 : 108) : mode.width
                        let view = StatusContentView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
                        view.provider = provider
                        view.displayMode = mode
                        view.appearance = NSAppearance(named: appearance)
                        view.usesWhiteForeground = true
                        view.previewBackground = name == "light"
                            ? NSColor(calibratedRed: 0.49, green: 0.64, blue: 0.16, alpha: 1)
                            : NSColor(calibratedWhite: 0.16, alpha: 1)
                        view.fiveHour = "45%"
                        view.week = "91%"
                        view.resets = "1"
                        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                         pixelsWide: Int(width * 4), pixelsHigh: 96,
                                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                                         bytesPerRow: 0, bitsPerPixel: 0) {
                            bitmap.size = view.bounds.size
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            if let data = bitmap.representation(using: .png, properties: [:]) {
                                try? data.write(to: URL(fileURLWithPath:
                                    "build/status-preview-\(provider.title.lowercased())-\(languageCode)-\(name)-\(mode).png"))
                            }
                        }
                    }
                }
            }
            }
            return
        }
        guard let instanceGuard = SingleInstanceGuard() else {
            DistributedNotificationCenter.default().post(name: AppNotifications.showDashboard,
                                                         object: nil)
            let currentPID = ProcessInfo.processInfo.processIdentifier
            NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.usage-menu")
                .first(where: { $0.processIdentifier != currentPID })?
                .activate(options: [.activateAllWindows])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(instanceGuard) {
            app.run()
        }
    }
}
#endif
