//
//  PracticeCanvas.swift
//  HandTrackingDebug
//
//  Draws the practice board with plain shapes. Dashed rings show the game's
//  reach for each action, so you can see *why* a grab or drop did or didn't
//  happen:
//  - around each ingredient: grab reach (radius + grab slack)
//  - around the plate while cooking: where an ingredient lands on it
//  - around the plate while serving: where a closed hand picks it up
//  - around the tray: where the carried plate counts as served
//

import SwiftUI

struct PracticeCanvas: View {
    let board: PracticeBoard

    private static let colors: [Color] = [.red, .green, .yellow, .orange]

    var body: some View {
        Canvas { context, _ in
            drawTray(in: &context)
            drawPlate(in: &context)
            for ingredient in board.ingredients {
                drawIngredient(ingredient, in: &context)
            }
            drawBanner(in: &context)
        }
        .allowsHitTesting(false)
    }

    private func circle(_ centre: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    private func text(_ string: String, size: CGFloat, color: Color = .white) -> Text {
        Text(string).font(.system(size: size, weight: .bold, design: .rounded)).foregroundStyle(color)
    }

    private var dashed: StrokeStyle { StrokeStyle(lineWidth: 1.5, dash: [6, 6]) }

    private func drawIngredient(_ ingredient: PracticeIngredient, in context: inout GraphicsContext) {
        let centre = board.position(of: ingredient)
        let color = Self.colors[ingredient.id % Self.colors.count]

        if ingredient.isOnPlate {
            let radius = board.ingredientRadius * 0.3 * (board.currentPlateRadius / board.plateRadius)
            context.fill(circle(centre, radius), with: .color(color))
            return
        }

        let radius = board.ingredientRadius
        if ingredient.heldBy == nil, board.phase == .cooking {
            context.stroke(circle(centre, radius + PracticeRules.grabSlack),
                           with: .color(color.opacity(0.6)), style: dashed)
        }
        context.fill(circle(centre, radius), with: .color(color.opacity(ingredient.heldBy == nil ? 0.55 : 0.85)))
        context.stroke(circle(centre, radius), with: .color(.white), lineWidth: ingredient.heldBy == nil ? 2 : 5)

        var label = ingredient.name
        if let hand = ingredient.heldBy { label += "\nheld by #\(hand)" }
        context.draw(text(label, size: 18), at: centre)
    }

    private func drawPlate(in context: inout GraphicsContext) {
        let centre = board.platePosition
        let radius = board.currentPlateRadius

        switch board.phase {
        case .cooking:
            context.stroke(circle(board.plateHome, board.plateDropReach),
                           with: .color(.white.opacity(0.5)), style: dashed)
        case .serving:
            if board.plateHeldBy == nil {
                context.stroke(circle(centre, board.plateRadius + PracticeRules.grabSlack),
                               with: .color(.yellow.opacity(0.7)), style: dashed)
            }
        case .served:
            break
        }

        context.fill(circle(centre, radius), with: .color(.white.opacity(0.18)))
        context.stroke(circle(centre, radius), with: .color(.white),
                       lineWidth: board.plateHeldBy == nil ? 3 : 6)

        let count = board.ingredients.filter(\.isOnPlate).count
        var label = "Plate \(count)/\(PracticeRules.ingredientsPerDish)"
        if let hand = board.plateHeldBy { label += "\nheld by #\(hand)" }
        context.draw(text(label, size: 16), at: CGPoint(x: centre.x, y: centre.y + radius + 22))
    }

    private func drawTray(in context: inout GraphicsContext) {
        guard let centre = board.trayCentre else { return }
        let size = board.traySize
        let rect = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                          width: size.width, height: size.height)
        context.fill(Path(roundedRect: rect, cornerRadius: 16), with: .color(.blue.opacity(0.35)))
        context.stroke(Path(roundedRect: rect, cornerRadius: 16), with: .color(.blue), lineWidth: 4)

        // Served once the carried plate's centre is within this distance.
        let reach = board.plateRadius * PracticeRules.carriedPlateScale + size.width / 2
        context.stroke(circle(centre, reach), with: .color(.blue.opacity(0.7)), style: dashed)
        context.draw(text("SERVE HERE", size: 20), at: centre)
    }

    private func drawBanner(in context: inout GraphicsContext) {
        let top = CGPoint(x: board.size.width / 2, y: board.size.height * 0.5)
        switch board.phase {
        case .served:
            context.draw(text("SERVED! (\(board.servedCount))", size: 54, color: .green), at: top)
        case .serving(let side):
            context.draw(text("Carry the plate to the \(side.rawValue)", size: 26, color: .yellow),
                         at: CGPoint(x: top.x, y: board.plateHome.y - board.plateRadius - 60))
        case .cooking:
            break
        }
    }
}
