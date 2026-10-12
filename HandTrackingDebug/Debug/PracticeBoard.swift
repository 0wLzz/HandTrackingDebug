//
//  PracticeBoard.swift
//  HandTrackingDebug
//
//  A stripped-down copy of PlayFeat's cooking board — no art, just shapes —
//  so the grab → drop on plate → carry to the tray gestures can be practised
//  and inspected.
//
//  The rules and numbers are PlayFeat's, from GameScene + Input.swift +
//  Serving.swift (see `PracticeRules`). It reads the same `HandData` the game
//  receives, so if a gesture works here it works there.
//
//  Coordinates are SwiftUI view space (origin top-left), unlike the game's
//  SpriteKit scene (origin bottom-left); positions are flipped to match.
//

import CoreGraphics
import Foundation

/// PlayFeat's GameScene values. Keep in sync with the game.
enum PracticeRules {
    /// Extra reach around a target that still counts as touching it.
    static let grabSlack: CGFloat = 30
    /// How long a hand must stay open before it lets go.
    static let releaseDelay: TimeInterval = 0.18
    /// How long a hand that's carrying something survives being lost.
    static let heldHandGrace: TimeInterval = 0.35
    /// Fraction of the gap to the hand a carried object closes per 60Hz frame.
    static let dragSmoothing: CGFloat = 0.5
    /// The plate shrinks to this while being carried to the tray.
    static let carriedPlateScale: CGFloat = 0.62
    /// Tray height ÷ width, from Tray.png.
    static let trayAspect: CGFloat = 1211.0 / 1586.0
    /// Ingredients on the plate before the dish is "complete".
    static let ingredientsPerDish = 3
    /// How long "Served!" shows before the next dish.
    static let servedPause: TimeInterval = 1.2

    /// GameScene.easing: turns the per-60Hz-frame fraction into one for a
    /// frame that lasted `delta` (frames arrive at camera rate here).
    static func easing(base: CGFloat, delta: TimeInterval) -> CGFloat {
        guard base > 0 else { return 0 }
        guard base < 1 else { return 1 }
        guard delta > 0 else { return base }
        let elapsed = min(delta, 0.1)
        return CGFloat(1 - pow(1 - Double(base), elapsed * 60))
    }
}

struct PracticeIngredient: Identifiable {
    let id: Int
    let name: String
    var position: CGPoint
    var heldBy: Int?
    var isOnPlate = false
    /// Where it sits on the plate, relative to the plate's centre.
    var plateOffset: CGPoint = .zero
}

enum PracticeSide: String {
    case left = "LEFT"
    case right = "RIGHT"
}

enum PracticePhase: Equatable {
    /// Carry ingredients onto the plate.
    case cooking
    /// Dish complete — carry the plate to the tray on this side.
    case serving(PracticeSide)
    /// Just served; the next dish starts shortly.
    case served(at: TimeInterval)

    var title: String {
        switch self {
        case .cooking: "Cooking — put \(PracticeRules.ingredientsPerDish) ingredients on the plate"
        case .serving(let side): "Serving — carry the plate to the \(side.rawValue) tray"
        case .served: "Served!"
        }
    }
}

/// One hand as the board sees it this frame — for the panel.
struct PracticeHandRow: Identifiable {
    let id: Int
    let isFist: Bool
    let holding: String
    /// How long the hand has been open while holding something (counts up to
    /// `releaseDelay`, then it lets go).
    let openFor: TimeInterval?
}

@Observable
final class PracticeBoard {
    private(set) var size: CGSize = .zero
    private(set) var ingredients: [PracticeIngredient] = []
    private(set) var platePosition: CGPoint = .zero
    private(set) var plateHeldBy: Int?
    private(set) var phase: PracticePhase = .cooking
    private(set) var servedCount = 0
    private(set) var log: [String] = []
    private(set) var handRows: [PracticeHandRow] = []

    /// Per-hand memory, like GameScene's `trackers`.
    private struct HandState {
        var wasFist = false
        var heldIngredient: Int?
        var openSince: TimeInterval?
        var lastSeen: TimeInterval = 0
    }

    @ObservationIgnored private var hands: [Int: HandState] = [:]
    @ObservationIgnored private var plateOpenSince: TimeInterval?
    @ObservationIgnored private var lastUpdate: TimeInterval?

    static let ingredientNames = ["Tomato", "Lettuce", "Cheese", "Chicken"]

    // MARK: - Geometry (GameScene's formulas, design scale 1)

    var shortEdge: CGFloat { min(size.width, size.height) }
    var plateRadius: CGFloat { min(max(shortEdge * 0.17, 70), 150) }
    var ingredientRadius: CGFloat { min(max(shortEdge * 0.17, 68), 100) }
    /// The game's `plateHome` is 18% up from the bottom.
    var plateHome: CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.82) }
    /// An ingredient lands on the plate once its centre is this close.
    var plateDropReach: CGFloat { plateRadius + ingredientRadius * 0.5 }
    var currentPlateRadius: CGFloat {
        plateHeldBy == nil ? plateRadius : plateRadius * PracticeRules.carriedPlateScale
    }
    var traySize: CGSize {
        let width = plateRadius * 1.9
        return CGSize(width: width, height: width * PracticeRules.trayAspect)
    }
    var trayCentre: CGPoint? {
        guard case .serving(let side) = phase else { return nil }
        let x = side == .left ? traySize.width / 2 : size.width - traySize.width / 2
        return CGPoint(x: x, y: size.height / 2)
    }

    func position(of ingredient: PracticeIngredient) -> CGPoint {
        guard ingredient.isOnPlate else { return ingredient.position }
        let scale = currentPlateRadius / plateRadius
        return CGPoint(x: platePosition.x + ingredient.plateOffset.x * scale,
                       y: platePosition.y + ingredient.plateOffset.y * scale)
    }

    // MARK: - Lifecycle

    func reset() {
        servedCount = 0
        log.removeAll()
        hands.removeAll()
        startDish()
    }

    private func startDish() {
        plateHeldBy = nil
        plateOpenSince = nil
        platePosition = plateHome
        for id in hands.keys {
            hands[id]?.heldIngredient = nil
            hands[id]?.openSince = nil
        }
        // A row along the top, like ingredients spawning under the HUD.
        let names = Self.ingredientNames
        ingredients = names.indices.map { index in
            PracticeIngredient(
                id: index,
                name: names[index],
                position: CGPoint(
                    x: size.width * CGFloat(index + 1) / CGFloat(names.count + 1),
                    y: ingredientRadius + 40
                )
            )
        }
        phase = .cooking
    }

    // MARK: - One frame

    /// Runs the game's hand rules on this frame's hands (what
    /// `HandPoseManager.hands` would hold), in view coordinates of `viewSize`.
    func update(hands frameHands: [HandData], mapping: CameraViewMapping, viewSize: CGSize, now: TimeInterval) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        if viewSize != size {
            size = viewSize
            startDish()
        }

        let delta = lastUpdate.map { now - $0 } ?? 0
        lastUpdate = now

        if case .served(let servedAt) = phase, now - servedAt >= PracticeRules.servedPause {
            startDish()
        }

        var rows: [PracticeHandRow] = []
        for hand in frameHands {
            let cursor = mapping.viewPoint(hand.cursorPosition, in: viewSize)
            // Every joint plus the cursor, exactly as GameScene builds `handPoints`.
            let points = hand.recognizedJoints.map { mapping.viewPoint($0, in: viewSize) } + [cursor]
            let isFist = hand.isClosedFist
            var state = hands[hand.id] ?? HandState()
            state.lastSeen = now

            switch phase {
            case .cooking:
                cook(handID: hand.id, cursor: cursor, points: points, isFist: isFist,
                     state: &state, now: now, delta: delta)
            case .serving:
                carryPlate(handID: hand.id, cursor: cursor, points: points, isFist: isFist,
                           now: now, delta: delta)
            case .served:
                break
            }

            state.wasFist = isFist
            hands[hand.id] = state
            rows.append(PracticeHandRow(
                id: hand.id,
                isFist: isFist,
                holding: holdingDescription(handID: hand.id, state: state),
                openFor: state.openSince.map { now - $0 } ?? (plateHeldBy == hand.id ? plateOpenSince.map { now - $0 } : nil)
            ))
        }

        retireVanishedHands(stillLive: Set(frameHands.map(\.id)), now: now)
        handRows = rows
    }

    // MARK: - Cooking (Input.swift, cooking branch)

    private func cook(handID: Int, cursor: CGPoint, points: [CGPoint], isFist: Bool,
                      state: inout HandState, now: TimeInterval, delta: TimeInterval) {
        // Grab: the hand *closes* while touching an ingredient.
        if isFist, !state.wasFist, state.heldIngredient == nil,
           let index = grabCandidate(touchedBy: points) {
            ingredients[index].heldBy = handID
            state.heldIngredient = ingredients[index].id
            note("Hand #\(handID) grabbed \(ingredients[index].name)")
        }

        // Carry: follows the hand whatever its pose reads this frame.
        if let heldID = state.heldIngredient, let index = ingredients.firstIndex(where: { $0.id == heldID }) {
            let target = clamped(cursor, radius: ingredientRadius)
            ingredients[index].position = eased(ingredients[index].position, toward: target, delta: delta)

            if distance(ingredients[index].position, plateHome) <= plateDropReach {
                commitToPlate(index)
                state.heldIngredient = nil
                state.openSince = nil
                return
            }
        }

        // Let go only after staying open for `releaseDelay`.
        if let heldID = state.heldIngredient, let index = ingredients.firstIndex(where: { $0.id == heldID }) {
            if !isFist {
                let openedAt = state.openSince ?? now
                state.openSince = openedAt
                if now - openedAt >= PracticeRules.releaseDelay {
                    ingredients[index].heldBy = nil
                    state.heldIngredient = nil
                    state.openSince = nil
                    note("Hand #\(handID) let go of \(ingredients[index].name) (open \(Format.ms(now - openedAt)))")
                }
            } else {
                state.openSince = nil
            }
        }
    }

    /// Nearest free ingredient any point of the hand is touching.
    private func grabCandidate(touchedBy points: [CGPoint]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in ingredients.indices where !ingredients[index].isOnPlate && ingredients[index].heldBy == nil {
            let reach = ingredientRadius + PracticeRules.grabSlack
            guard let nearest = points.map({ distance($0, ingredients[index].position) }).min(),
                  nearest <= reach else { continue }
            if best == nil || nearest < best!.distance {
                best = (index, nearest)
            }
        }
        return best?.index
    }

    private func commitToPlate(_ index: Int) {
        let onPlate = ingredients.filter(\.isOnPlate).count
        let angle = CGFloat(onPlate) * 2.1
        ingredients[index].isOnPlate = true
        ingredients[index].heldBy = nil
        ingredients[index].plateOffset = CGPoint(x: cos(angle) * plateRadius * 0.4,
                                                 y: sin(angle) * plateRadius * 0.4)
        note("\(ingredients[index].name) dropped on the plate (\(onPlate + 1)/\(PracticeRules.ingredientsPerDish))")

        if onPlate + 1 >= PracticeRules.ingredientsPerDish {
            let side: PracticeSide = Bool.random() ? .left : .right
            // Anything still in a hand goes back on the table.
            for i in ingredients.indices where ingredients[i].heldBy != nil { ingredients[i].heldBy = nil }
            for id in hands.keys {
                hands[id]?.heldIngredient = nil
                hands[id]?.openSince = nil
            }
            phase = .serving(side)
            note("Dish complete — the bell rings on the \(side.rawValue)")
        }
    }

    // MARK: - Serving (Input.swift, carryPlate)

    private func carryPlate(handID: Int, cursor: CGPoint, points: [CGPoint], isFist: Bool,
                            now: TimeInterval, delta: TimeInterval) {
        // Pick up: a closed hand anywhere on the plate takes it (no "just closed" needed).
        if isFist, plateHeldBy == nil,
           points.contains(where: { distance($0, platePosition) <= plateRadius + PracticeRules.grabSlack }) {
            plateHeldBy = handID
            plateOpenSince = nil
            note("Hand #\(handID) picked up the plate")
        }

        guard plateHeldBy == handID else { return }

        let carriedRadius = plateRadius * PracticeRules.carriedPlateScale
        platePosition = eased(platePosition, toward: clamped(cursor, radius: carriedRadius), delta: delta)

        // Reaching the tray *is* serving.
        if let tray = trayCentre, distance(platePosition, tray) <= carriedRadius + traySize.width / 2 {
            plateHeldBy = nil
            plateOpenSince = nil
            servedCount += 1
            phase = .served(at: now)
            note("SERVED by hand #\(handID) — total \(servedCount)")
            return
        }

        // Let go short of the tray and the plate goes back home.
        if !isFist {
            let openedAt = plateOpenSince ?? now
            plateOpenSince = openedAt
            if now - openedAt >= PracticeRules.releaseDelay {
                releasePlateHome()
                note("Hand #\(handID) let go of the plate short of the tray — back home")
            }
        } else {
            plateOpenSince = nil
        }
    }

    private func releasePlateHome() {
        plateHeldBy = nil
        plateOpenSince = nil
        platePosition = plateHome
    }

    // MARK: - Lost hands (Input.swift, retireVanishedHands)

    private func retireVanishedHands(stillLive: Set<Int>, now: TimeInterval) {
        for (id, state) in hands where !stillLive.contains(id) {
            let isHolding = state.heldIngredient != nil || plateHeldBy == id
            if isHolding, now - state.lastSeen <= PracticeRules.heldHandGrace { continue }

            if let heldID = state.heldIngredient, let index = ingredients.firstIndex(where: { $0.id == heldID }) {
                ingredients[index].heldBy = nil
                note("Hand #\(id) lost — dropped \(ingredients[index].name)")
            }
            if plateHeldBy == id {
                releasePlateHome()
                note("Hand #\(id) lost — plate back home")
            }
            hands[id] = nil
        }
    }

    // MARK: - Helpers

    private func holdingDescription(handID: Int, state: HandState) -> String {
        if plateHeldBy == handID { return "the plate" }
        if let heldID = state.heldIngredient, let item = ingredients.first(where: { $0.id == heldID }) {
            return item.name
        }
        return "nothing"
    }

    private func eased(_ point: CGPoint, toward target: CGPoint, delta: TimeInterval) -> CGPoint {
        let t = PracticeRules.easing(base: PracticeRules.dragSmoothing, delta: delta)
        return CGPoint(x: point.x + (target.x - point.x) * t, y: point.y + (target.y - point.y) * t)
    }

    /// Keeps a carried object of `radius` fully on screen.
    private func clamped(_ point: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(point.x, radius), max(radius, size.width - radius)),
            y: min(max(point.y, radius), max(radius, size.height - radius))
        )
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func note(_ text: String) {
        log.insert(text, at: 0)
        if log.count > 40 { log.removeLast() }
    }
}
