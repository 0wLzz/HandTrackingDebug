//
//  OverlayCanvas.swift
//  HandTrackingDebug
//
//  Draws every piece of data that decides where a hand is and what state it's
//  in, on top of the camera, using the same `CameraViewMapping` as the game.
//
//  Legend
//  - Small dots: Vision's 21 joints per hand. Cyan = trusted (confidence at or
//    above the threshold), red ring = ignored (below the threshold).
//  - Yellow ring: this frame's raw palm centre (what the classifier measured).
//  - Big circle: the smoothed cursor the game uses. Green = open, orange =
//    pinching, grey = coasting (not seen this frame), cyan = new this frame.
//  - Yellow line raw → cursor: how far smoothing is holding the cursor back.
//  - Dashed ellipse: match radius — a reading inside it continues this hand.
//  - Thumb–index line: the pinch gap, labelled with its ratio.
//  - Magenta: the player's body; grey: other people. Rings on the player's
//    wrists: how far a hand's wrist may be and still count as theirs.
//  - Red ✕: a raw hand that was rejected, with the reason.
//

import SwiftUI

struct OverlayCanvas: View {
    let snapshot: DebugSnapshot?
    let settings: PipelineSettings
    let options: OverlayOptions

    var body: some View {
        Canvas { context, size in
            guard let snapshot else { return }
            let mapping = CameraViewMapping(bufferSize: snapshot.bufferSize, gravity: .resizeAspectFill)
            let canvas = OverlayDrawing(mapping: mapping, size: size, settings: settings, options: options)

            if options.showBodies {
                for body in snapshot.bodies { canvas.drawBody(body, in: &context) }
            }
            for observation in snapshot.observations {
                canvas.drawObservation(observation, in: &context)
            }
            for hand in snapshot.tracked {
                canvas.drawTrackedHand(hand, in: &context)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The drawing helpers, sharing one mapping and size.
private struct OverlayDrawing {
    let mapping: CameraViewMapping
    let size: CGSize
    let settings: PipelineSettings
    let options: OverlayOptions

    func screen(_ normalized: CGPoint) -> CGPoint {
        mapping.viewPoint(normalized, in: size)
    }

    /// A circle of `radius` in Vision's normalized space, drawn as the
    /// ellipse it becomes on screen (x and y scale differently).
    func ellipse(around normalized: CGPoint, radius: CGFloat) -> Path {
        let centre = screen(normalized)
        let edgeX = screen(CGPoint(x: normalized.x + radius, y: normalized.y))
        let edgeY = screen(CGPoint(x: normalized.x, y: normalized.y + radius))
        let rx = abs(edgeX.x - centre.x)
        let ry = abs(edgeY.y - centre.y)
        return Path(ellipseIn: CGRect(x: centre.x - rx, y: centre.y - ry, width: rx * 2, height: ry * 2))
    }

    func dot(at point: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    func label(_ text: String, at point: CGPoint, color: Color, in context: inout GraphicsContext) {
        guard options.showLabels else { return }
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        )
        let textSize = resolved.measure(in: CGSize(width: 400, height: 200))
        let box = CGRect(
            x: point.x - textSize.width / 2 - 4,
            y: point.y - textSize.height - 6,
            width: textSize.width + 8,
            height: textSize.height + 4
        )
        context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.black.opacity(0.7)))
        context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    // MARK: - Bodies

    func drawBody(_ body: BodyDebug, in context: inout GraphicsContext) {
        let color: Color = body.isPlayer ? .pink : .gray
        let width: CGFloat = body.isPlayer ? 4 : 2
        for chain in body.body.chains where chain.count > 1 {
            var path = Path()
            path.move(to: screen(chain[0]))
            for point in chain.dropFirst() { path.addLine(to: screen(point)) }
            context.stroke(path, with: .color(color), lineWidth: width)
        }
        if let head = body.body.head {
            context.fill(dot(at: screen(head), radius: 6), with: .color(color))
        }
        let wrists: [(String, CGPoint?)] = [("L", body.body.leftWrist), ("R", body.body.rightWrist)]
        for (side, wrist) in wrists {
            guard let wrist else { continue }
            context.fill(dot(at: screen(wrist), radius: 7), with: .color(color))
            if body.isPlayer {
                context.stroke(
                    ellipse(around: wrist, radius: body.reach),
                    with: .color(.pink.opacity(0.6)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                )
            }
            label("body \(side) wrist", at: screen(wrist), color: color, in: &context)
        }
        let shoulderMid = CGPoint(
            x: (body.body.leftShoulder.x + body.body.rightShoulder.x) / 2,
            y: (body.body.leftShoulder.y + body.body.rightShoulder.y) / 2
        )
        label(
            body.isPlayer ? "PLAYER span \(Format.n(body.scale))" : "other person span \(Format.n(body.scale))",
            at: screen(shoulderMid), color: color, in: &context
        )
    }

    // MARK: - Raw Vision hands

    func drawObservation(_ observation: ObservationDebug, in context: inout GraphicsContext) {
        if options.showRawJoints {
            drawSkeleton(of: observation, in: &context)
        }
        if options.showPinchGap {
            drawPinchGap(of: observation, in: &context)
        }

        if let reading = observation.reading {
            let palm = screen(reading.location)
            context.stroke(dot(at: palm, radius: 6), with: .color(.yellow), lineWidth: 2)
        }

        let isRejected = observation.rejection != nil || observation.filter?.isKept == false
        guard isRejected else { return }
        let anchor = observation.joint("wrist")?.location ?? observation.joints.first?.location
        guard let anchor else { return }
        let point = screen(anchor)
        context.stroke(line(CGPoint(x: point.x - 10, y: point.y - 10), CGPoint(x: point.x + 10, y: point.y + 10)),
                       with: .color(.red), lineWidth: 3)
        context.stroke(line(CGPoint(x: point.x + 10, y: point.y - 10), CGPoint(x: point.x - 10, y: point.y + 10)),
                       with: .color(.red), lineWidth: 3)
        let reason = observation.rejection ?? observation.filter?.reason ?? ""
        label("obs \(observation.index) ✕ \(reason)", at: CGPoint(x: point.x, y: point.y + 40), color: .red, in: &context)
    }

    private func drawSkeleton(of observation: ObservationDebug, in context: inout GraphicsContext) {
        for chain in FrameProcessor.fingerChains {
            let joints = chain.compactMap { observation.joint($0) }
            for (a, b) in zip(joints, joints.dropFirst()) {
                let trusted = a.isTrusted && b.isTrusted
                guard trusted || options.showLowConfidenceJoints else { continue }
                context.stroke(
                    line(screen(a.location), screen(b.location)),
                    with: .color(trusted ? .white.opacity(0.7) : .red.opacity(0.4)),
                    lineWidth: trusted ? 2 : 1
                )
            }
        }
        for joint in observation.joints {
            let point = screen(joint.location)
            if joint.isTrusted {
                context.fill(dot(at: point, radius: 4), with: .color(.cyan))
            } else if options.showLowConfidenceJoints {
                context.stroke(dot(at: point, radius: 4), with: .color(.red), lineWidth: 1.5)
            }
        }
    }

    private func drawPinchGap(of observation: ObservationDebug, in context: inout GraphicsContext) {
        guard let thumb = observation.joint("thumbTip"), let index = observation.joint("indexTip") else { return }
        let ratio = observation.reading?.pinchRatio
        let color: Color
        if let ratio, ratio <= settings.pinchCloseRatio {
            color = .orange
        } else if let ratio, ratio >= settings.pinchOpenRatio {
            color = .green
        } else {
            color = .gray
        }
        let a = screen(thumb.location)
        let b = screen(index.location)
        context.stroke(line(a, b), with: .color(color), lineWidth: 3)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        label(ratio.map { "gap \(Format.n($0, 2))" } ?? "gap –", at: mid, color: color, in: &context)
    }

    // MARK: - Tracked hands (what the game receives)

    func drawTrackedHand(_ hand: TrackedHandDebug, in context: inout GraphicsContext) {
        let cursor = screen(hand.smoothed)
        let color: Color
        switch hand.status {
        case .coasting: color = .gray
        case .new: color = .cyan
        case .seen: color = hand.isPinching ? .orange : .green
        }

        if options.showMatchRadius {
            context.stroke(
                ellipse(around: hand.smoothed, radius: settings.matchRadius),
                with: .color(color.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: [6, 6])
            )
        }

        if let raw = hand.rawLocation {
            context.stroke(line(screen(raw), cursor), with: .color(.yellow), lineWidth: 2)
        }

        let circle = dot(at: cursor, radius: 18)
        context.fill(circle, with: .color(color.opacity(0.35)))
        context.stroke(circle, with: .color(color), lineWidth: 3)

        var text = "#\(hand.id) \(hand.status.rawValue) \(hand.isPinching ? "PINCH" : "open")"
        if hand.status == .coasting {
            text += " \(Format.ms(hand.secondsSinceSeen))"
        }
        label(text, at: CGPoint(x: cursor.x, y: cursor.y - 20), color: color, in: &context)
    }
}
