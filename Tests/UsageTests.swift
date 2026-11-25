import Foundation

@main
enum UsageTests {
    static func main() throws {
        func response(_ groups: [[String: Any]]) -> [String: Any] {
            ["status": "SUCCESS", "command": ["name": "usage", "data": ["groups": groups]]]
        }
        func group(_ name: String, _ buckets: [[String: Any]]) -> [String: Any] {
            var result: [String: Any] = ["name": name, "buckets": buckets]
            if name == "Gemini Models" { result["description"] = "Models within this group: Gemini Flash, Gemini Pro" }
            if name == "Claude and GPT models" { result["description"] = "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS" }
            return result
        }
        let result = response([
            group("Gemini Models", [
                ["id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.915394, "reset_time": "2026-11-14T02:10:16Z"],
                ["id": "gemini-5h", "window": "5h", "remaining_fraction": 0.985215, "reset_time": "2026-11-07T13:03:43.123Z"],
                ["id": "missing", "window": "5h"],
                ["id": "invalid", "window": "5h", "remaining_fraction": -0.1],
                ["id": "boolean", "window": "5h", "remaining_fraction": true]
            ]),
            group("Claude and GPT models", [
                ["id": "3p-weekly", "window": "weekly", "remaining_fraction": 0.49],
                ["id": "3p-5h", "window": "5h", "remaining_fraction": 1.0]
            ]),
            group("Gemini 4 Argon", [
                ["id": "gemini-argon-wtu-weekly", "window": "weekly", "remaining_fraction": 0.35]
            ])
        ])
        let quotas = try GeminiQuota.parse(result)
        precondition(quotas.count == 5)
        let usage = UsageSnapshot(geminiQuotas: quotas)
        precondition(usage.fiveHour?.remaining == 98 && usage.weekly?.remaining == 91)
        precondition(usage.resetCredits == nil)
        precondition(usage.fiveHour?.resetsAt != nil && usage.weekly?.resetsAt != nil)
        precondition(usage.quotaBuckets.count == 5, "Other pools remain available as details")
        let options = AGYModelOption.options(from: usage.quotaBuckets)
        precondition(AGYModelOption.matching("Gemini 3.8 Flash (Medium)", in: options)?.name == "Gemini Flash")
        precondition(AGYModelOption.matching("gemini-3.8-pro-high", in: options)?.name == "Gemini Pro")
        precondition(AGYModelOption.matching("Claude Opus 4.8 (Thinking)", in: options)?.name == "Claude Opus")
        precondition(AGYModelOption.matching("GPT-OSS 120B", in: options)?.name == "GPT-OSS")
        precondition(AGYModelOption.matching("Gemini 4 Argon", in: options)?.name == "Gemini 4 Argon")
        for effort in ["Low", "Medium", "High", "XHigh", "Extra High"] {
            let hydrogen = AGYModelOption.matching("Gemini 4 Hydrogen (\(effort))", in: options)
            precondition(hydrogen?.name == "Gemini 4 Hydrogen" && hydrogen?.isShared == true)
            let selected = usage.selectingAGYModel(hydrogen?.id)
            precondition(selected.fiveHour?.remaining == 98 && selected.weekly?.remaining == 91,
                         "Hydrogen must use baseline Gemini quota, not the independent Argon pool")
        }
        precondition(AGYModelOption.matching("gemini-4-hydrogen-xhigh", in: options)?.name == "Gemini 4 Hydrogen")
        let dedicated = try GeminiQuota.parse(response([
            group("Gemini Models", [["id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.91]]),
            group("Gemini 4 Hydrogen", [["id": "gemini-hydrogen-weekly", "window": "weekly", "remaining_fraction": 0.42]])
        ]))
        let dedicatedOptions = AGYModelOption.options(from: dedicated)
        precondition(dedicatedOptions.filter { $0.name.contains("Hydrogen") }.count == 1)
        let dedicatedModel = AGYModelOption.matching("Gemini 4 Hydrogen (Medium)", in: dedicatedOptions)
        let dedicatedUsage = UsageSnapshot(geminiQuotas: dedicated).selectingAGYModel(dedicatedModel?.id)
        precondition(dedicatedUsage.weekly?.remaining == 42 && dedicatedUsage.usesWeeklyFallback,
                     "An explicitly returned Hydrogen pool must take priority over compatibility mapping")
        precondition(AGYModelOption.matching("unknown-model", in: options) == nil)
        precondition(AGYModelOption.matching(nil, in: options) == nil)
        precondition(AGYModelOption.matching("Gemini Flash Pro", in: options) == nil, "Ambiguous matches must not borrow another model's pool")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        func writeModel(_ name: String, atomic: Bool = true) throws {
            try JSONSerialization.data(withJSONObject: ["model": name]).write(to: settings, options: atomic ? .atomic : [])
        }
        try writeModel("Gemini 3.8 Flash (Medium)")
        precondition(AGYModelMonitor.readModel(at: settings) == "Gemini 3.8 Flash (Medium)")
        let monitor = AGYModelMonitor(url: settings)
        var changes: [String?] = []
        monitor.onChange = { changes.append($0) }
        monitor.check()
        func waitForChanges(_ count: Int) {
            let deadline = Date().addingTimeInterval(3)
            while changes.count < count && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            precondition(changes.count == count, "Settings changes must be detected without a quota query")
        }
        try writeModel("Claude Opus 4.8", atomic: false)
        waitForChanges(2)
        precondition(changes.last! == "Claude Opus 4.8")
        try writeModel("Gemini 4 Argon")
        waitForChanges(3)
        precondition(changes.last! == "Gemini 4 Argon")
        monitor.check()
        precondition(changes.count == 3, "Unchanged model must not trigger rerendering")
        try FileManager.default.removeItem(at: settings)
        waitForChanges(4)
        precondition(changes.last! == nil, "Missing settings must clear the previous model")
        try writeModel("Gemini 3.8 Pro")
        waitForChanges(5)
        precondition(changes.last! == "Gemini 3.8 Pro", "Watching must survive atomic replacement and recreation")
        precondition(options.map { $0.name } == ["Gemini Flash", "Gemini Pro", "Claude Opus", "Claude Sonnet", "GPT-OSS", "Gemini 4 Argon", "Gemini 4 Hydrogen"])
        let claude = usage.selectingAGYModel(options[2].id)
        precondition(claude.fiveHour?.remaining == 100 && claude.weekly?.remaining == 49)
        let argon = usage.selectingAGYModel(options[5].id)
        precondition(argon.fiveHour == nil && argon.weekly?.remaining == 35, "A weekly-only model must not borrow a five-hour window from another model")
        precondition(argon.displayedFiveHour?.remaining == 35 && argon.usesWeeklyFallback)
        precondition(argon.displayedFiveHour?.resetsAt == argon.weekly?.resetsAt)
        let pro = usage.selectingAGYModel(options[1].id)
        precondition(pro.fiveHour?.remaining == 98 && pro.weekly?.remaining == 91 && options[1].isShared)
        let unavailable = usage.selectingAGYModel("removed-model")
        precondition(unavailable.fiveHour == nil && unavailable.weekly == nil, "A missing saved selection must not silently show another model")
        precondition(unavailable.displayedFiveHour == nil && !unavailable.usesWeeklyFallback)
        precondition(pro.displayedFiveHour?.remaining == 98 && !pro.usesWeeklyFallback)
        precondition(usage.weekly?.remaining == 91, "Selecting a model must not mutate cached raw data")
        // New agy response observed on 2026-11-25: named model versions,
        // Orchestrator families, merged Gemini quota and unset epoch reset times.
        var currentGemini = group("Gemini Models", [
            ["id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.83, "reset_time": "2026-12-01T01:22:59Z"],
            ["id": "gemini-5h", "window": "5h", "remaining_fraction": 0.92, "reset_time": "2026-11-25T19:18:50Z"]
        ])
        currentGemini["description"] = "Models within this group: Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Argon, Gemini 4 Hydrogen, Orchestrator (Neon), Orchestrator (Carbon), Orchestrator (Argon), Gemini 3.8 Flash"
        var currentThirdParty = group("Claude and GPT models", [
            ["id": "3p-weekly", "window": "weekly", "remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z"],
            ["id": "3p-5h", "window": "5h", "remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00.000Z"]
        ])
        currentThirdParty["description"] = "Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B"
        let upgraded = UsageSnapshot(geminiQuotas: try GeminiQuota.parse(response([currentGemini, currentThirdParty])))
        let upgradedOptions = AGYModelOption.options(from: upgraded.quotaBuckets)
        precondition(upgradedOptions.count == 11)
        precondition(upgradedOptions.filter { $0.name.contains("Hydrogen") }.count == 1)
        for name in ["Gemini 4 Neon (XHigh)", "Gemini 4 Carbon (High)", "Gemini 4 Hydrogen (Medium)",
                     "Orchestrator (Neon)", "Orchestrator (Carbon)", "Orchestrator (Argon)"] {
            let option = AGYModelOption.matching(name, in: upgradedOptions)
            precondition(option?.groupName == "Gemini Models" && option?.isShared == true)
        }
        for (id, label) in [("gemini-pro-orchestrator-neon", "Orchestrator (Neon)"),
                            ("gemini-pro-orchestrator", "Orchestrator (Carbon)"),
                            ("gemini-pro-orchestrator-argon", "Orchestrator (Argon)")] {
            precondition(AGYModelOption.matching(id, in: upgradedOptions)?.name == label)
        }
        for (saved, label) in [("Gemini Models::Gemini Flash", "Gemini 3.8 Flash"),
                               ("Gemini 4 Argon::Gemini 4 Argon", "Gemini 4 Argon"),
                               ("Claude and GPT models::Claude Opus", "Claude Opus 5.5")] {
            let resolved = AGYModelOption.resolvingSavedID(saved, in: upgradedOptions)
            precondition(resolved?.name == label)
            let selected = upgraded.selectingAGYModel(saved)
            precondition(selected.weekly != nil && selected.fiveHour != nil,
                         "Saved model selection must survive an explicit pool move or versioned label")
        }
        let movedArgon = upgraded.selectingAGYModel("Gemini 4 Argon::Gemini 4 Argon")
        precondition(movedArgon.fiveHour?.remaining == 92 && movedArgon.weekly?.remaining == 83 && !movedArgon.usesWeeklyFallback)
        let unusedClaude = upgraded.selectingAGYModel("Claude and GPT models::Claude Opus")
        precondition(unusedClaude.fiveHour?.remaining == 100 && unusedClaude.weekly?.remaining == 100)
        precondition(unusedClaude.fiveHour?.resetsAt == nil && unusedClaude.weekly?.resetsAt == nil,
                     "Unset reset times must not show January 1970")
        precondition(AGYModelOption.matching("claude-opus-5-5-high", in: upgradedOptions)?.name == "Claude Opus 5.5")
        precondition(AGYModelOption.matching("Claude Opus 4.8 (High)", in: upgradedOptions) == nil,
                     "A specific old version must not silently become another version")
        precondition(upgraded.selectingAGYModel("Gemini Models::Gemini Pro").fiveHour == nil,
                     "Removed models must remain unavailable")
        let ambiguousVersions = upgradedOptions + [AGYModelOption(name: "Claude Opus 4.6", groupName: "Other", isShared: false)]
        precondition(AGYModelOption.resolvingSavedID("old::Claude Opus", in: ambiguousVersions) == nil)
        precondition(AGYModelOption.matching("Claude Opus 4.6 (High)", in: ambiguousVersions)?.name == "Claude Opus 4.6")
        precondition(AGYModelOption.resolvingSavedID("removed-model", in: upgradedOptions) == nil)
        for fraction in [0.0, 1.0] {
            let parsed = try GeminiQuota.parse(response([group("Gemini Models", [
                ["id": "gemini-5h", "window": "5h", "remaining_fraction": fraction]])]))
            precondition(parsed.first?.window.remaining == Int(fraction * 100))
        }
        let argonOnly = UsageSnapshot(geminiQuotas: try GeminiQuota.parse(response([
            group("Gemini 4 Argon", [["id": "gemini-argon-wtu-weekly", "window": "weekly", "remaining_fraction": 0.5]])])))
        precondition(argonOnly.fiveHour == nil && argonOnly.weekly == nil, "Separate Argon quota must not be mislabeled as pooled Gemini quota")
        precondition(!AGYModelOption.options(from: argonOnly.quotaBuckets).contains { $0.name.contains("Hydrogen") },
                     "No baseline Gemini pool means no fabricated Hydrogen quota")
        for invalid in [[:], response([]), ["response": "not structured quota"],
                        response([group("Gemini Models", [["id": "bad", "window": "5h", "remaining_fraction": 2]])])] {
            do { _ = try GeminiQuota.parse(invalid); fatalError("Must reject invalid data") }
            catch GeminiUsageError.noQuota {}
        }
        let codex = UsageSnapshot(["rateLimitsByLimitId": ["codex": [
            "primary": ["usedPercent": 25, "resetsAt": 100], "secondary": ["usedPercent": 12]]],
            "rateLimitResetCredits": ["availableCount": 2]])
        precondition(codex.fiveHour?.remaining == 75 && codex.weekly?.remaining == 88 && codex.resetCredits == 2)
        precondition(codex.quotaBuckets.isEmpty)
        print("Usage tests passed: agy windows, independent pools, missing/invalid/zero/full quotas, dates, Codex compatibility.")
    }
}
