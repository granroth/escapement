import Foundation
import Testing

@testable import EscapementKit

@Suite("BackupProgressFormatter")
struct BackupProgressFormatterTests {
    private let formatter = BackupProgressFormatter(locale: Locale(identifier: "en_US"))

    @Test("formats copied bytes and Apple's approximate multi-day estimate")
    func bytesAndDays() {
        let progress = BackupProgress(
            bytesCopied: 250_000_000_000,
            timeRemaining: 432_000)
        #expect(formatter.detail(progress) == "250 GB copied — About 5 days remaining")
    }

    @Test("formats either detail independently")
    func partialDetails() {
        #expect(
            formatter.detail(BackupProgress(bytesCopied: 1_500_000))
                == "1.5 MB copied")
        #expect(
            formatter.detail(BackupProgress(timeRemaining: 8 * 60))
                == "About 8 minutes remaining")
    }

    @Test("does not round a positive sub-kilobyte count down to zero")
    func byteUnits() {
        #expect(
            formatter.detail(BackupProgress(bytesCopied: 1))
                == "1 byte copied")
        #expect(
            formatter.detail(BackupProgress(bytesCopied: 500))
                == "500 bytes copied")
    }

    @Test("returns no detail when Time Machine has no byte or time estimate")
    func noDetails() {
        #expect(formatter.detail(BackupProgress(fractionCompleted: 0.2)) == nil)
    }
}
