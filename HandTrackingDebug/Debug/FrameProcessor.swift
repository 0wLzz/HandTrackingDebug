//
//  FrameProcessor.swift
//  HandTrackingDebug
//
//  Runs one camera frame through the same steps, in the same order, as
//  PlayFeat's `HandPoseManager.process(pixelBuffer:)`:
//
//    1. Vision: hand pose (every frame) + body pose (every Nth frame)
//    2. Body: which bodies exist, which one is the player
//    3. HandClassifier: palm, wrist, pinch gap for each raw hand
//    4. Body filter: keep only hands on the player's wrists (input mode, limit)
//    5. HandIdentityTracker: stable IDs, smoothing, pinch, coasting
//
//  The difference: instead of publishing only the final hands, it records what
//  every step decided into a `DebugSnapshot`.
//
//  Used only on the camera's video queue.
//

import CoreGraphics
import QuartzCore
import Vision

final class FrameProcessor {
    var settings = PipelineSettings() {
        didSet { applySettings() }
    }

    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private let bodyPose = HumanBodyPoseManager()
    private var tracker = HandIdentityTracker()
    private var frameNumber = 0

    init() {
        applySettings()
    }

    private func applySettings() {
        handPoseRequest.maximumHandCount = settings.handCandidateLimit
        bodyPose.jointConfidenceThreshold = settings.jointConfidenceThreshold
        bodyPose.wristMatchTolerance = settings.wristMatchTolerance
        bodyPose.bodyPoseFrameInterval = settings.bodyPoseFrameInterval
        bodyPose.bodyGracePeriod = settings.bodyGracePeriod
        tracker.cursorSmoothing = settings.cursorSmoothing
        tracker.matchRadius = settings.matchRadius
        tracker.gracePeriod = settings.gracePeriod
        tracker.pinchCloseRatio = settings.pinchCloseRatio
        tracker.pinchOpenRatio = settings.pinchOpenRatio
        tracker.framesToCommit = settings.framesToCommit
    }

    // MARK: - One frame

    func process(_ pixelBuffer: CVPixelBuffer) -> DebugSnapshot {
        let started = CACurrentMediaTime()
        frameNumber += 1

        let bufferSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        // 1. Vision — one handler, so the image is decoded once.
        let runsBodyPose = bodyPose.shouldRunBodyPose(tracksSinglePlayer: true)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        var visionError: String?
        do {
            try handler.perform(runsBodyPose ? [handPoseRequest, bodyPose.bodyPoseRequest]
                                             : [handPoseRequest])
        } catch {
            visionError = error.localizedDescription
        }

        // 2. Bodies
        let bodySource = updateBodies(ranThisFrame: runsBodyPose && visionError == nil)
        let bodies = bodyPose.lastBodies
        let playerIndex = HumanBodyPoseManager.nearestBody(in: bodies)
        let bodyDebugs = bodies.indices.map { index in
            BodyDebug(
                id: index,
                body: bodies[index],
                isPlayer: index == playerIndex,
                scale: bodies[index].scale,
                reach: bodies[index].scale * settings.wristMatchTolerance
            )
        }

        // 3. Classify every raw hand
        let observations = visionError == nil ? (handPoseRequest.results ?? []) : []
        var observationDebugs: [ObservationDebug] = []
        var classified: [(observationIndex: Int, reading: HandClassifier.Classification)] = []

        for (index, observation) in observations.enumerated() {
            var reading: HandClassifier.Classification?
            var rejection: String?
            do {
                reading = try HandClassifier.classify(
                    observation,
                    jointConfidenceThreshold: settings.jointConfidenceThreshold
                )
            } catch HandClassifier.ClassificationError.noReliableWrist {
                rejection = "Wrist not visible with enough confidence"
            } catch HandClassifier.ClassificationError.noReliablePalm {
                rejection = "No knuckle visible — palm length can't be measured"
            } catch {
                rejection = error.localizedDescription
            }
            if let reading { classified.append((index, reading)) }

            observationDebugs.append(ObservationDebug(
                index: index,
                confidence: observation.confidence,
                chirality: Self.chiralityName(observation.chirality),
                joints: Self.joints(of: observation, threshold: settings.jointConfidenceThreshold),
                reading: reading,
                rejection: rejection,
                filter: nil
            ))
        }

        // 4. Body filter — the exact call the game makes…
        let mode = settings.mode.inputMode
        let limit = min(settings.maximumHandCount, mode.handCount)
        let wrists = classified.map { $0.reading.wrist }
        let keep = classified.isEmpty ? [] : (HumanBodyPoseManager.playerHandIndices(
            handWrists: wrists,
            bodies: bodies,
            wristTolerance: settings.wristMatchTolerance,
            limit: limit,
            mode: mode
        ) ?? [])

        // …plus the reasons behind it.
        let verdicts = HandFilterExplainer.explain(
            handWrists: wrists,
            bodies: bodies,
            playerIndex: playerIndex,
            tolerance: settings.wristMatchTolerance,
            mode: mode,
            kept: Set(keep),
            limit: limit
        )
        for (classifiedIndex, item) in classified.enumerated() {
            observationDebugs[item.observationIndex].filter = verdicts[classifiedIndex]
        }

        // 5. Identity tracker
        let keptReadings = keep.map { classified[$0].reading }
        let keptObservationIndices = keep.map { classified[$0].observationIndex }
        let hands = tracker.update(with: keptReadings, at: CACurrentMediaTime())
        let trackedDebug = tracker.lastDebug.map { entry -> TrackedHandDebug in
            var entry = entry
            entry.observationIndex = entry.readingIndex.map { keptObservationIndices[$0] }
            return entry
        }

        return DebugSnapshot(
            frameNumber: frameNumber,
            processingMilliseconds: (CACurrentMediaTime() - started) * 1000,
            bufferSize: bufferSize,
            visionError: visionError,
            bodyPoseRanThisFrame: runsBodyPose,
            bodySource: bodySource,
            bodies: bodyDebugs,
            observations: observationDebugs,
            modeName: settings.mode.rawValue,
            handLimit: limit,
            tracked: trackedDebug,
            output: hands,
            events: tracker.lastEvents
        )
    }

    // MARK: - Steps

    /// Feeds this frame's body results in (when body pose ran) and reports
    /// where the bodies the filter will use came from.
    private func updateBodies(ranThisFrame: Bool) -> BodySource {
        guard ranThisFrame else {
            return bodyPose.lastBodies.isEmpty ? .none : .reusedBetweenRuns
        }
        let results = bodyPose.bodyPoseRequest.results
        let foundNow = (results ?? []).contains {
            HumanBodyPoseManager.bodyCandidate(
                from: $0,
                jointConfidenceThreshold: settings.jointConfidenceThreshold
            ) != nil
        }
        bodyPose.processObservations(results)
        if foundNow { return .detectedThisFrame }
        return bodyPose.lastBodies.isEmpty ? .none : .heldByGracePeriod
    }

    // MARK: - Raw joints

    /// All 21 hand joints, in finger order. The names are what the overlay
    /// and panel show.
    static let jointNames: [(VNHumanHandPoseObservation.JointName, String)] = [
        (.wrist, "wrist"),
        (.thumbCMC, "thumbCMC"), (.thumbMP, "thumbMP"), (.thumbIP, "thumbIP"), (.thumbTip, "thumbTip"),
        (.indexMCP, "indexMCP"), (.indexPIP, "indexPIP"), (.indexDIP, "indexDIP"), (.indexTip, "indexTip"),
        (.middleMCP, "middleMCP"), (.middlePIP, "middlePIP"), (.middleDIP, "middleDIP"), (.middleTip, "middleTip"),
        (.ringMCP, "ringMCP"), (.ringPIP, "ringPIP"), (.ringDIP, "ringDIP"), (.ringTip, "ringTip"),
        (.littleMCP, "littleMCP"), (.littlePIP, "littlePIP"), (.littleDIP, "littleDIP"), (.littleTip, "littleTip")
    ]

    /// The bones drawn on the overlay: wrist → each fingertip.
    static let fingerChains: [[String]] = [
        ["wrist", "thumbCMC", "thumbMP", "thumbIP", "thumbTip"],
        ["wrist", "indexMCP", "indexPIP", "indexDIP", "indexTip"],
        ["wrist", "middleMCP", "middlePIP", "middleDIP", "middleTip"],
        ["wrist", "ringMCP", "ringPIP", "ringDIP", "ringTip"],
        ["wrist", "littleMCP", "littlePIP", "littleDIP", "littleTip"]
    ]

    private static func joints(of observation: VNHumanHandPoseObservation, threshold: Float) -> [JointDebug] {
        guard let points = try? observation.recognizedPoints(.all) else { return [] }
        return jointNames.compactMap { name, label in
            guard let point = points[name] else { return nil }
            return JointDebug(
                name: label,
                location: point.location,
                confidence: point.confidence,
                isTrusted: point.confidence >= threshold
            )
        }
    }

    private static func chiralityName(_ chirality: VNChirality) -> String {
        switch chirality {
        case .left: "left"
        case .right: "right"
        default: "unknown"
        }
    }
}

// MARK: - Body filter reasons

/// Repeats the checks in `HumanBodyPoseManager.playerHandIndices`, one hand at
/// a time, to say *why* each hand was kept or dropped. Whether it was kept
/// always comes from the real function (`kept`); this only adds the reason.
enum HandFilterExplainer {
    static func explain(
        handWrists: [CGPoint],
        bodies: [HumanBodyPoseManager.BodyCandidate],
        playerIndex: Int?,
        tolerance: CGFloat,
        mode: any HandInputMode,
        kept: Set<Int>,
        limit: Int
    ) -> [HandFilterDebug] {
        handWrists.indices.map { index in
            let hand = handWrists[index]
            let isKept = kept.contains(index)

            guard let playerIndex else {
                return HandFilterDebug(
                    isKept: isKept,
                    reason: "No body in frame — a hand only counts when attached to a visible shoulder",
                    distanceToPlayerWrist: nil, reach: nil, distanceToOtherPerson: nil
                )
            }

            let player = bodies[playerIndex]
            let reach = player.scale * tolerance
            let playerWrists = mode.playerWrists(of: player)
            let toPlayer = playerWrists.map { distance($0, hand) }.min()
            let toOthers = bodies.indices
                .filter { $0 != playerIndex && bodies[$0].scale > 0 }
                .compactMap { other in bodies[other].wrists.map { distance($0, hand) }.min() }
                .min()

            let reason: String
            if isKept {
                reason = "Kept — on the player's wrist"
            } else if toPlayer == nil {
                reason = "The player's wrist for this mode isn't visible"
            } else if let toPlayer, toPlayer > reach {
                reason = "Too far from the player's wrist (\(Format.n(toPlayer)) > reach \(Format.n(reach)))"
            } else if let toPlayer, let toOthers, toPlayer > toOthers {
                reason = "Closer to another person's wrist"
            } else {
                reason = "Over the hand limit (\(limit)) — a closer hand won"
            }

            return HandFilterDebug(
                isKept: isKept,
                reason: reason,
                distanceToPlayerWrist: toPlayer,
                reach: reach,
                distanceToOtherPerson: toOthers
            )
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
