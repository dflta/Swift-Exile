import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct FocusReclaimPolicyTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func noActionWhilePanelKeepsFocus() {
        var policy = FocusReclaimPolicy()
        policy.began(at: start)
        #expect(policy.decide(now: start.addingTimeInterval(0.1), isInteractable: true, panelIsKey: true, gameFrontmost: true) == .none)
    }

    @Test func retakesThenActivatesOnLastAttemptThenGivesUpOnce() {
        var policy = FocusReclaimPolicy(window: 1.5, maxAttempts: 3)
        policy.began(at: start)
        let stolen = { (t: Double, p: inout FocusReclaimPolicy) in
            p.decide(now: self.start.addingTimeInterval(t), isInteractable: true, panelIsKey: false, gameFrontmost: true)
        }
        #expect(stolen(0.05, &policy) == .retake(activateApp: false))
        #expect(stolen(0.10, &policy) == .retake(activateApp: false))
        #expect(stolen(0.20, &policy) == .retake(activateApp: true))
        #expect(stolen(0.30, &policy) == .giveUp)
        #expect(stolen(0.40, &policy) == .none)
    }

    @Test func noRetakeAfterWindow() {
        var policy = FocusReclaimPolicy(window: 1.5, maxAttempts: 3)
        policy.began(at: start)
        // A switch to the game long after opening the overlay is the user's choice, not a steal.
        #expect(policy.decide(now: start.addingTimeInterval(5), isInteractable: true, panelIsKey: false, gameFrontmost: true) == .none)
    }

    @Test func noRetakeWhenAnotherAppIsFrontmost() {
        var policy = FocusReclaimPolicy()
        policy.began(at: start)
        // The user switched to another app (e.g. Chrome): hide, don't fight.
        #expect(policy.decide(now: start.addingTimeInterval(0.2), isInteractable: true, panelIsKey: false, gameFrontmost: false) == .none)
    }

    @Test func noRetakeAfterEnded() {
        var policy = FocusReclaimPolicy()
        policy.began(at: start)
        policy.ended()
        #expect(policy.decide(now: start.addingTimeInterval(0.1), isInteractable: true, panelIsKey: false, gameFrontmost: true) == .none)
    }

    @Test func newSessionResetsAttempts() {
        var policy = FocusReclaimPolicy(window: 1.5, maxAttempts: 1)
        policy.began(at: start)
        #expect(policy.decide(now: start.addingTimeInterval(0.1), isInteractable: true, panelIsKey: false, gameFrontmost: true) == .retake(activateApp: true))
        let later = start.addingTimeInterval(10)
        policy.began(at: later)
        #expect(policy.attempts == 0)
        #expect(policy.decide(now: later.addingTimeInterval(0.1), isInteractable: true, panelIsKey: false, gameFrontmost: true) == .retake(activateApp: true))
    }
}
