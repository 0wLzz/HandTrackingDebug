//
//  PinchDetector.swift
//  HandTrackingDebug
//
//  COPY of PlayFeat/Vision/Gestures/PinchDetector.swift (PlayFeat commit bd4fa6d).
//  Keep it in sync with the game. Debug-only changes are marked `DEBUG`.
//
//  Decides pinched / open from a run of frames, not a single one.
//

import CoreGraphics

struct PinchDetector: Equatable {

    /// Consecutive agreeing frames needed before the state actually changes.
    ///
    /// Three at 30Hz is about a tenth of a second — long enough to outlast the
    /// stray bad frame, short enough that the player never feels it.
    var framesToCommit: Int = 3

    private(set) var isPinching = false

    private(set) var pinchEvidence = 0   // DEBUG: readable so the panel can show it
    private(set) var apartEvidence = 0   // DEBUG: readable so the panel can show it

    init(framesToCommit: Int = 3) {
        self.framesToCommit = max(1, framesToCommit)
    }

    /// Feeds one frame's measurement in.
    ///
    /// `ratio` is the thumb-to-index gap in palm lengths, or nil when it
    /// couldn't be measured at all. Nil is **not** evidence of being apart:
    /// a hand whose thumb briefly drops out of tracking keeps whatever state
    /// it had, because "I can't see it" and "it is open" are different claims.
    /// Treating them the same is what made a grab let go on one bad frame.
    mutating func record(ratio: CGFloat?, closeRatio: CGFloat, openRatio: CGFloat) {
        guard let ratio else { return }

        if ratio <= closeRatio {
            pinchEvidence += 1
            apartEvidence = 0
        } else if ratio >= openRatio {
            apartEvidence += 1
            pinchEvidence = 0
        } else {
            // Between the two thresholds the reading is ambiguous, so neither
            // side gains ground and the hand holds its state. This is the
            // hysteresis band; without it a hand hovering right at the
            // boundary would chatter.
            return
        }

        if pinchEvidence >= framesToCommit { isPinching = true }
        if apartEvidence >= framesToCommit { isPinching = false }
    }

    /// Forgets accumulated evidence but keeps the committed state — used when
    /// a hand goes missing, so it resumes from what it was rather than from a
    /// half-built case for the opposite.
    mutating func clearEvidence() {
        pinchEvidence = 0
        apartEvidence = 0
    }
}
