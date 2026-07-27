import Foundation

/// User-facing formatting for Time Machine's optional progress estimates.
public struct BackupProgressFormatter: Sendable {
    public let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// The destination-row detail beneath the progress bar. Projected totals
    /// are retained in the model for diagnostics but deliberately omitted here.
    public func detail(_ progress: BackupProgress) -> String? {
        var parts: [String] = []

        if let bytes = progress.bytesCopied {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
            formatter.includesUnit = true
            formatter.isAdaptive = true
            parts.append("\(formatter.string(fromByteCount: bytes)) copied")
        }

        if let remaining = progress.timeRemaining,
            let duration = remainingDuration(remaining)
        {
            parts.append("About \(duration) remaining")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private func remainingDuration(_ seconds: TimeInterval) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.calendar = {
            var calendar = Calendar.current
            calendar.locale = locale
            return calendar
        }()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowsFractionalUnits = false
        formatter.zeroFormattingBehavior = .dropAll

        switch seconds {
        case 86_400...: formatter.allowedUnits = [.day]
        case 3_600...: formatter.allowedUnits = [.hour]
        case 60...: formatter.allowedUnits = [.minute]
        default: return "less than a minute"
        }

        return formatter.string(from: seconds)
    }
}
