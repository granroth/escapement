import AppKit
import EscapementKit

/// The right-hand inspector: a header with the destination, an Enabled switch,
/// the schedule editor, and Apply / Cancel. Edits are staged and committed on
/// Apply, matching the Lingon-style panel; the window controller consults
/// `hasUnsavedChanges` before letting the selection move away.
@MainActor
final class InspectorViewController: NSViewController {

    private let controller: AppController
    private var destination: Destination?

    /// The last committed state, against which unsaved changes are measured.
    private var baseline: (recurrence: Recurrence?, enabled: Bool) = (nil, false)

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let enabledSwitch = NSSwitch()
    private let enabledLabel = NSTextField(labelWithString: "Enabled")
    private let editor = ScheduleEditorView()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Schedule", target: nil, action: nil)
    private let placeholder = NSTextField(labelWithString: "Select a destination to set its schedule.")
    private let editingStack = NSStackView()

    init(controller: AppController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        build()
        showDestination(nil)
    }

    private func build() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        kindLabel.font = .systemFont(ofSize: 11)
        kindLabel.textColor = .secondaryLabelColor

        enabledSwitch.target = self
        enabledSwitch.action = #selector(controlChanged)
        enabledLabel.font = .systemFont(ofSize: 12)

        let nameStack = NSStackView(views: [nameLabel, kindLabel])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 1

        let enabledStack = NSStackView(views: [enabledLabel, enabledSwitch])
        enabledStack.spacing = 6

        let header = NSStackView(views: [iconView, nameStack, NSView(), enabledStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let separator = NSBox()
        separator.boxType = .separator

        editor.onChange = { [weak self] in self?.updateButtons() }

        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(apply)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"  // Esc
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(remove)

        let buttons = NSStackView(views: [removeButton, NSView(), cancelButton, applyButton])
        buttons.orientation = .horizontal

        editingStack.orientation = .vertical
        editingStack.alignment = .leading
        editingStack.spacing = 14
        editingStack.translatesAutoresizingMaskIntoConstraints = false
        [header, separator, editor, NSView(), buttons].forEach {
            editingStack.addArrangedSubview($0)
        }
        editingStack.setHuggingPriority(.defaultLow, for: .horizontal)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center

        view.addSubview(editingStack)
        view.addSubview(placeholder)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            editingStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            editingStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            editingStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            editingStack.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: editingStack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: editingStack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: editingStack.widthAnchor),

            placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Selection

    /// Seeds the inspector for a destination (or clears it for none).
    func showDestination(_ destination: Destination?) {
        self.destination = destination
        guard let destination else {
            editingStack.isHidden = true
            placeholder.isHidden = false
            return
        }
        editingStack.isHidden = false
        placeholder.isHidden = true

        iconView.image = DestinationIcons.image(for: destination.kind)
        nameLabel.stringValue = destination.name
        kindLabel.stringValue = destination.kind.displayName

        let schedule = controller.schedule(for: destination.id)
        enabledSwitch.state = (schedule?.isEnabled ?? false) ? .on : .off
        editor.seed(from: schedule, calendar: controller.calendar, locale: controller.locale)
        // The baseline is the *seeded* state, not the raw schedule. A
        // destination with no schedule still seeds valid defaults (Daily), so
        // comparing against the schedule (nil) would mark it dirty before the
        // user touches anything — falsely enabling Apply and popping the
        // discard prompt. Capturing what the editor now shows makes "dirty"
        // mean "the user changed something".
        baseline = current
        removeButton.isHidden = schedule == nil
        updateButtons()
    }

    // MARK: - Dirty tracking

    /// The staged edits, or `nil` recurrence if the editor is currently invalid.
    private var current: (recurrence: Recurrence?, enabled: Bool) {
        (editor.currentRecurrence(), enabledSwitch.state == .on)
    }

    var hasUnsavedChanges: Bool {
        guard destination != nil else { return false }
        return current.recurrence != baseline.recurrence || current.enabled != baseline.enabled
    }

    private func updateButtons() {
        let dirty = hasUnsavedChanges
        cancelButton.isEnabled = dirty
        applyButton.isEnabled = dirty && editor.isValid
    }

    // MARK: - Actions

    @objc private func controlChanged() { updateButtons() }

    @objc private func apply() { commit() }

    /// Commits staged edits. Returns false if the editor is invalid.
    @discardableResult
    func commit() -> Bool {
        guard let destination, let recurrence = editor.currentRecurrence() else { return false }
        let schedule = DestinationSchedule(
            destinationID: destination.id, recurrence: recurrence,
            isEnabled: enabledSwitch.state == .on, effectiveFrom: Date())
        controller.apply(schedule)
        baseline = (recurrence, enabledSwitch.state == .on)
        removeButton.isHidden = false
        updateButtons()
        return true
    }

    @objc private func cancel() { revert() }

    /// Discards staged edits, re-seeding from the stored schedule.
    func revert() {
        showDestination(destination)
    }

    @objc private func remove() {
        guard let destination else { return }
        controller.removeSchedule(destinationID: destination.id)
        showDestination(destination)
    }
}
