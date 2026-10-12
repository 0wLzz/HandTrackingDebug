//
//  CameraPreview.swift
//  HandTrackingDebug
//
//  The live camera image, set up exactly like PlayFeat's CameraPreviewView:
//  same gravity, mirrored, rotation driven by the feed.
//

import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let feed: CameraFeed

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let layer = view.previewLayer
        layer.session = feed.session
        layer.videoGravity = feed.previewGravity
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        feed.attach(previewLayer: layer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
