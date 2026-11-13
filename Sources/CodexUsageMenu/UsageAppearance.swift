import AppKit

// One native, monochrome icon shared by the menu bar, window and menu.
enum ProviderArtwork {
    static func icon(_ provider: UsageProvider, size: CGFloat = 24, white: Bool = false) -> NSImage {
        if provider == .codex,
           let url = Bundle.main.url(forResource: "codex-mark", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            (white ? NSColor.white : NSColor.black).setStroke()
            let r = rect.insetBy(dx: size * 0.20, dy: size * 0.20)
            let cx = r.midX, cy = r.midY
            let bend = r.width * 0.12
            let path = NSBezierPath()
            path.move(to: NSPoint(x: cx, y: r.maxY))
            path.curve(to: NSPoint(x: r.maxX, y: cy),
                       controlPoint1: NSPoint(x: cx + bend, y: cy + bend),
                       controlPoint2: NSPoint(x: cx + bend, y: cy + bend))
            path.curve(to: NSPoint(x: cx, y: r.minY),
                       controlPoint1: NSPoint(x: cx + bend, y: cy - bend),
                       controlPoint2: NSPoint(x: cx + bend, y: cy - bend))
            path.curve(to: NSPoint(x: r.minX, y: cy),
                       controlPoint1: NSPoint(x: cx - bend, y: cy - bend),
                       controlPoint2: NSPoint(x: cx - bend, y: cy - bend))
            path.curve(to: NSPoint(x: cx, y: r.maxY),
                       controlPoint1: NSPoint(x: cx - bend, y: cy + bend),
                       controlPoint2: NSPoint(x: cx - bend, y: cy + bend))
            path.close()
            path.lineWidth = size / 16
            path.lineJoinStyle = .round
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class UsageSurface: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (NSColor.controlBackgroundColor.blended(withFraction: 0.025, of: .labelColor) ?? .controlBackgroundColor).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}

final class QuotaTrack: NSView {
    var remaining: Int? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        track.fill()
        guard let remaining, remaining > 0 else { return }
        let fill = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(remaining, 100)) / 100, height: bounds.height)
        (remaining <= 10 ? NSColor.systemRed : remaining <= 25 ? .systemOrange : .labelColor).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class DashboardMetricCard: NSView {
    let titleField = NSTextField(labelWithString: "")
    let valueField = NSTextField(labelWithString: "—")
    let detailField = NSTextField(labelWithString: "")
    private let track = QuotaTrack()
    private let isQuota: Bool

    init(title: String, symbolName: String, compact: Bool = false) {
        isQuota = symbolName != "arrow.clockwise"
        super.init(frame: .zero)
        let surface = UsageSurface()
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        let symbol = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!)
        symbol.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        symbol.contentTintColor = .secondaryLabelColor
        symbol.setAccessibilityElement(false)
        let heading = NSStackView(views: [titleField, NSView(), symbol])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        valueField.font = .monospacedDigitSystemFont(ofSize: compact ? 23 : 30, weight: .semibold)
        valueField.textColor = .labelColor
        detailField.font = .systemFont(ofSize: compact ? 10 : 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        track.translatesAutoresizingMaskIntoConstraints = false
        let content = NSStackView(views: [heading, valueField, detailField, track])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = compact ? 5 : 7
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        let inset: CGFloat = compact ? 12 : 16
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            content.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor),
            detailField.widthAnchor.constraint(equalTo: content.widthAnchor),
            track.widthAnchor.constraint(equalTo: content.widthAnchor),
            track.heightAnchor.constraint(equalToConstant: 3),
            symbol.widthAnchor.constraint(equalToConstant: 13),
            symbol.heightAnchor.constraint(equalToConstant: 13)
        ])
        track.alphaValue = isQuota ? 1 : 0
        track.setAccessibilityElement(false)
    }
    func setRemaining(_ value: Int?, detail: String) {
        track.remaining = value
        detailField.stringValue = detail
        detailField.toolTip = detail
    }
    required init?(coder: NSCoder) { nil }
}

final class MenuUsageSummary: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let first = DashboardMetricCard(title: "5 H", symbolName: "clock", compact: true)
    private let week = DashboardMetricCard(title: "WEEK", symbolName: "calendar", compact: true)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 296, height: 202))
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let heading = NSStackView(views: [icon, title])
        heading.spacing = 6
        heading.alignment = .centerY
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        let metrics = NSStackView(views: [first, week])
        metrics.distribution = .fillEqually
        metrics.spacing = 8
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.textColor = .labelColor
        note.maximumNumberOfLines = 3
        let root = NSStackView(views: [heading, subtitle, metrics, footer, note])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            subtitle.widthAnchor.constraint(equalTo: root.widthAnchor),
            metrics.widthAnchor.constraint(equalTo: root.widthAnchor),
            metrics.heightAnchor.constraint(equalToConstant: 102),
            note.widthAnchor.constraint(equalTo: root.widthAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func update(provider: UsageProvider, model: String?, usage: UsageSnapshot?, updated: String,
                message: String?, language: AppLanguage) {
        icon.image = ProviderArtwork.icon(provider)
        title.stringValue = provider == .codex ? "Codex" : "agy CLI"
        subtitle.stringValue = model ?? language.text("剩余额度", "剩餘額度", "Remaining quota")
        subtitle.toolTip = subtitle.stringValue
        first.titleField.stringValue = usage?.usesWeeklyFallback == true ? "5 H*" : "5 H"
        func metric(_ card: DashboardMetricCard, _ window: UsageWindow?) {
            card.valueField.stringValue = window.map { "\($0.remaining)%" } ?? "—"
            let detail: String
            if let date = window?.resetsAt {
                let formatter = DateFormatter()
                formatter.locale = language.locale
                formatter.dateFormat = "MM/dd HH:mm"
                detail = language.text("重置 ", "重置 ", "Resets ") + formatter.string(from: date)
            } else {
                detail = language.text("剩余额度", "剩餘額度", "Remaining quota")
            }
            card.setRemaining(window?.remaining, detail: detail)
        }
        metric(first, usage?.displayedFiveHour)
        metric(week, usage?.weekly)
        footer.stringValue = (provider == .codex
            ? language.text("重置次数 ", "重置次數 ", "Resets ") + (usage?.resetCredits.map(String.init) ?? "—") + "  ·  " : "") + updated
        note.stringValue = message ?? (usage?.usesWeeklyFallback == true
            ? language.text("5 H* 同步周额度，此模型仅提供周额度。", "5 H* 同步週額度，此模型僅提供週額度。", "5 H* mirrors WEEK; this model has weekly quota only.") : "")
        note.isHidden = note.stringValue.isEmpty
        layoutSubtreeIfNeeded()
        let noteHeight = note.isHidden ? 0 : note.fittingSize.height + 9
        frame.size.height = 10 + 18 + 9 + subtitle.fittingSize.height + 9 + 102 + 9 + 14 + noteHeight + 10
    }
}

final class QuotaPoolInfoView: NSView {
    init(name: String, quotas: [GeminiQuota], language: AppLanguage) {
        super.init(frame: NSRect(x: 0, y: 0, width: 296, height: 120))
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let root = NSStackView(views: [title])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        for quota in quotas {
            let label = NSTextField(labelWithString: quota.windowID == "weekly" ? "WEEK" : quota.windowID.uppercased())
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: "\(quota.window.remaining)%")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            let row = NSStackView(views: [label, NSView(), value])
            row.alignment = .firstBaseline
            root.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            if let reset = quota.resetsAt {
                let formatter = DateFormatter()
                formatter.locale = language.locale
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                let date = NSTextField(labelWithString: language.text("重置 ", "重置 ", "Resets ") + formatter.string(from: reset))
                date.font = .systemFont(ofSize: 11)
                date.textColor = .secondaryLabelColor
                root.setCustomSpacing(3, after: row)
                root.addArrangedSubview(date)
            }
        }
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        layoutSubtreeIfNeeded()
        frame.size.height = root.fittingSize.height + 20
    }
    required init?(coder: NSCoder) { nil }
}
