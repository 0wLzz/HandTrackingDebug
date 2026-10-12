//
//  PipelineSettings.swift
//  HandTrackingDebug
//
//  Every tuning knob that changes where a hand is or what state it's in.
//  Defaults are PlayFeat's values, so the app starts out behaving exactly like
//  the game; "Reset to PlayFeat values" brings them back.
//

import CoreGraphics
import Foundation

struct PipelineSettings: Equatable {
    // HandClassifier + body detector
    /// Joints below this Vision confidence are ignored.
    var jointConfidenceThreshold: Float = 0.25

    // HandIdentityTracker
    var cursorSmoothing: CGFloat = 0.35
    var matchRadius: CGFloat = 0.45
    var gracePeriod: TimeInterval = 0.35
    var pinchCloseRatio: CGFloat = 0.3
    var pinchOpenRatio: CGFloat = 0.5
    var framesToCommit = 3

    // Body filter (HumanBodyPoseManager)
    var wristMatchTolerance: CGFloat = 0.6
    var bodyPoseFrameInterval = 3
    var bodyGracePeriod: TimeInterval = 0.6

    // HandPoseManager
    var maximumHandCount = 2
    var handCandidateLimit = 4
    var mode: ModeChoice = .twoHands
}

enum ModeChoice: String, CaseIterable, Identifiable {
    case twoHands = "Two hands"
    case leftHand = "Left hand"
    case rightHand = "Right hand"

    var id: String { rawValue }

    var inputMode: any HandInputMode {
        switch self {
        case .twoHands: TwoHandMode()
        case .leftHand: OneHandMode(hand: .left)
        case .rightHand: OneHandMode(hand: .right)
        }
    }
}
