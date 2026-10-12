//
//  HandInputModes.swift
//  HandTrackingDebug
//
//  COPY of PlayFeat/Vision/HandSide.swift and Vision/InputModes/ (PlayFeat
//  commit bd4fa6d), trimmed to what hand tracking uses: which side, how many
//  hands, and which of the body's wrists belong to the player. The seat-check
//  text and localization are left out.
//

import CoreGraphics

enum HandSide: String, CaseIterable {
    case left
    case right
}

protocol HandInputMode {
    /// How many hands the game follows.
    var handCount: Int { get }

    /// The wrists on `body` whose hands belong to the player in this mode.
    /// Empty when none of them was seen this frame.
    func playerWrists(of body: HumanBodyPoseManager.BodyCandidate) -> [CGPoint]
}

extension HandInputMode {
    /// Whether every hand this mode plays with is visible on `body`.
    func seesEveryHand(on body: HumanBodyPoseManager.BodyCandidate) -> Bool {
        playerWrists(of: body).count == handCount
    }
}

struct TwoHandMode: HandInputMode {
    let handCount = 2

    func playerWrists(of body: HumanBodyPoseManager.BodyCandidate) -> [CGPoint] {
        body.wrists
    }
}

struct OneHandMode: HandInputMode {
    /// The hand the player chose in Settings.
    let hand: HandSide

    let handCount = 1

    func playerWrists(of body: HumanBodyPoseManager.BodyCandidate) -> [CGPoint] {
        body.wrist(on: hand).map { [$0] } ?? []
    }
}
