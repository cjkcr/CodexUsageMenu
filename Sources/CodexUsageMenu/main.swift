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
        case .automatic, .full: return 168
        case .compact: return 116
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
            (usesWhiteForeground ? whiteCodexIcon : codexIcon)?
                .draw(in: NSRect(x: 1, y: 1, width: 22, height: 22),
                      from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        let compact = displayMode == .compact
        let columns: [(String, String, CGFloat, CGFloat)] = compact
            ? [("5 H", fiveHour, 0, 29), ("WEEK", week, 30, 35)]
            : [("5 H", fiveHour, 3, 39), ("WEEK", week, 45, 45)]
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let foreground: NSColor = usesWhiteForeground ? .white : .black
        for (label, value, x, width) in columns {
            drawText(label, font: labelFont, color: foreground,
                     in: NSRect(x: x, y: 12, width: width, height: 8))
            drawText(value, font: valueFont, color: foreground,
                     in: NSRect(x: x, y: 1, width: width, height: 12))
        }
        drawText("↻\(resets)", font: compact ? NSFont.systemFont(ofSize: 11, weight: .medium)
                                           : NSFont.menuBarFont(ofSize: 0),
                 color: foreground, in: compact ? NSRect(x: 66, y: 3, width: 25, height: 18)
                                                : NSRect(x: 92, y: 3, width: 39, height: 18))
        (usesWhiteForeground ? whiteCodexIcon : codexIcon)?
            .draw(in: compact ? NSRect(x: 92, y: 1, width: 22, height: 22)
                              : NSRect(x: 136, y: -1, width: 26, height: 26),
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

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let displayModePreferenceKey = "StatusDisplayMode"

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
    private let displayModeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var displayModeOptions: [NSMenuItem] = []
    private let chooseCLIItem = NSMenuItem(title: "", action: #selector(chooseCLI), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "q")
    private let contentView = StatusContentView(frame: NSRect(x: 0, y: 0, width: 168, height: 24))
    private var dashboardWindow: NSWindow?
    private let dashboardUsage = NSTextField(labelWithString: "")
    private let dashboardStatus = NSTextField(wrappingLabelWithString: "")
    private let dashboardPlacement = NSTextField(wrappingLabelWithString: "")
    private let dashboardMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private var language = AppLanguage.current()
    private var displayState: DisplayState = .loading
    private var refreshing = false
    private var activityTimer: Timer?
    private var lastRefreshStartedAt: Date?
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
        for item in [fiveHourItem, weeklyItem, creditsItem, updatedItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
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

        render()
        showDashboard()
        refreshNow()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshIfDue()
        }
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

    func windowWillClose(_ notification: Notification) {
        dashboardWindow = nil
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 310),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Codex Usage Menu"
        window.center()
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 13
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Codex Usage Menu")
        title.font = .boldSystemFont(ofSize: 19)
        root.addArrangedSubview(title)
        dashboardUsage.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        root.addArrangedSubview(dashboardUsage)
        dashboardStatus.maximumNumberOfLines = 3
        root.addArrangedSubview(dashboardStatus)
        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.spacing = 10
        let modeLabel = NSTextField(labelWithString: "")
        modeLabel.identifier = NSUserInterfaceItemIdentifier("displayModeLabel")
        modeRow.addArrangedSubview(modeLabel)
        dashboardMode.target = self
        dashboardMode.action = #selector(selectDashboardMode(_:))
        modeRow.addArrangedSubview(dashboardMode)
        root.addArrangedSubview(modeRow)
        dashboardPlacement.font = .systemFont(ofSize: 11)
        dashboardPlacement.textColor = .secondaryLabelColor
        root.addArrangedSubview(dashboardPlacement)
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        for (identifier, action) in [("refresh", #selector(refreshNow)),
                                     ("chooseCLI", #selector(chooseCLI))] {
            let button = NSButton(title: "", target: self, action: action)
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            actions.addArrangedSubview(button)
        }
        root.addArrangedSubview(actions)
        let help = NSTextField(wrappingLabelWithString: "")
        help.identifier = NSUserInterfaceItemIdentifier("statusHelp")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        root.addArrangedSubview(help)
        window.contentView?.addSubview(root)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
            ])
        }
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
        guard let root = dashboardWindow?.contentView?.subviews.first as? NSStackView else { return }
        dashboardWindow?.title = "Codex Usage Menu \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
        switch displayState {
        case .loading:
            dashboardUsage.stringValue = language.text("正在读取用量…", "正在讀取用量…", "Loading usage…")
            dashboardStatus.stringValue = ""
        case .usage(let usage, let updatedAt):
            dashboardUsage.stringValue = "5 H \(usage.fiveHour.map { "\($0.remaining)%" } ?? "—")    WEEK \(usage.weekly.map { "\($0.remaining)%" } ?? "—")    ↻\(usage.resetCredits.map(String.init) ?? "—")"
            dashboardStatus.stringValue = language.text("更新于 ", "更新於 ", "Updated ")
                + formattedDate(updatedAt, dateStyle: .none, timeStyle: .short)
        case .failure(let error):
            dashboardUsage.stringValue = language.text("用量读取失败", "用量讀取失敗", "Could not load usage")
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
                "菜单栏图标落在刘海左侧或遮挡区域。请先关闭其他菜单栏项目腾出空间。",
                "選單列圖示落在瀏海左側或遮擋區域。請先關閉其他選單列項目騰出空間。",
                "The menu bar icon is left of the camera safe area. Free space by closing other menu bar items."
            )
        } else {
            dashboardPlacement.stringValue = language.text(
                "菜单栏图标已创建。", "選單列圖示已建立。", "Menu bar icon created."
            )
        }
        if let modeRow = root.arrangedSubviews.first(where: { $0 is NSStackView }) as? NSStackView,
           let label = modeRow.arrangedSubviews.first as? NSTextField {
            label.stringValue = language.text("菜单栏显示", "選單列顯示", "Menu bar display")
        }
        for button in root.arrangedSubviews.compactMap({ $0 as? NSStackView }).flatMap(\.arrangedSubviews).compactMap({ $0 as? NSButton }) {
            switch button.identifier?.rawValue {
            case "refresh": button.title = language.text("立即刷新", "立即重新整理", "Refresh now")
            case "chooseCLI": button.title = language.text("选择 Codex CLI…", "選擇 Codex CLI…", "Choose Codex CLI…")
            default: break
            }
        }
        if let help = root.arrangedSubviews.compactMap({ $0 as? NSTextField })
            .first(where: { $0.identifier?.rawValue == "statusHelp" }) {
            help.stringValue = language.text(
                "如果刘海遮住菜单栏图标，请先关闭其他菜单栏项目腾出空间；图标出现后，可按住 Command 将它拖到右侧。此窗口可从 Dock 重新打开。",
                "若瀏海遮住選單列圖示，請先關閉其他選單列項目騰出空間；圖示出現後，可按住 Command 將它拖到右側。此視窗可從 Dock 重新開啟。",
                "If the camera housing hides the menu bar icon, free space by closing other menu bar items. Once visible, Command-drag it right. Reopen this window from the Dock."
            )
        }
    }

    private func refreshIfDue() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let codexIsForeground = bundleID == "com.openai.codex" || bundleID == "com.openai.chatgpt"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let active = codexIsForeground || CodexActivity.hasRecentSession()
            DispatchQueue.main.async {
                guard let self, let lastRefreshStartedAt = self.lastRefreshStartedAt else { return }
                let interval: TimeInterval = active ? 2 * 60 : 60 * 60
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

    @objc private func refreshNow() {
        guard !refreshing else { return }
        refreshing = true
        lastRefreshStartedAt = .now
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

    @objc private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = language.text("请选择 codex 可执行文件", "請選擇 codex 執行檔",
                                      "Choose the codex executable")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = language.text("所选文件无法执行", "所選檔案無法執行",
                                              "The selected file is not executable")
            alert.runModal()
            return
        }
        UserDefaults.standard.set(url.path, forKey: CodexUsageClient.preferredExecutablePathKey)
        refreshNow()
    }

    private func render() {
        updateDisplayMode()
        displayModeItem.title = language.text("菜单栏显示", "選單列顯示", "Menu bar display")
        for (mode, item) in zip(StatusDisplayMode.allCases, displayModeOptions) {
            item.title = mode.title(in: language)
            item.state = mode == preferredDisplayMode ? .on : .off
        }
        refreshItem.title = language.text("立即刷新", "立即重新整理", "Refresh now")
        chooseCLIItem.title = language.text("选择 Codex CLI…", "選擇 Codex CLI…", "Choose Codex CLI…")
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
        guard contentView.displayMode != mode || statusItem.length != mode.width else { return }
        contentView.displayMode = mode
        contentView.setFrameSize(NSSize(width: mode.width, height: 24))
        statusItem.length = mode.width
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
        if CommandLine.arguments.contains("--diagnose-cli") {
            print(CodexUsageClient().executableURL()?.path ?? "Codex CLI not found")
            return
        }
        if CommandLine.arguments.contains("--render-preview") {
            for languageCode in ["en", "zh-Hans", "zh-Hant"] {
                for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                           ("dark", NSAppearance.Name.darkAqua)] {
                    for mode in [StatusDisplayMode.full, .compact, .iconOnly] {
                        let view = StatusContentView(frame: NSRect(x: 0, y: 0,
                                                                   width: mode.width, height: 24))
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
                                                         pixelsWide: Int(mode.width * 4), pixelsHigh: 96,
                                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                                         bytesPerRow: 0, bitsPerPixel: 0) {
                            bitmap.size = view.bounds.size
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            if let data = bitmap.representation(using: .png, properties: [:]) {
                                try? data.write(to: URL(fileURLWithPath:
                                    "build/status-preview-\(languageCode)-\(name)-\(mode).png"))
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
        app.setActivationPolicy(.regular)
        withExtendedLifetime(instanceGuard) {
            app.run()
        }
    }
}
