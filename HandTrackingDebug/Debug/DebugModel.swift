//
//  DebugModel.swift
//  HandTrackingDebug
//
//  What the screen shows: the latest snapshot, the event log, frame rate,
//  the tuning settings and the overlay toggles. Touched only on the main
//  thread; frames are processed on the camera queue and handed over here.
//

import Foundation
import QuartzCore
import SwiftUI

@Observable
final class DebugModel {
    /// The frame on screen. Stops updating while frozen.
    private(set) var snapshot: DebugSnapshot?
    private(set) var events: [LoggedEvent] = []
    private(set) var framesPerSecond: Double = 0
    private(set) var cameraStatus = "Starting camera…"

    /// Holds the current frame on screen so the numbers can be read.
    /// Processing keeps running, and events keep being logged.
    var isFrozen = false

    var settings = PipelineSettings() {
        didSet {
            guard settings != oldValue else { return }
            let newSettings = settings
            let processor = self.processor
            feed.videoQueue.async { processor.settings = newSettings }
        }
    }

    var overlay = OverlayOptions()

    /// Practice board: grab ingredients at the top, drop them on the plate,
    /// carry the plate to the side — PlayFeat's rules, no artwork.
    let practice = PracticeBoard()
    var isPracticing = false {
        didSet { if isPracticing { practice.reset() } }
    }
    /// Size of the camera area, where the board is laid out.
    @ObservationIgnored var cameraAreaSize: CGSize = .zero

    let feed = CameraFeed()
    private let processor = FrameProcessor()
    @ObservationIgnored private var frameTimes: [CFTimeInterval] = []
    @ObservationIgnored private var hasStarted = false

    init() {
        let processor = self.processor
        feed.onFrame = { [weak self] pixelBuffer in
            let snapshot = processor.process(pixelBuffer)   // camera queue
            DispatchQueue.main.async { self?.receive(snapshot) }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        feed.start { [weak self] granted in
            self?.cameraStatus = granted
                ? "Running"
                : "Camera access denied — allow it in Settings › Privacy › Camera"
        }
    }

    func resetSettings() {
        settings = PipelineSettings()
    }

    func clearEvents() {
        events.removeAll()
    }

    // MARK: - Frames

    private func receive(_ snapshot: DebugSnapshot) {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        framesPerSecond = Double(frameTimes.count)

        let newEvents = snapshot.events.map {
            LoggedEvent(frame: snapshot.frameNumber, date: Date(), event: $0)
        }
        if !newEvents.isEmpty {
            events.insert(contentsOf: newEvents.reversed(), at: 0)
            if events.count > 200 { events.removeLast(events.count - 200) }
        }

        guard !isFrozen else { return }
        self.snapshot = snapshot
        if isPracticing {
            practice.update(
                hands: snapshot.output,
                mapping: CameraViewMapping(bufferSize: snapshot.bufferSize, gravity: feed.previewGravity),
                viewSize: cameraAreaSize,
                now: now
            )
        }
    }
}

struct LoggedEvent: Identifiable {
    let id = UUID()
    let frame: Int
    let date: Date
    let event: TrackerEvent
}

struct OverlayOptions {
    var showRawJoints = true
    var showLowConfidenceJoints = true
    var showMatchRadius = true
    var showBodies = true
    var showPinchGap = true
    var showLabels = true
}
