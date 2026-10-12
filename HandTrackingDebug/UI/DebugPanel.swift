//
//  DebugPanel.swift
//  HandTrackingDebug
//
//  Every value behind a hand's position and state, in pipeline order:
//  frame → bodies → raw Vision hands → body filter → tracker → what the game
//  receives. Plus the event log and live tuning.
//

import SwiftUI

struct DebugPanel: View {
    @Bindable var model: DebugModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                if model.isPracticing {
                    PracticeSection(board: model.practice, onReset: model.practice.reset)
                }
                if let snapshot = model.snapshot {
                    FrameSection(snapshot: snapshot, fps: model.framesPerSecond)
                    OutputSection(snapshot: snapshot)
                    TrackerSection(snapshot: snapshot, settings: model.settings)
                    ObservationsSection(snapshot: snapshot, settings: model.settings)
                    BodiesSection(snapshot: snapshot)
                } else {
                    Text("Waiting for the first frame…").foregroundStyle(.secondary)
                }
                EventLogSection(events: model.events, onClear: model.clearEvents)
                TuningSection(model: model)
            }
            .padding(14)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.isFrozen ? "Resume" : "Freeze frame") { model.isFrozen.toggle() }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isFrozen ? .yellow : .blue)
                Spacer()
            }
            Toggle("Practice: grab & serve", isOn: $model.isPracticing)
                .bold()
            Toggle("Raw joints", isOn: $model.overlay.showRawJoints)
            Toggle("Low-confidence joints", isOn: $model.overlay.showLowConfidenceJoints)
            Toggle("Pinch gap", isOn: $model.overlay.showPinchGap)
            Toggle("Match radius", isOn: $model.overlay.showMatchRadius)
            Toggle("Bodies & wrist reach", isOn: $model.overlay.showBodies)
            Toggle("Labels", isOn: $model.overlay.showLabels)
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Building blocks

struct PanelSection<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(.white)
            if let caption {
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    init(_ label: String, _ value: String, color: Color = .primary) {
        self.label = label
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
        }
    }
}

/// The pinch gap on a 0 – 1.2 scale: orange = pinch zone (≤ close),
/// grey = dead zone (no change), green = open zone (≥ open), white tick = now.
struct PinchGauge: View {
    let ratio: CGFloat?
    let close: CGFloat
    let open: CGFloat
    private let maximum: CGFloat = 1.2

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.green.opacity(0.35))
                Rectangle().fill(Color.gray.opacity(0.6))
                    .frame(width: position(open, in: width))
                Rectangle().fill(Color.orange.opacity(0.7))
                    .frame(width: position(close, in: width))
                if let ratio {
                    Rectangle().fill(Color.white)
                        .frame(width: 3)
                        .offset(x: position(ratio, in: width) - 1.5)
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func position(_ value: CGFloat, in width: CGFloat) -> CGFloat {
        min(max(value / maximum, 0), 1) * width
    }
}

/// `count` of `total` frames of evidence, as dots.
struct EvidenceDots: View {
    let count: Int
    let total: Int
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Circle()
                    .fill(index < count ? color : Color.gray.opacity(0.3))
                    .frame(width: 9, height: 9)
            }
        }
    }
}

// MARK: - Sections

struct FrameSection: View {
    let snapshot: DebugSnapshot
    let fps: Double

    var body: some View {
        PanelSection("Frame #\(snapshot.frameNumber)") {
            InfoRow("Frame rate", "\(Int(fps)) fps")
            InfoRow("Processing", "\(Format.n(snapshot.processingMilliseconds, 1)) ms",
                    color: snapshot.processingMilliseconds > 33 ? .orange : .primary)
            InfoRow("Buffer (after rotation)", "\(Int(snapshot.bufferSize.width))×\(Int(snapshot.bufferSize.height))")
            InfoRow("Body pose ran", snapshot.bodyPoseRanThisFrame ? "yes" : "no (reusing)")
            InfoRow("Input mode", "\(snapshot.modeName), limit \(snapshot.handLimit)")
            if let error = snapshot.visionError {
                InfoRow("Vision error", error, color: .red)
            }
        }
    }
}

struct OutputSection: View {
    let snapshot: DebugSnapshot

    var body: some View {
        PanelSection("Sent to the game (\(snapshot.output.count))",
                     caption: "Exactly what HandPoseManager.hands would hold. GameScene keys everything on these IDs.") {
            if snapshot.output.isEmpty {
                Text("No hands").foregroundStyle(.secondary)
            }
            ForEach(snapshot.output) { hand in
                InfoRow("#\(hand.id)",
                        "\(Format.point(hand.cursorPosition)) \(hand.isClosedFist ? "PINCH" : "open")",
                        color: hand.isClosedFist ? .orange : .green)
            }
        }
    }
}

struct TrackerSection: View {
    let snapshot: DebugSnapshot
    let settings: PipelineSettings

    var body: some View {
        PanelSection("Identity tracker (\(snapshot.tracked.count))",
                     caption: "Matching, smoothing, pinch evidence and the grace period, per hand.") {
            if snapshot.tracked.isEmpty {
                Text("Not tracking any hand").foregroundStyle(.secondary)
            }
            ForEach(snapshot.tracked) { hand in
                TrackedHandCard(hand: hand, settings: settings)
            }
        }
    }
}

struct TrackedHandCard: View {
    let hand: TrackedHandDebug
    let settings: PipelineSettings

    private var statusColor: Color {
        switch hand.status {
        case .new: .cyan
        case .seen: hand.isPinching ? .orange : .green
        case .coasting: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Hand #\(hand.id)").bold()
                Text(hand.status.rawValue)
                    .padding(.horizontal, 6)
                    .background(statusColor.opacity(0.3), in: Capsule())
                Spacer()
                Text(hand.isPinching ? "PINCH" : "open").bold().foregroundStyle(hand.isPinching ? .orange : .green)
            }

            if let observation = hand.observationIndex {
                InfoRow("From Vision observation", "\(observation)")
            }
            if let distance = hand.matchDistance {
                InfoRow("Match distance / radius", "\(Format.n(distance)) / \(Format.n(settings.matchRadius))",
                        color: distance > settings.matchRadius * 0.8 ? .orange : .primary)
            }

            if let raw = hand.rawLocation {
                InfoRow("Raw palm", Format.point(raw))
            }
            InfoRow("Smoothed cursor", Format.point(hand.smoothed))
            if let raw = hand.rawLocation {
                let lag = hypot(raw.x - hand.smoothed.x, raw.y - hand.smoothed.y)
                InfoRow("Smoothing lag", Format.n(lag))
            }

            InfoRow("Pinch gap", hand.pinchRatio.map { Format.n($0, 2) } ?? "–")
            PinchGauge(ratio: hand.pinchRatio, close: settings.pinchCloseRatio, open: settings.pinchOpenRatio)
            HStack {
                Text("pinch").foregroundStyle(.secondary)
                EvidenceDots(count: hand.pinchEvidence, total: settings.framesToCommit, color: .orange)
                Spacer()
                Text("apart").foregroundStyle(.secondary)
                EvidenceDots(count: hand.apartEvidence, total: settings.framesToCommit, color: .green)
            }

            if hand.status == .coasting {
                InfoRow("Missing for / grace", "\(Format.ms(hand.secondsSinceSeen)) / \(Format.ms(settings.gracePeriod))",
                        color: .orange)
                ProgressView(value: min(hand.secondsSinceSeen / max(settings.gracePeriod, 0.001), 1))
                    .tint(.orange)
            }
        }
        .padding(8)
        .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ObservationsSection: View {
    let snapshot: DebugSnapshot
    let settings: PipelineSettings

    var body: some View {
        PanelSection("Raw Vision hands (\(snapshot.observations.count))",
                     caption: "Everything Vision reported, before the body filter. Up to \(settings.handCandidateLimit) per frame.") {
            if snapshot.observations.isEmpty {
                Text("Vision found no hands").foregroundStyle(.secondary)
            }
            ForEach(snapshot.observations) { observation in
                ObservationCard(observation: observation, threshold: settings.jointConfidenceThreshold)
            }
        }
    }
}

struct ObservationCard: View {
    let observation: ObservationDebug
    let threshold: Float

    private var verdictColor: Color {
        if observation.rejection != nil { return .red }
        return observation.filter?.isKept == true ? .green : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Observation \(observation.index)").bold()
                Spacer()
                Text(observation.filter?.isKept == true ? "KEPT" : "DROPPED").bold().foregroundStyle(verdictColor)
            }
            InfoRow("Vision confidence", Format.n(observation.confidence))
            InfoRow("Vision chirality (mirrored)", observation.chirality)
            InfoRow("Trusted joints (≥ \(Format.n(threshold)))", "\(observation.trustedJointCount) / \(observation.joints.count)",
                    color: observation.trustedJointCount < 10 ? .orange : .primary)

            if let rejection = observation.rejection {
                InfoRow("Classifier", rejection, color: .red)
            }
            if let reading = observation.reading {
                InfoRow("Palm centre", Format.point(reading.location))
                InfoRow("Wrist", Format.point(reading.wrist))
                InfoRow("Palm length", Format.n(reading.palmLength))
                InfoRow("Pinch gap (palm lengths)", reading.pinchRatio.map { Format.n($0, 2) } ?? "– (tip missing)")
            }
            if let filter = observation.filter {
                InfoRow("Body filter", filter.reason, color: filter.isKept ? .green : .red)
                if let toPlayer = filter.distanceToPlayerWrist, let reach = filter.reach {
                    InfoRow("To player wrist / reach", "\(Format.n(toPlayer)) / \(Format.n(reach))")
                }
                if let toOthers = filter.distanceToOtherPerson {
                    InfoRow("To other person's wrist", Format.n(toOthers))
                }
            }

            DisclosureGroup("All 21 joints") {
                ForEach(observation.joints, id: \.name) { joint in
                    InfoRow(joint.name, "\(Format.point(joint.location)) c=\(Format.n(joint.confidence))",
                            color: joint.isTrusted ? .primary : .red)
                }
            }
        }
        .padding(8)
        .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct BodiesSection: View {
    let snapshot: DebugSnapshot

    var body: some View {
        PanelSection("Bodies (\(snapshot.bodies.count))",
                     caption: "A hand only counts if its wrist is near the player's (nearest person's) wrist.") {
            InfoRow("Source", snapshot.bodySource.rawValue)
            ForEach(snapshot.bodies) { body in
                VStack(alignment: .leading, spacing: 3) {
                    Text(body.isPlayer ? "Body \(body.id) — PLAYER" : "Body \(body.id) — other person")
                        .bold()
                        .foregroundStyle(body.isPlayer ? .pink : .gray)
                    InfoRow("Shoulder span", Format.n(body.scale))
                    InfoRow("Wrist reach", Format.n(body.reach))
                    InfoRow("Left wrist", body.body.leftWrist.map(Format.point) ?? "not seen")
                    InfoRow("Right wrist", body.body.rightWrist.map(Format.point) ?? "not seen")
                    InfoRow("Head", body.body.head == nil ? "not seen" : "seen")
                }
                .padding(8)
                .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct EventLogSection: View {
    let events: [LoggedEvent]
    let onClear: () -> Void

    var body: some View {
        PanelSection("Event log", caption: "Newest first. Keeps running while frozen.") {
            HStack {
                Spacer()
                Button("Clear", action: onClear).buttonStyle(.bordered)
            }
            if events.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            }
            ForEach(events.prefix(60)) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Text("f\(entry.frame)").foregroundStyle(.secondary)
                    Text(entry.event.text).foregroundStyle(entry.event.isProblem ? .orange : .primary)
                }
            }
        }
    }
}

struct TuningSection: View {
    @Bindable var model: DebugModel

    var body: some View {
        PanelSection("Tuning", caption: "Starts at PlayFeat's values. Changes apply on the next frame.") {
            Picker("Mode", selection: $model.settings.mode) {
                ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            slider("Joint confidence", value: Binding(
                get: { Double(model.settings.jointConfidenceThreshold) },
                set: { model.settings.jointConfidenceThreshold = Float($0) }
            ), range: 0...1)
            slider("Cursor smoothing", value: cgFloat(\.cursorSmoothing), range: 0.05...1)
            slider("Match radius", value: cgFloat(\.matchRadius), range: 0.05...1)
            slider("Grace period (s)", value: $model.settings.gracePeriod, range: 0...1.5)
            slider("Pinch close ratio", value: cgFloat(\.pinchCloseRatio), range: 0.05...1)
            slider("Pinch open ratio", value: cgFloat(\.pinchOpenRatio), range: 0.05...1.2)
            Stepper("Frames to commit pinch: \(model.settings.framesToCommit)",
                    value: $model.settings.framesToCommit, in: 1...10)
            slider("Wrist match tolerance", value: cgFloat(\.wristMatchTolerance), range: 0.1...2)
            slider("Body grace period (s)", value: $model.settings.bodyGracePeriod, range: 0...2)
            Stepper("Body pose every \(model.settings.bodyPoseFrameInterval) frames",
                    value: $model.settings.bodyPoseFrameInterval, in: 1...10)
            Stepper("Vision hand candidates: \(model.settings.handCandidateLimit)",
                    value: $model.settings.handCandidateLimit, in: 1...6)

            Button("Reset to PlayFeat values", action: model.resetSettings)
                .buttonStyle(.bordered)
        }
    }

    private func cgFloat(_ keyPath: WritableKeyPath<PipelineSettings, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(model.settings[keyPath: keyPath]) },
            set: { model.settings[keyPath: keyPath] = CGFloat($0) }
        )
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            InfoRow(title, Format.n(value.wrappedValue, 2))
            Slider(value: value, in: range)
        }
    }
}

struct PracticeSection: View {
    let board: PracticeBoard
    let onReset: () -> Void

    var body: some View {
        PanelSection("Practice board",
                     caption: "PlayFeat's rules: grab = pinch while touching (reach = radius + \(Int(PracticeRules.grabSlack))pt), let go = open for \(Format.ms(PracticeRules.releaseDelay)), lost hand keeps its item \(Format.ms(PracticeRules.heldHandGrace)).") {
            Text(board.phase.title).bold().foregroundStyle(.yellow)
            InfoRow("Served", "\(board.servedCount)")
            InfoRow("On plate", "\(board.ingredients.filter { $0.isOnPlate }.count) / \(PracticeRules.ingredientsPerDish)")
            InfoRow("Plate held by", board.plateHeldBy.map { "#\($0)" } ?? "nobody")
            InfoRow("Plate radius / drop reach", "\(Int(board.plateRadius)) / \(Int(board.plateDropReach)) pt")
            InfoRow("Ingredient radius", "\(Int(board.ingredientRadius)) pt")

            ForEach(board.handRows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Hand #\(row.id)").bold()
                        Spacer()
                        Text(row.isFist ? "PINCH" : "open").foregroundStyle(row.isFist ? .orange : .green)
                    }
                    InfoRow("Holding", row.holding)
                    if let openFor = row.openFor {
                        InfoRow("Open for / to let go", "\(Format.ms(openFor)) / \(Format.ms(PracticeRules.releaseDelay))",
                                color: .orange)
                    }
                }
                .padding(6)
                .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("New game", action: onReset).buttonStyle(.bordered)
            }
            ForEach(Array(board.log.enumerated()), id: \.offset) { item in
                Text(item.element).font(.system(size: 11, design: .monospaced))
            }
        }
    }
}
