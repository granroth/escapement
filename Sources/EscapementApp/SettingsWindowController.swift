import AppKit
import EscapementKit

/// Settings: pick a destination, set its schedule. The heavy validation lives
/// in `EscapementKit`'s failable factories — the editor only assembles the
/// pieces and refuses to apply an invalid combination.
@MainActor
final class SettingsWindowController: NSWindowController {

    private let controller: AppController
    private let destinationPopUp = NSPopUpButton()
    private let editor: ScheduleEditorView
    private let noDestinationsLabel = NSTextField(
        labelWithString: "No Time Machine destinations to configure yet.")
    private var destinations: [Destination] = []

    init(controller: AppController) {
        self.controller = controller
        self.editor = ScheduleEditorView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Escapement Settings"
        window.setFrameAutosaveName("EscapementSettingsWindow")
        super.init(window: window)
        buildContent()
        controller.addObserver { [weak self] in self?.reloadDestinations() }
        reloadDestinations()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        let pickerLabel = NSTextField(labelWithString: "Destination:")
        destinationPopUp.target = self
        destinationPopUp.action = #selector(destinationChanged)

        editor.onApply = { [weak self] recurrence, enabled in
            self?.applyEditor(recurrence: recurrence, enabled: enabled)
        }
        editor.onRemove = { [weak self] in self?.removeSelected() }

        for view in [pickerLabel, destinationPopUp, editor, noDestinationsLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        noDestinationsLabel.textColor = .secondaryLabelColor
        noDestinationsLabel.isHidden = true

        NSLayoutConstraint.activate([
            pickerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            pickerLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            destinationPopUp.centerYAnchor.constraint(equalTo: pickerLabel.centerYAnchor),
            destinationPopUp.leadingAnchor.constraint(
                equalTo: pickerLabel.trailingAnchor, constant: 8),
            destinationPopUp.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -20),

            editor.topAnchor.constraint(equalTo: pickerLabel.bottomAnchor, constant: 18),
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            editor.bottomAnchor.constraint(
                lessThanOrEqualTo: content.bottomAnchor, constant: -20),

            noDestinationsLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            noDestinationsLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    private func reloadDestinations() {
        let previousID = selectedDestinationID
        destinations = controller.destinations

        destinationPopUp.removeAllItems()
        for destination in destinations {
            destinationPopUp.addItem(withTitle: destination.name)
        }
        let empty = destinations.isEmpty
        editor.isHidden = empty
        destinationPopUp.isHidden = empty
        noDestinationsLabel.isHidden = !empty
        guard !empty else { return }

        if let previousID, let index = destinations.firstIndex(where: { $0.id == previousID }) {
            destinationPopUp.selectItem(at: index)
        }
        seedEditor()
    }

    private var selectedDestinationID: String? {
        let index = destinationPopUp.indexOfSelectedItem
        guard index >= 0, index < destinations.count else { return nil }
        return destinations[index].id
    }

    private func seedEditor() {
        guard let id = selectedDestinationID else { return }
        editor.seed(
            from: controller.schedule(for: id),
            calendar: controller.calendar, locale: controller.locale)
    }

    @objc private func destinationChanged() { seedEditor() }

    private func applyEditor(recurrence: Recurrence, enabled: Bool) {
        guard let id = selectedDestinationID else { return }
        // effectiveFrom is stamped now so a just-saved schedule never triggers
        // an immediate backup — the first fire is the next occurrence.
        let schedule = DestinationSchedule(
            destinationID: id, recurrence: recurrence, isEnabled: enabled, effectiveFrom: Date())
        controller.apply(schedule)
    }

    private func removeSelected() {
        guard let id = selectedDestinationID else { return }
        controller.removeSchedule(destinationID: id)
        seedEditor()
    }
}
