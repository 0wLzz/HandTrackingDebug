//
//  DebugScreen.swift
//  HandTrackingDebug
//
//  Camera + overlay on the left, every number on the right.
//

import SwiftUI

struct DebugScreen: View {
    @Bindable var model: DebugModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.black
                CameraPreview(feed: model.feed)
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { model.cameraAreaSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in model.cameraAreaSize = size }
                }
                if model.isPracticing {
                    PracticeCanvas(board: model.practice)
                }
                OverlayCanvas(snapshot: model.snapshot, settings: model.settings, options: model.overlay)
                statusBadge
                    .padding(12)
            }
            .ignoresSafeArea()

            DebugPanel(model: model)
                .frame(width: 400)
                .background(Color(white: 0.08))
        }
        .onAppear { model.start() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var statusBadge: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.cameraStatus != "Running" {
                Text(model.cameraStatus)
            }
            Text("\(Int(model.framesPerSecond)) fps")
            if model.isFrozen {
                Text("FROZEN — tap Resume").foregroundStyle(.yellow)
            }
        }
        .font(.system(size: 14, weight: .bold, design: .monospaced))
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}
