import Foundation
import Testing

@testable import EscapementKit

@Suite("MenuBarSuppression")
struct MenuBarSuppressionTests {

    @Test("knows nothing before any reading")
    func startsUnknown() {
        #expect(MenuBarSuppression().verdict == nil)
    }

    @Test("one unplaced reading is not enough")
    func oneReadingIsNotEnough() {
        var suppression = MenuBarSuppression()
        suppression.observe(.unplaced)
        #expect(suppression.verdict == nil)
    }

    @Test("two consecutive unplaced readings decide it")
    func twoConsecutiveDecide() {
        var suppression = MenuBarSuppression()
        suppression.observe(.unplaced)
        suppression.observe(.unplaced)
        #expect(suppression.verdict == true)
    }

    @Test("a placed reading clears the verdict and the count")
    func placedClears() {
        var suppression = MenuBarSuppression()
        suppression.observe(.unplaced)
        suppression.observe(.unplaced)
        suppression.observe(.placed)
        #expect(suppression.verdict == false)

        suppression.observe(.unplaced)
        #expect(suppression.verdict == false)
    }

    @Test("unplaced readings must be consecutive")
    func mustBeConsecutive() {
        var suppression = MenuBarSuppression()
        suppression.observe(.unplaced)
        suppression.observe(.placed)
        suppression.observe(.unplaced)
        #expect(suppression.verdict == false)
    }

    /// No item is not evidence of suppression — the user is allowed to turn the
    /// icon off, and that must never be reported to them as macOS interfering.
    @Test("no item at all is never suppression")
    func absentIsNotSuppression() {
        var suppression = MenuBarSuppression()
        suppression.observe(.unplaced)
        suppression.observe(.unplaced)
        #expect(suppression.verdict == true)

        suppression.observe(.absent)
        #expect(suppression.verdict == false)
    }

    /// The transient a freshly created item reports says nothing, and must not
    /// disturb a verdict already reached.
    @Test("settling never changes the verdict")
    func settlingIsInert() {
        var suppression = MenuBarSuppression()
        suppression.observe(.settling)
        #expect(suppression.verdict == nil)

        suppression.observe(.unplaced)
        suppression.observe(.unplaced)
        #expect(suppression.verdict == true)

        suppression.observe(.settling)
        #expect(suppression.verdict == true)
    }

    @Test("settling does not break a run of unplaced readings")
    func settlingDoesNotResetTheCount() {
        var suppression = MenuBarSuppression()
        suppression.observe(.unplaced)
        suppression.observe(.settling)
        suppression.observe(.unplaced)
        #expect(suppression.verdict == true)
    }

    /// The defect this tri-state exists to prevent, seen live on macOS 27: an
    /// agent restarting while the icon is genuinely suppressed reads `settling`
    /// first. If that counted as evidence the item was fine, the agent would
    /// publish a confident "not suppressed" over the previous run's correct
    /// verdict and un-explain a hidden icon for a tick or two.
    @Test("a restart while suppressed never claims the icon is fine")
    func restartWhileSuppressedStaysQuiet() {
        var suppression = MenuBarSuppression()
        suppression.observe(.settling)
        #expect(suppression.verdict == nil, "must publish nothing, not false")

        suppression.observe(.unplaced)
        #expect(suppression.verdict == nil, "still not enough to publish")

        suppression.observe(.unplaced)
        #expect(suppression.verdict == true)
    }

    @Test("a restart while permitted reaches a verdict promptly")
    func restartWhilePermitted() {
        var suppression = MenuBarSuppression()
        suppression.observe(.settling)
        suppression.observe(.placed)
        #expect(suppression.verdict == false)
    }
}

@Suite("AgentState menu bar suppression")
struct AgentStateMenuBarTests {

    @Test("the flag round-trips")
    func roundTrips() throws {
        var state = AgentState()
        state.setMenuBarIconSuppressed(true)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AgentState.self, from: data)
        #expect(decoded.menuBarIconSuppressed == true)
    }

    /// The field must be optional in the file as well as the type. A state file
    /// written before it existed has to keep decoding, or the agent's next load
    /// throws and silently discards everything else in it. Every other field an
    /// older agent could have written is present here, because "the pause
    /// survives" is not the claim — "nothing is lost" is.
    @Test("a state file from before the field still decodes, keeping every value")
    func olderStateStillDecodes() throws {
        let json = """
            {
              "pausedUntil": 760000000,
              "waiting": {
                "blockedDestinationID": "B1",
                "holderDestinationID": "B2",
                "since": 759000000
              },
              "lastUpdateCheck": 759500000
            }
            """
        let decoded = try JSONDecoder().decode(AgentState.self, from: Data(json.utf8))
        #expect(decoded.menuBarIconSuppressed == nil)
        #expect(decoded.pausedUntil != nil)
        #expect(decoded.waiting?.blockedDestinationID == "B1")
        #expect(decoded.waiting?.holderDestinationID == "B2")
        #expect(decoded.lastUpdateCheck != nil)
    }
}
