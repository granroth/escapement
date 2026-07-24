import AppKit
import EscapementKit

/// Edits the recurrence part of a schedule (not the enabled flag, which the
/// inspector owns). Assembles a `Recurrence` from native controls and reports
/// changes so the inspector can track unsaved edits; validation is deferred to
/// the kit's failable factories.
@MainActor
final class ScheduleEditorView: NSView {

    /// Called whenever any control changes, so the inspector can update its
    /// dirty state and Apply/Cancel availability.
    var onChange: (() -> Void)?

    private let frequencyPopUp = NSPopUpButton()

    // Hourly
    private let everyHoursPopUp = NSPopUpButton()
    private let hourlyMinutePopUp = NSPopUpButton()
    private let windowCheckbox = NSButton(
        checkboxWithTitle: "Only during a time window", target: nil, action: nil)
    private let windowStartPicker = NSDatePicker()
    private let windowEndPicker = NSDatePicker()

    // Daily
    private let everyDaysField = NSTextField()
    private let everyDaysStepper = NSStepper()

    // Daily / weekly / monthly time
    private let timePicker = NSDatePicker()

    private let weekdayButtons: [NSButton]
    private let dayButtons: [NSButton]
    private let validationLabel = NSTextField(labelWithString: "")

    private let hourlyRow = NSStackView()
    private let windowRow = NSStackView()
    private let dailyRow = NSStackView()
    private let timeRow = NSStackView()
    private let weekdayRow = NSStackView()
    private let dayGrid: NSGridView

    private var calendar = Calendar.current

    private static let weekdayInitials = ["S", "M", "T", "W", "T", "F", "S"]

    override init(frame frameRect: NSRect) {
        weekdayButtons = Self.weekdayInitials.map {
            let b = NSButton(title: $0, target: nil, action: nil)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            return b
        }
        dayButtons = (1...31).map {
            let b = NSButton(title: "\($0)", target: nil, action: nil)
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
        frequencyPopUp.addItems(withTitles: ["Hourly", "Daily", "Weekly", "Monthly"])
        frequencyPopUp.target = self
        frequencyPopUp.action = #selector(frequencyChanged)

        for hours in 1...12 { everyHoursPopUp.addItem(withTitle: "\(hours)") }
        for minute in stride(from: 0, to: 60, by: 5) {
            hourlyMinutePopUp.addItem(withTitle: String(format: ":%02d", minute))
        }
        windowCheckbox.target = self
        windowCheckbox.action = #selector(windowToggled)
        for picker in [windowStartPicker, windowEndPicker, timePicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
            picker.target = self
            picker.action = #selector(controlChanged)
        }

        everyDaysField.integerValue = 1
        everyDaysField.alignment = .right
        everyDaysField.formatter = integerFormatter()
        everyDaysField.target = self
        everyDaysField.action = #selector(everyDaysFieldChanged)
        NSLayoutConstraint.activate([everyDaysField.widthAnchor.constraint(equalToConstant: 44)])
        everyDaysStepper.minValue = 1
        everyDaysStepper.maxValue = 366
        everyDaysStepper.increment = 1
        everyDaysStepper.integerValue = 1
        everyDaysStepper.valueWraps = false
        everyDaysStepper.target = self
        everyDaysStepper.action = #selector(everyDaysStepperChanged)

        for control in [everyHoursPopUp, hourlyMinutePopUp] {
            control.target = self
            control.action = #selector(controlChanged)
        }
        for button in weekdayButtons + dayButtons {
            button.target = self
            button.action = #selector(controlChanged)
        }

        validationLabel.textColor = .systemRed
        validationLabel.font = .systemFont(ofSize: 11)

        hourlyRow.spacing = 6
        addArranged(hourlyRow, [label("Every"), everyHoursPopUp, label("hours at"), hourlyMinutePopUp])

        windowRow.orientation = .vertical
        windowRow.alignment = .leading
        windowRow.spacing = 6
        let windowTimes = NSStackView(views: [
            label("From"), windowStartPicker, label("to"), windowEndPicker,
        ])
        windowTimes.spacing = 6
        windowRow.addArrangedSubview(windowCheckbox)
        windowRow.addArrangedSubview(windowTimes)

        dailyRow.spacing = 6
        addArranged(dailyRow, [label("Every"), everyDaysField, everyDaysStepper, label("day(s)")])

        timeRow.spacing = 6
        addArranged(timeRow, [label("At"), timePicker])

        weekdayRow.spacing = 4
        weekdayButtons.forEach { weekdayRow.addArrangedSubview($0) }

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

        let frequencyRow = NSStackView(views: [label("Frequency:"), frequencyPopUp])
        frequencyRow.spacing = 6

        let stack = NSStackView(views: [
            frequencyRow, hourlyRow, dailyRow, timeRow, windowRow, weekdayRow, dayGrid,
            validationLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    private func addArranged(_ stack: NSStackView, _ views: [NSView]) {
        views.forEach { stack.addArrangedSubview($0) }
    }
    private func integerFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 366
        f.allowsFloats = false
        return f
    }

    // MARK: - Seeding

    func seed(from schedule: DestinationSchedule?, calendar: Calendar, locale: Locale) {
        self.calendar = calendar
        for picker in [windowStartPicker, windowEndPicker, timePicker] {
            picker.calendar = calendar
            picker.locale = locale
        }

        // Defaults for a destination with no schedule yet.
        frequencyPopUp.selectItem(at: 1)
        everyHoursPopUp.selectItem(at: 3)
        hourlyMinutePopUp.selectItem(at: 0)
        windowCheckbox.state = .off
        setPicker(windowStartPicker, hour: 0, minute: 0)
        setPicker(windowEndPicker, hour: 23, minute: 0)
        setEveryDays(1)
        setPicker(timePicker, hour: 3, minute: 0)
        selectWeekdays([])
        selectDays([])

        if let schedule {
            switch schedule.recurrence.kind {
            case .hourly(let everyHours, let minute, let window):
                frequencyPopUp.selectItem(at: 0)
                everyHoursPopUp.selectItem(at: everyHours - 1)
                hourlyMinutePopUp.selectItem(
                    at: min((minute + 2) / 5, hourlyMinutePopUp.numberOfItems - 1))
                if let window {
                    windowCheckbox.state = .on
                    setPicker(windowStartPicker, hour: window.start.hour, minute: window.start.minute)
                    setPicker(windowEndPicker, hour: window.end.hour, minute: window.end.minute)
                }
            case .daily(let everyDays):
                frequencyPopUp.selectItem(at: 1)
                setEveryDays(everyDays)
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
        }

        updateVisibility()
        updateValidation()
    }

    private func seedTime(_ time: TimeOfDay?) {
        setPicker(timePicker, hour: time?.hour ?? 3, minute: time?.minute ?? 0)
    }
    private func setPicker(_ picker: NSDatePicker, hour: Int, minute: Int) {
        if let date = calendar.date(
            from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))
        {
            picker.dateValue = date
        }
    }
    private func setEveryDays(_ value: Int) {
        everyDaysField.integerValue = value
        everyDaysStepper.integerValue = value
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

    private func time(from picker: NSDatePicker) -> TimeOfDay {
        let c = calendar.dateComponents([.hour, .minute], from: picker.dateValue)
        return TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)!
    }
    private var selectedTime: TimeOfDay { time(from: timePicker) }
    private var selectedWeekdays: Set<Weekday> {
        Set(
            weekdayButtons.enumerated().filter { $0.element.state == .on }
                .compactMap { Weekday(rawValue: $0.offset + 1) })
    }
    private var selectedDays: Set<Int> {
        Set(dayButtons.enumerated().filter { $0.element.state == .on }.map { $0.offset + 1 })
    }

    func currentRecurrence() -> Recurrence? {
        switch frequencyPopUp.indexOfSelectedItem {
        case 0:
            let minute = hourlyMinutePopUp.indexOfSelectedItem * 5
            let window =
                windowCheckbox.state == .on
                ? TimeWindow(start: time(from: windowStartPicker), end: time(from: windowEndPicker))
                : nil
            // An inverted window makes TimeWindow(...) nil; treat that as
            // "no valid recurrence" so validation flags it.
            if windowCheckbox.state == .on && window == nil { return nil }
            return .hourly(
                everyHours: everyHoursPopUp.indexOfSelectedItem + 1, minute: minute, window: window)
        case 1:
            return .daily(everyDays: max(1, everyDaysField.integerValue), times: [selectedTime])
        case 2:
            return .weekly(weekdays: selectedWeekdays, times: [selectedTime])
        case 3:
            return .monthly(days: selectedDays, times: [selectedTime])
        default:
            return nil
        }
    }

    var isValid: Bool { currentRecurrence() != nil }

    // MARK: - Actions

    @objc private func frequencyChanged() {
        updateVisibility()
        updateValidation()
        onChange?()
    }
    @objc private func windowToggled() {
        updateVisibility()
        updateValidation()
        onChange?()
    }
    @objc private func controlChanged() {
        updateValidation()
        onChange?()
    }
    @objc private func everyDaysStepperChanged() {
        everyDaysField.integerValue = everyDaysStepper.integerValue
        controlChanged()
    }
    @objc private func everyDaysFieldChanged() {
        let clamped = min(max(everyDaysField.integerValue, 1), 366)
        everyDaysField.integerValue = clamped
        everyDaysStepper.integerValue = clamped
        controlChanged()
    }

    private func updateVisibility() {
        let frequency = frequencyPopUp.indexOfSelectedItem
        hourlyRow.isHidden = frequency != 0
        windowRow.isHidden = frequency != 0
        windowRow.arrangedSubviews.last?.isHidden = windowCheckbox.state == .off
        dailyRow.isHidden = frequency != 1
        timeRow.isHidden = frequency == 0
        weekdayRow.isHidden = frequency != 2
        dayGrid.isHidden = frequency != 3
    }

    private func updateValidation() {
        if currentRecurrence() == nil {
            switch frequencyPopUp.indexOfSelectedItem {
            case 0:
                validationLabel.stringValue = "The window’s start must be at or before its end."
            case 2:
                validationLabel.stringValue = "Choose at least one weekday."
            default:
                validationLabel.stringValue = "Choose at least one day of the month."
            }
        } else {
            validationLabel.stringValue = ""
        }
    }
}
