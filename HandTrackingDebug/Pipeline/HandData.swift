//
//  HandData.swift
//  HandTrackingDebug
//
//  COPY of PlayFeat/Vision/HandData.swift (PlayFeat commit bd4fa6d).
//  Keep it in sync with the game. Debug-only changes are marked `DEBUG`.
//
//  One tracked hand, as the game receives it.
//

import SwiftUI

/// One tracked hand, as published to the UI and the scene.
///
/// `id` is stable across frames — see `HandIdentityTracker`. Without that,
/// two-handed play breaks the moment Vision reorders its observations, because
/// each hand would inherit the other's grab.
struct HandData: Identifiable, Equatable {
    let id: Int
    /// Palm centre in *normalized Vision space* (origin bottom-left, 0...1).
    var cursorPosition: CGPoint
    /// Not grabbing. Anything that isn't an active thumb-to-index-finger
    /// pinch is open, a clenched fist included.
    var isOpenHand: Bool
    /// Grabbing: thumb tip and index-finger tip pinched together.
    var isClosedFist: Bool
    /// One chain of joints per finger (thumb → little), normalized Vision space.
    var skeleton: [[CGPoint]]

    /// Every detected joint of this hand as a flat list.
    var recognizedJoints: [CGPoint] { skeleton.flatMap { $0 } }
}
