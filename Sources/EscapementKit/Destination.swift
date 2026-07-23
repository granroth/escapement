import Foundation

/// A Time Machine backup destination, as reported by `tmutil destinationinfo`.
///
/// Escapement never creates or configures these — they are set up in System
/// Settings — so this type is a read-only view. It is `Identifiable` by the
/// `id` that `tmutil` assigns, which is also the value passed to
/// `startbackup --destination`.
public struct Destination: Identifiable, Hashable, Sendable, Codable {

    public enum Kind: Hashable, Sendable, Codable {
        case local
        /// A network share. The URL is what `tmutil` reports (e.g. an
        /// `smb://` address); it is kept verbatim for display and carries no
        /// guarantee of being a resolvable `URL`, so it stays a string.
        case network(url: String?)
    }

    public let id: String
    public let name: String
    public let kind: Kind

    /// Whether `tmutil` marks this as the most recently used destination.
    /// Absent from all but at most one destination.
    public let isLastUsed: Bool

    public init(id: String, name: String, kind: Kind, isLastUsed: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isLastUsed = isLastUsed
    }
}
