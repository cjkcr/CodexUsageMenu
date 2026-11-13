import Foundation
import CoreFoundation
import Darwin

// Both Codex and agy's Gemini pool report five-hour and weekly quota windows.
enum UsageProvider: Int, CaseIterable {
    case codex, gemini
    var title: String { self == .codex ? "Codex" : "Gemini" }
    var firstLabel: String { "5 H" }
    var secondLabel: String { "WEEK" }
}

struct GeminiQuota {
    let groupName: String
    let modelNames: [String]
    let bucketID: String
    let windowID: String
    let fraction: Double
    let resetsAt: Date?
    var window: UsageWindow {
        UsageWindow(remaining: Int((fraction * 100).rounded(.down)), resetsAt: resetsAt)
    }

    var isPrimaryGemini: Bool {
        bucketID == "gemini-5h" || bucketID == "gemini-weekly"
            || groupName.lowercased() == "gemini models"
    }

    static func parse(_ result: [String: Any]) throws -> [GeminiQuota] {
        if let status = result["status"] as? String, status != "SUCCESS" {
            throw GeminiUsageError.requestFailed
        }
        guard let command = result["command"] as? [String: Any],
              let name = command["name"] as? String,
              ["usage", "/usage", "quota", "/quota"].contains(name.lowercased()),
              let data = command["data"] as? [String: Any],
              let groups = data["groups"] as? [[String: Any]] else { throw GeminiUsageError.noQuota }
        let quotas = groups.flatMap { group -> [GeminiQuota] in
            guard let name = group["name"] as? String, !name.isEmpty else { return [] }
            let description = group["description"] as? String ?? ""
            let prefix = "Models within this group:"
            let modelNames: [String] = description.hasPrefix(prefix)
                ? description.dropFirst(prefix.count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                : []
            return (group["buckets"] as? [[String: Any]] ?? []).compactMap { bucket -> GeminiQuota? in
                guard let id = bucket["id"] as? String,
                      let windowID = bucket["window"] as? String,
                      let fraction = bucket["remaining_fraction"] as? NSNumber,
                      CFGetTypeID(fraction) != CFBooleanGetTypeID(),
                      fraction.doubleValue.isFinite, (0...1).contains(fraction.doubleValue)
                else { return nil }
                let reset = (bucket["reset_time"] as? String).flatMap { value -> Date? in
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
                }
                return GeminiQuota(groupName: name, modelNames: modelNames, bucketID: id, windowID: windowID,
                                   fraction: fraction.doubleValue, resetsAt: reset)
            }
        }
        guard !quotas.isEmpty else { throw GeminiUsageError.noQuota }
        return quotas
    }
}

struct AGYModelOption {
    let name: String
    let groupName: String
    let isShared: Bool
    var id: String { groupName + "::" + name }

    // agy saves version/effort-qualified names, while /usage lists quota families.
    // Only accept a unique family match; never guess an unrelated quota pool.
    static func matching(_ model: String?, in options: [AGYModelOption]) -> AGYModelOption? {
        guard let model else { return nil }
        func words(_ name: String) -> Set<String> {
            Set(name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0.rangeOfCharacter(from: .letters) != nil })
        }
        if let exact = options.first(where: { $0.name.caseInsensitiveCompare(model) == .orderedSame }) { return exact }
        let tokens = words(model)
        let matches = options.filter {
            let family = words($0.name)
            return !family.isEmpty && family.isSubset(of: tokens)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func options(from buckets: [GeminiQuota]) -> [AGYModelOption] {
        var seen: Set<String> = []
        var options: [AGYModelOption] = []
        for bucket in buckets where seen.insert(bucket.groupName).inserted {
            let models = bucket.modelNames.isEmpty ? [bucket.groupName] : bucket.modelNames
            for name in models {
                options.append(AGYModelOption(name: name, groupName: bucket.groupName,
                                              isShared: bucket.modelNames.count > 1))
            }
        }
        // Older agy /usage descriptions still list only Flash and Pro. Hydrogen
        // uses baseline Gemini quota (https://antigravity.google/docs/plans).
        // Prefer any explicit Hydrogen pool returned by newer CLI versions.
        let hasHydrogenPool = buckets.contains {
            ([$0.groupName, $0.bucketID] + $0.modelNames)
                .contains { $0.localizedCaseInsensitiveContains("hydrogen") }
        }
        if !hasHydrogenPool,
           let shared = buckets.first(where: { ["gemini-5h", "gemini-weekly"].contains($0.bucketID) }) {
            options.append(AGYModelOption(name: "Gemini 4 Hydrogen", groupName: shared.groupName, isShared: true))
        }
        return options
    }
}

// Watch the directory as well as checking periodically: agy may replace settings.json
// atomically. Read only the model field; never read login files or conversation text.
final class AGYModelMonitor {
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli/settings.json")
    private let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var model: String?
    var onChange: ((String?) -> Void)?

    init(url: URL = AGYModelMonitor.settingsURL) { self.url = url }

    static func readModel(at url: URL = settingsURL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let model = settings["model"] as? String else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func check() {
        fileSource?.cancel()
        fileSource = nil
        let fileFD = open(url.path, O_EVTONLY)
        if fileFD >= 0 {
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileFD,
                eventMask: [.write, .rename, .delete], queue: .main)
            watcher.setEventHandler { [weak self] in self?.scheduleCheck() }
            watcher.setCancelHandler { close(fileFD) }
            fileSource = watcher
            watcher.resume()
        }
        if source == nil {
            let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
            if fd >= 0 {
                let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                    eventMask: [.write, .rename, .delete], queue: .main)
                watcher.setEventHandler { [weak self] in self?.scheduleCheck() }
                watcher.setCancelHandler { close(fd) }
                source = watcher
                watcher.resume()
            }
        }
        let current = Self.readModel(at: url)
        guard current != model else { return }
        model = current
        onChange?(current)
    }

    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    deinit { pending?.cancel(); source?.cancel(); fileSource?.cancel() }
}

enum GeminiUsageError: LocalizedError {
    case missingCLI, requestFailed, noQuota, timeout
    var errorDescription: String? {
        let language = AppLanguage.current()
        switch self {
        case .missingCLI:
            return language.text("未找到 agy CLI。请先安装并登录，或选择 agy 可执行文件。", "找不到 agy CLI。請先安裝並登入，或選擇 agy 執行檔。", "agy CLI was not found. Install and sign in, or choose the agy executable.")
        case .requestFailed:
            return language.text("agy 用量查询失败，请确认 agy 已登录且 /usage 能正常使用。", "agy 用量查詢失敗，請確認 agy 已登入且 /usage 能正常使用。", "agy quota request failed. Check that agy is signed in and /usage works.")
        case .noQuota:
            return language.text("agy 未返回有效额度，请更新 agy 并确认 /usage 命令可用。", "agy 未回傳有效額度，請更新 agy 並確認 /usage 指令可用。", "agy returned no valid quota. Update agy and check that /usage is available.")
        case .timeout:
            return language.text("agy 用量查询超时，请检查网络后刷新。", "agy 用量查詢逾時，請檢查網路後重新整理。", "The agy quota request timed out. Check your connection and refresh.")
        }
    }
}

final class GeminiUsageClient {
    static let preferredExecutablePathKey = "AGYCLIExecutablePath"

    static func hasRecentSession() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli")
        // /usage updates agy's database itself. Only interactive input counts as activity,
        // otherwise the monitor's own queries would keep the fast refresh loop alive forever.
        for relative in ["history.jsonl"] {
            if let values = try? directory.appendingPathComponent(relative).resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate, (-300...0).contains(date.timeIntervalSinceNow) { return true }
        }
        return false
    }

    func executableURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var paths = [UserDefaults.standard.string(forKey: Self.preferredExecutablePathKey)]
            .compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        for path in [".local/bin", ".npm-global/bin", ".bun/bin", ".volta/bin", ".asdf/shims", ".mise/shims", "Library/pnpm"] {
            paths.append(home.appendingPathComponent(path).appendingPathComponent("agy"))
        }
        paths += ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"].map { URL(fileURLWithPath: $0) }
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("agy") }
        return paths.first { fm.isExecutableFile(atPath: $0.path) }
    }

    // Use the installed CLI's own quota command; the app never reads its credentials.
    func fetch() throws -> UsageSnapshot {
        guard let executable = executableURL() else { throw GeminiUsageError.missingCLI }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--print", "/usage", "--output-format", "json", "--log-file", "/dev/null"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        environment["PATH"] = ([executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw GeminiUsageError.requestFailed }
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        let hardDeadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: deadline)
        DispatchQueue.global().asyncAfter(deadline: .now() + 28, execute: hardDeadline)
        defer {
            deadline.cancel(); hardDeadline.cancel()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit else { throw GeminiUsageError.timeout }
        guard process.terminationStatus == 0 else { throw GeminiUsageError.requestFailed }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw GeminiUsageError.noQuota }
        return try UsageSnapshot(geminiQuotas: GeminiQuota.parse(json))
    }
}
