import Foundation

/// Turns raw `tmutil` output into Escapement's domain types.
///
/// Kept as pure, static functions with no process invocation so the parsing —
/// the part most likely to break when Apple changes a format — is testable
/// against captured fixtures without a live Time Machine.
public enum TimeMachineOutputParser {

    public enum ParseError: Error, Sendable {
        case notAPropertyList
        case noStatusDictionary
    }

    // MARK: - Destinations

    /// Parses the XML plist emitted by `tmutil destinationinfo -X`.
    ///
    /// An entry lacking an `ID` is skipped rather than guessed at: the id is
    /// the handle used to start a backup, and a destination we cannot start is
    /// worse than one we do not list.
    public static func destinations(fromDestinationInfoPlist data: Data) throws -> [Destination] {
        guard let root = try propertyList(from: data) as? [String: Any] else {
            throw ParseError.notAPropertyList
        }
        let entries = root["Destinations"] as? [[String: Any]] ?? []

        return entries.compactMap { entry in
            guard let id = entry["ID"] as? String else { return nil }
            let name = entry["Name"] as? String ?? id
            let kind: Destination.Kind =
                (entry["Kind"] as? String == "Network")
                ? .network(url: entry["URL"] as? String)
                : .local
            let isLastUsed = (entry["LastDestination"] as? NSNumber)?.boolValue ?? false
            return Destination(id: id, name: name, kind: kind, isLastUsed: isLastUsed)
        }
    }

    // MARK: - Status

    /// Parses the OpenStep-style dictionary emitted by `tmutil status`.
    ///
    /// The output is prefixed with a human-readable line before the `{`, so we
    /// slice from the first brace and hand the rest to the property-list
    /// reader, which accepts the OpenStep format. Every scalar in that format
    /// decodes as a string, including numbers, which is why `Running` and
    /// `Percent` are read as strings below.
    public static func activity(fromStatusOutput output: String) throws -> BackupActivity {
        // `tmutil status` prefixes the dictionary with a fixed human-readable
        // line ("Backup session status:") that contains no brace, so slicing
        // from the first `{` reaches the dictionary. This assumes Apple's
        // preamble stays brace-free; if that ever changes, parsing fails
        // cleanly with `.noStatusDictionary` rather than misbehaving.
        guard let braceIndex = output.firstIndex(of: "{") else {
            throw ParseError.noStatusDictionary
        }
        let dictText = String(output[braceIndex...])
        guard let dict = try propertyList(from: Data(dictText.utf8)) as? [String: Any] else {
            throw ParseError.noStatusDictionary
        }

        let running = string(dict["Running"]) ?? "0"
        guard running != "0" else { return .idle }

        let destinationID = dict["DestinationID"] as? String
        let phaseName = string(dict["BackupPhase"]) ?? ""

        // A cancellation in progress reports Running = 1 with a Stopping
        // phase; it is a distinct state, so it is matched before the general
        // running case.
        if phaseName == "Stopping" {
            return .stopping(destinationID: destinationID)
        }

        // A backup can report Running = 1 in the instant before backupd sets a
        // phase; treat a missing phase as `.preparing` rather than surfacing a
        // blank `.other("")` the UI would render as an empty label.
        let phase = phaseName.isEmpty ? .preparing : BackupActivity.Phase(rawValue: phaseName)
        return .running(
            destinationID: destinationID,
            phase: phase,
            progress: progress(from: string(dict["Percent"])))
    }

    // MARK: - Helpers

    private static func propertyList(from data: Data) throws -> Any {
        do {
            return try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ParseError.notAPropertyList
        }
    }

    /// OpenStep scalars decode as strings, but XML plists may yield numbers;
    /// normalise both so callers need not care which format produced the value.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// `tmutil` reports `-1` while progress is genuinely unknown; that must
    /// become `nil` (indeterminate), never `0`. A known fraction is clamped
    /// into `0...1` against out-of-range noise.
    private static func progress(from percent: String?) -> Double? {
        guard let percent, let value = Double(percent), value >= 0 else { return nil }
        return min(max(value, 0), 1)
    }
}
