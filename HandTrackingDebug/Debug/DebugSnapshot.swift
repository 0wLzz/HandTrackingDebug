//
//  DebugSnapshot.swift
//  HandTrackingDebug
//
//  Everything the pipeline decided about one camera frame, as plain values.
//  Built on the video queue, then handed to the UI in one piece, so the panel
//  always shows one consistent frame.
//

import CoreGraphics
import Foundation

struct DebugSnapshot {
    let frameNumber: Int
    /// Time spent on this frame: Vision + body filter + tracker.
    let processingMilliseconds: Double
    /// Frame size after rotation — what `CameraViewMapping` maps from.
    let bufferSize: CGSize
    /// Set when `VNImageRequestHandler.perform` threw; the game then publishes
    /// no new readings for that frame (only coasting hands).
    let visionError: String?

    // Body
    let bodyPoseRanThisFrame: Bool
    let bodySource: BodySource
    let bodies: [BodyDebug]

    // Hands, in pipeline order
    let observations: [ObservationDebug]
    let modeName: String
    let handLimit: Int
    let tracked: [TrackedHandDebug]
    /// Exactly what PlayFeat's `HandPoseManager.hands` would contain.
    let output: [HandData]
    let events: [TrackerEvent]
}

/// Where this frame's bodies came from.
enum BodySource: String {
    case detectedThisFrame = "Detected this frame"
    case reusedBetweenRuns = "Reused (body pose only runs every Nth frame)"
    case heldByGracePeriod = "Held from earlier (detector found none, grace period)"
    case none = "No body"
}

struct BodyDebug: Identifiable {
    let id: Int
    let body: HumanBodyPoseManager.BodyCandidate
    /// The nearest (widest-shouldered) body — the only one whose hands count.
    let isPlayer: Bool
    /// Shoulder span, normalized. The yardstick for `reach`.
    let scale: CGFloat
    /// How far a hand's wrist may be from this body's wrist: scale × tolerance.
    let reach: CGFloat
}

/// One raw hand Vision reported, before any filtering.
struct ObservationDebug: Identifiable {
    var id: Int { index }
    let index: Int
    /// Vision's overall confidence in the observation.
    let confidence: Float
    /// Vision's left/right guess. The feed is mirrored at source, so this is
    /// usually the opposite of the player's real hand.
    let chirality: String
    let joints: [JointDebug]
    /// Set when `HandClassifier` could read the hand.
    let reading: HandClassifier.Classification?
    /// Set when it couldn't — why.
    let rejection: String?
    /// The body filter's verdict. Nil when the hand was never classified.
    var filter: HandFilterDebug?

    var trustedJointCount: Int { joints.filter(\.isTrusted).count }

    func joint(_ name: String) -> JointDebug? { joints.first { $0.name == name } }
}

struct JointDebug {
    let name: String
    let location: CGPoint
    let confidence: Float
    /// At or above the joint confidence threshold — the only joints the
    /// classifier uses.
    let isTrusted: Bool
}

/// Why the body filter kept or dropped a hand. Mirrors the checks in
/// `HumanBodyPoseManager.playerHandIndices`.
struct HandFilterDebug {
    let isKept: Bool
    let reason: String
    /// Distance from this hand's wrist to the nearest player wrist the mode allows.
    let distanceToPlayerWrist: CGFloat?
    /// The allowed distance (player's shoulder span × wrist tolerance).
    let reach: CGFloat?
    /// Distance to the nearest wrist of anyone else in frame.
    let distanceToOtherPerson: CGFloat?
}

/// What the identity tracker did with one hand this frame.
struct TrackedHandDebug: Identifiable {
    enum Status: String {
        case new = "NEW"
        case seen = "SEEN"
        case coasting = "COASTING"
    }

    let id: Int
    let status: Status
    /// Index into the readings that survived the body filter.
    let readingIndex: Int?
    /// How far the reading was from where this hand was last frame.
    let matchDistance: CGFloat?
    /// This frame's palm centre, before smoothing. Nil while coasting.
    let rawLocation: CGPoint?
    /// The cursor the game uses.
    let smoothed: CGPoint
    let pinchRatio: CGFloat?
    let pinchEvidence: Int
    let apartEvidence: Int
    let isPinching: Bool
    /// 0 when seen this frame; grows while coasting.
    let secondsSinceSeen: TimeInterval
    /// Which raw Vision observation this hand came from (filled in by the
    /// frame processor). Nil while coasting.
    var observationIndex: Int?
}

/// A change in a hand's state, as it happened.
enum TrackerEvent {
    case appeared(id: Int)
    case startedCoasting(id: Int)
    case recovered(id: Int, after: TimeInterval)
    case dropped(id: Int, missingFor: TimeInterval)
    case pinchStarted(id: Int)
    case pinchEnded(id: Int)

    var text: String {
        switch self {
        case .appeared(let id): "Hand #\(id) appeared (new ID)"
        case .startedCoasting(let id): "Hand #\(id) not seen — coasting"
        case .recovered(let id, let after): "Hand #\(id) seen again after \(Format.ms(after))"
        case .dropped(let id, let missing): "Hand #\(id) dropped — missing \(Format.ms(missing)) > grace period"
        case .pinchStarted(let id): "Hand #\(id) PINCH committed (grab)"
        case .pinchEnded(let id): "Hand #\(id) released (open)"
        }
    }

    var isProblem: Bool {
        switch self {
        case .startedCoasting, .dropped: true
        default: false
        }
    }
}

enum Format {
    static func n(_ value: CGFloat, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", Double(value))
    }
    static func n(_ value: Double, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", value)
    }
    static func n(_ value: Float, _ digits: Int = 2) -> String {
        String(format: "%.\(digits)f", Double(value))
    }
    static func point(_ p: CGPoint) -> String {
        "(\(n(p.x)), \(n(p.y)))"
    }
    static func ms(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }
}
