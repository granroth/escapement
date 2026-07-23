import AppKit
import EscapementKit

/// A destination row: name and kind, the schedule summary, the live status
/// (with a progress bar while backing up), last and next run, and a primary
/// action that starts or stops a backup.
@MainActor
final class DestinationCellView: NSTableCellView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let scheduleLabel = NSTextField(labelWithString: "")
    private let timesLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let actionButton = NSButton(title: "Back Up Now", target: nil, action: nil)

    private var onPrimaryAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func build() {
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        scheduleLabel.font = .systemFont(ofSize: 12)
        scheduleLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        timesLabel.font = .systemFont(ofSize: 11)
        timesLabel.textColor = .secondaryLabelColor
        timesLabel.alignment = .right

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.isHidden = true

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(primaryAction)

        let left = NSStackView(views: [nameLabel, subtitleLabel, scheduleLabel])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2

        let center = NSStackView(views: [statusLabel, progress])
        center.orientation = .vertical
        center.alignment = .leading
        center.spacing = 4

        let right = NSStackView(views: [actionButton, timesLabel])
        right.orientation = .vertical
        right.alignment = .trailing
        right.spacing = 4

        for view in [left, center, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        progress.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            center.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 16),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 140),

            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: center.trailingAnchor, constant: 12),
        ])
    }

    func configure(with model: DestinationRow, globalBusy: Bool, onPrimaryAction: @escaping () -> Void) {
        self.onPrimaryAction = onPrimaryAction

        nameLabel.stringValue = model.destination.name
        subtitleLabel.stringValue = model.destination.kind.displayName
        scheduleLabel.stringValue = model.scheduleSummary
        statusLabel.stringValue = model.statusText
        statusLabel.textColor = model.isBusy ? .controlAccentColor : .labelColor
        timesLabel.stringValue = "Last: \(model.lastRunText)   Next: \(model.nextRunText)"

        if let value = model.progress {
            // Stop any indeterminate animation left over from a reused cell
            // before switching the bar to determinate.
            progress.stopAnimation(nil)
            progress.isHidden = false
            progress.isIndeterminate = false
            progress.doubleValue = value
        } else if model.isBusy {
            progress.isHidden = false
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
            progress.isHidden = true
        }

        // Button: stop this backup, start one, or disabled while another runs.
        if model.isBusy {
            actionButton.title = "Stop"
            actionButton.isEnabled = !model.statusText.hasPrefix("Stopping")
        } else {
            actionButton.title = "Back Up Now"
            actionButton.isEnabled = !globalBusy
        }
    }

    @objc private func primaryAction() {
        onPrimaryAction?()
    }
}

/// The conflict banner shown across the top of the status window.
@MainActor
final class BannerView: NSView {

    enum Level {
        case warning
        case caution
    }

    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "Open Time Machine Settings…", target: nil, action: nil)

    var onOpenSettings: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func build() {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(openSettings)

        let stack = NSStackView(views: [icon, label, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func configure(level: Level, message: String, showButton: Bool) {
        label.stringValue = message
        button.isHidden = !showButton
        switch level {
        case .warning:
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
            icon.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            icon.contentTintColor = .systemRed
        case .caution:
            layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
            icon.image = NSImage(
                systemSymbolName: "questionmark.circle.fill", accessibilityDescription: "Caution")
            icon.contentTintColor = .systemYellow
        }
    }

    @objc private func openSettings() { onOpenSettings?() }
}
