//
//  HandTrackingDebugApp.swift
//  HandTrackingDebug
//
//  A standalone viewer for PlayFeat's hand tracking: the camera, every joint
//  Vision reports, the body filter's verdicts, and the identity tracker's
//  state, live — plus sliders for every tuning knob.
//

import SwiftUI

@main
struct HandTrackingDebugApp: App {
    @State private var model = DebugModel()

    var body: some Scene {
        WindowGroup {
            DebugScreen(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
