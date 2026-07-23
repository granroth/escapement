import AppKit
import EscapementKit

/// The schedule editor for one destination: enable, frequency, times, and the
/// weekday or day-of-month selection where the frequency needs it.
@MainActor
final class ScheduleEditorView: NSView {

    /// Called with a valid recurrence and the enabled flag when Apply is
    /// pressed.
    var onApply: ((Recurrence, Bool) -> Void)?
    var onRemove: (() -> Void)?

    private let enableCheckbox = NSButton(checkboxWithTitle: "Back up on this schedule", target: nil, action: nil)
    private let frequencyPopUp = NSPopUpButton()
    private let everyHoursPopUp = NSPopUpButton()
    private let hourlyMinutePopUp = NSPopUpButton()
    private let timePicker = NSDatePicker()
    private let weekdayButtons: [NSButton]
    private let dayButtons: [NSButton]
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Schedule", target: nil, action: nil)
    private let validationLabel = NSTextField(labelWithString: "")

    private let hourlyRow = NSStackView()
    private let timeRow = NSStackView()
    private let weekdayRow = NSStackView()
    private let dayGrid: NSGridView

    private var calendar = Calendar.current

    // Sunday-first, matching Weekday's raw values.
    private static let weekdayInitials = ["S", "M", "T", "W", "T", "F", "S"]

    override init(frame frameRect: NSRect) {
        weekdayButtons = Self.weekdayInitials.map { title in
            let b = NSButton(title: title, target: nil, action: nil)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            return b
        }
        dayButtons = (1...31).map { day in
            let b = NSButton(title: "\(day)", target: nil, action: nil)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            return b
        }
        dayGrid = NSGridView(views: [])
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - Build

    private func build() {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(controlsChanged)

        frequencyPopUp.addItems(withTitles: ["Hourly", "Daily", "Weekly", "Monthly"])
        frequencyPopUp.target = self
        frequencyPopUp.action = #selector(frequencyChanged)

        for hours in 1...12 { everyHoursPopUp.addItem(withTitle: "\(hours)") }
        everyHoursPopUp.target = self
        everyHoursPopUp.action = #selector(controlsChanged)
        for minute in stride(from: 0, to: 60, by: 5) {
            hourlyMinutePopUp.addItem(withTitle: String(format: ":%02d", minute))
        }
        hourlyMinutePopUp.target = self
        hourlyMinutePopUp.action = #selector(controlsChanged)

        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.target = self
        timePicker.action = #selector(controlsChanged)

        for button in weekdayButtons + dayButtons {
            button.target = self
            button.action = #selector(controlsChanged)
        }

        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(apply)
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(remove)
        validationLabel.textColor = .systemRed
        validationLabel.font = .systemFont(ofSize: 11)

        // Hourly row: "Every [N] hours at [:MM]"
        hourlyRow.orientation = .horizontal
        hourlyRow.spacing = 6
        hourlyRow.addArrangedSubview(NSTextField(labelWithString: "Every"))
        hourlyRow.addArrangedSubview(everyHoursPopUp)
        hourlyRow.addArrangedSubview(NSTextField(labelWithString: "hours at"))
        hourlyRow.addArrangedSubview(hourlyMinutePopUp)

        // Time row: "At [time]"
        timeRow.orientation = .horizontal
        timeRow.spacing = 6
        timeRow.addArrangedSubview(NSTextField(labelWithString: "At"))
        timeRow.addArrangedSubview(timePicker)

        weekdayRow.orientation = .horizontal
        weekdayRow.spacing = 4
        weekdayButtons.forEach { weekdayRow.addArrangedSubview($0) }

        // Day-of-month grid, 7 columns.
        var gridRows: [[NSView]] = []
        var current: [NSView] = []
        for button in dayButtons {
            current.append(button)
            if current.count == 7 { gridRows.append(current); current = [] }
        }
        if !current.isEmpty {
            while current.count < 7 { current.append(NSGridCell.emptyContentView) }
            gridRows.append(current)
        }
        for row in gridRows { dayGrid.addRow(with: row) }

        let frequencyRow = NSStackView(views: [
            NSTextField(labelWithString: "Frequency:"), frequencyPopUp,
        ])
        frequencyRow.orientation = .horizontal
        frequencyRow.spacing = 6

        let buttons = NSStackView(views: [removeButton, NSView(), applyButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let stack = NSStackView(views: [
            enableCheckbox, frequencyRow, hourlyRow, timeRow, weekdayRow, dayGrid,
            validationLabel, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: - Seeding

    func seed(from schedule: DestinationSchedule?, calendar: Calendar, locale: Locale) {
        self.calendar = calendar
        timePicker.calendar = calendar
        timePicker.locale = locale

        guard let schedule else {
            enableCheckbox.state = .off
            frequencyPopUp.selectItem(at: 1)  // Daily
            setTime(hour: 3, minute: 0)
            everyHoursPopUp.selectItem(at: 3)  // 4 hours
            hourlyMinutePopUp.selectItem(at: 0)
            selectWeekdays([])
            selectDays([])
            updateVisibility()
            updateValidation()
            return
        }

        enableCheckbox.state = schedule.isEnabled ? .on : .off
        switch schedule.recurrence.kind {
        case .hourly(let everyHours, let minute):
            frequencyPopUp.selectItem(at: 0)
            everyHoursPopUp.selectItem(at: everyHours - 1)
            // The editor works in 5-minute steps. Round a stored minute to the
            // nearest step rather than flooring it, so an off-grid value from a
            // hand-edited config snaps to the closest choice instead of always
            // rounding down.
            let step = min((minute + 2) / 5, hourlyMinutePopUp.numberOfItems - 1)
            hourlyMinutePopUp.selectItem(at: step)
        case .daily:
            frequencyPopUp.selectItem(at: 1)
            seedTime(schedule.recurrence.times.first)
        case .weekly(let weekdays):
            frequencyPopUp.selectItem(at: 2)
            seedTime(schedule.recurrence.times.first)
            selectWeekdays(weekdays)
        case .monthly(let days):
            frequencyPopUp.selectItem(at: 3)
            seedTime(schedule.recurrence.times.first)
            selectDays(days)
        }
        updateVisibility()
        updateValidation()
    }

    private func seedTime(_ time: TimeOfDay?) {
        setTime(hour: time?.hour ?? 3, minute: time?.minute ?? 0)
    }

    private func setTime(hour: Int, minute: Int) {
        if let date = calendar.date(
            from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))
        {
            timePicker.dateValue = date
        }
    }

    private func selectWeekdays(_ weekdays: Set<Weekday>) {
        for (index, button) in weekdayButtons.enumerated() {
            button.state = weekdays.contains(Weekday(rawValue: index + 1)!) ? .on : .off
        }
    }

    private func selectDays(_ days: Set<Int>) {
        for (index, button) in dayButtons.enumerated() {
            button.state = days.contains(index + 1) ? .on : .off
        }
    }

    // MARK: - Reading controls

    private var selectedTime: TimeOfDay {
        let components = calendar.dateComponents([.hour, .minute], from: timePicker.dateValue)
        return TimeOfDay(hour: components.hour ?? 3, minute: components.minute ?? 0)!
    }

    private var selectedWeekdays: Set<Weekday> {
        Set(
            weekdayButtons.enumerated()
                .filter { $0.element.state == .on }
                .compactMap { Weekday(rawValue: $0.offset + 1) })
    }

    private var selectedDays: Set<Int> {
        Set(
            dayButtons.enumerated()
                .filter { $0.element.state == .on }
                .map { $0.offset + 1 })
    }

    private func currentRecurrence() -> Recurrence? {
        switch frequencyPopUp.indexOfSelectedItem {
        case 0:
            let minute = hourlyMinutePopUp.indexOfSelectedItem * 5
            return .hourly(everyHours: everyHoursPopUp.indexOfSelectedItem + 1, minute: minute)
        case 1:
            return .daily(times: [selectedTime])
        case 2:
            return .weekly(weekdays: selectedWeekdays, times: [selectedTime])
        case 3:
            return .monthly(days: selectedDays, times: [selectedTime])
        default:
            return nil
        }
    }

    // MARK: - Actions

    @objc private func frequencyChanged() {
        updateVisibility()
        updateValidation()
    }

    @objc private func controlsChanged() {
        updateValidation()
    }

    @objc private func apply() {
        guard let recurrence = currentRecurrence() else { return }
        onApply?(recurrence, enableCheckbox.state == .on)
    }

    @objc private func remove() { onRemove?() }

    private func updateVisibility() {
        let frequency = frequencyPopUp.indexOfSelectedItem
        hourlyRow.isHidden = frequency != 0
        timeRow.isHidden = frequency == 0
        weekdayRow.isHidden = frequency != 2
        dayGrid.isHidden = frequency != 3
    }

    private func updateValidation() {
        if currentRecurrence() == nil {
            let frequency = frequencyPopUp.indexOfSelectedItem
            validationLabel.stringValue =
                frequency == 2
                ? "Choose at least one weekday." : "Choose at least one day of the month."
            applyButton.isEnabled = false
        } else {
            validationLabel.stringValue = ""
            applyButton.isEnabled = true
        }
    }
}
