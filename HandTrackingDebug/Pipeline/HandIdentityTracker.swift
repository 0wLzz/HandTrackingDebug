//
//  HandIdentityTracker.swift
//  HandTrackingDebug
//
//  COPY of PlayFeat/Vision/Gestures/HandIdentityTracker.swift (PlayFeat branch
//  refactor/split-hand-pose-manager). Keep it in sync with the game.
//
//  The tracking rules are unchanged. Every `DEBUG` line only *records* what
//  the tracker decided — per hand (`lastDebug`) and as events (`lastEvents`) —
//  so the debug panel can show it. Remove those lines and this is the game's
//  tracker again.
//

import CoreGraphics
import Foundation

struct HandIdentityTracker {

    // MARK: - Tuning

    /// Exponential smoothing applied to each cursor (0 = frozen, 1 = raw).
    var cursorSmoothing: CGFloat = 0.35

    /// How far (in normalized units) a hand may travel between frames and still
    /// be considered the same hand.
    var matchRadius: CGFloat = 0.45

    /// How long a hand's trajectory survives after Vision stops reporting it.
    var gracePeriod: TimeInterval = 0.35

    /// Pinched below `pinchCloseRatio`, apart above `pinchOpenRatio`.
    var pinchCloseRatio: CGFloat = 0.3
    var pinchOpenRatio: CGFloat = 0.5

    /// DEBUG: consecutive agreeing frames before a pinch changes state. The
    /// game uses PinchDetector's default (3); exposed here so it can be tuned.
    var framesToCommit = 3

    // MARK: - State

    private struct TrackedHand {
        let id: Int
        var smoothed: CGPoint
        var pinch: PinchDetector
        var skeleton: [[CGPoint]]
        var lastSeen: TimeInterval
        /// DEBUG: whether this hand was already coasting last frame, so the
        /// start and end of a coast can be logged as events.
        var isCoasting = false

        var published: HandData {
            HandData(
                id: id,
                cursorPosition: smoothed,
                isOpenHand: !pinch.isPinching,
                isClosedFist: pinch.isPinching,
                skeleton: skeleton
            )
        }
    }

    private var tracked: [TrackedHand] = []
    private var nextHandID = 0

    /// DEBUG: what happened to every hand in the last `update`.
    private(set) var lastDebug: [TrackedHandDebug] = []
    /// DEBUG: state changes in the last `update` (appeared, coasting, pinch…).
    private(set) var lastEvents: [TrackerEvent] = []

    // MARK: - Update

    mutating func update(
        with readings: [HandClassifier.Classification],
        at now: TimeInterval
    ) -> [HandData] {
        let assignments = Self.matchAssignments(
            newPositions: readings.map(\.location),
            previousPositions: tracked.map(\.smoothed),
            radius: matchRadius
        )

        var stillTracked: [TrackedHand] = []
        var debug: [TrackedHandDebug] = []   // DEBUG
        var events: [TrackerEvent] = []      // DEBUG

        for (index, reading) in readings.enumerated() {
            var hand: TrackedHand
            let status: TrackedHandDebug.Status          // DEBUG
            var matchDistance: CGFloat?                   // DEBUG
            if let previous = assignments[index] {
                hand = tracked[previous]
                status = .seen
                matchDistance = Self.distance(reading.location, hand.smoothed)
                if hand.isCoasting {
                    events.append(.recovered(id: hand.id, after: now - hand.lastSeen))
                }
            } else {
                hand = TrackedHand(id: nextHandID, smoothed: reading.location,
                                   pinch: PinchDetector(framesToCommit: framesToCommit),
                                   skeleton: reading.skeleton, lastSeen: now)
                nextHandID += 1
                status = .new
                events.append(.appeared(id: hand.id))
            }
            let wasPinching = hand.pinch.isPinching   // DEBUG
            hand.isCoasting = false                   // DEBUG
            hand.lastSeen = now
            hand.skeleton = reading.skeleton

            hand.smoothed = CGPoint(
                x: hand.smoothed.x + (reading.location.x - hand.smoothed.x) * cursorSmoothing,
                y: hand.smoothed.y + (reading.location.y - hand.smoothed.y) * cursorSmoothing
            )

            hand.pinch.framesToCommit = max(1, framesToCommit)   // DEBUG: live tuning
            hand.pinch.record(
                ratio: reading.pinchRatio,
                closeRatio: pinchCloseRatio,
                openRatio: pinchOpenRatio
            )
            if hand.pinch.isPinching != wasPinching {             // DEBUG
                events.append(hand.pinch.isPinching ? .pinchStarted(id: hand.id) : .pinchEnded(id: hand.id))
            }

            stillTracked.append(hand)
            debug.append(TrackedHandDebug(                        // DEBUG
                id: hand.id,
                status: status,
                readingIndex: index,
                matchDistance: matchDistance,
                rawLocation: reading.location,
                smoothed: hand.smoothed,
                pinchRatio: reading.pinchRatio,
                pinchEvidence: hand.pinch.pinchEvidence,
                apartEvidence: hand.pinch.apartEvidence,
                isPinching: hand.pinch.isPinching,
                secondsSinceSeen: 0
            ))
        }

        let matched = Set(assignments.compactMap { $0 })
        for (index, previous) in tracked.enumerated() where !matched.contains(index) {
            let missingFor = now - previous.lastSeen
            // Same rule as the game's `where … now - previous.lastSeen <= gracePeriod`,
            // written out so a drop can be logged.
            guard missingFor <= gracePeriod else {
                events.append(.dropped(id: previous.id, missingFor: missingFor))   // DEBUG
                continue
            }
            var coasting = previous
            if !coasting.isCoasting { events.append(.startedCoasting(id: coasting.id)) }   // DEBUG
            coasting.isCoasting = true                                                   // DEBUG
            coasting.pinch.clearEvidence()
            stillTracked.append(coasting)
            debug.append(TrackedHandDebug(                        // DEBUG
                id: coasting.id,
                status: .coasting,
                readingIndex: nil,
                matchDistance: nil,
                rawLocation: nil,
                smoothed: coasting.smoothed,
                pinchRatio: nil,
                pinchEvidence: coasting.pinch.pinchEvidence,
                apartEvidence: coasting.pinch.apartEvidence,
                isPinching: coasting.pinch.isPinching,
                secondsSinceSeen: missingFor
            ))
        }

        tracked = stillTracked
        lastDebug = debug      // DEBUG
        lastEvents = events    // DEBUG
        return stillTracked.map(\.published)
    }

    // MARK: - Matching

    /// For each freshly detected hand position, the index of the previously
    /// tracked hand it continues — or nil when it's a new hand. Greedy
    /// nearest-neighbour, each previous hand claimable once.
    static func matchAssignments(
        newPositions: [CGPoint],
        previousPositions: [CGPoint],
        radius: CGFloat
    ) -> [Int?] {
        var claimed = Set<Int>()
        var assignments = [Int?](repeating: nil, count: newPositions.count)

        for (index, position) in newPositions.enumerated() {
            var best: Int?
            var bestDistance = radius
            for (candidate, previous) in previousPositions.enumerated() where !claimed.contains(candidate) {
                let gap = Self.distance(position, previous)
                if gap < bestDistance {
                    bestDistance = gap
                    best = candidate
                }
            }
            if let best {
                claimed.insert(best)
                assignments[index] = best
            }
        }
        return assignments
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
