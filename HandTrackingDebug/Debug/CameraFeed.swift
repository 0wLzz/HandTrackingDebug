//
//  CameraFeed.swift
//  HandTrackingDebug
//
//  The camera half of PlayFeat's HandPoseManager (session setup, rotation,
//  start/stop), with the same settings: front camera, widest format, 2× zoom,
//  Center Stage off, mirrored at source, video only.
//
//  Frames arrive on `videoQueue` through `onFrame`.
//

import AVFoundation
import UIKit

final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    /// Frames are delivered here, one at a time, off the main thread.
    let videoQueue = DispatchQueue(label: "handtrackingdebug.video")

    /// Called on `videoQueue` for every frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Same values as PlayFeat's HandPoseManager.
    let previewGravity: AVLayerVideoGravity = .resizeAspectFill
    private let zoomMultiple: CGFloat = 2.0
    private let captureWidths: ClosedRange<Int32> = 640...1920

    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "handtrackingdebug.session")
    private var isConfigured = false

    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservers: [NSKeyValueObservation] = []

    // MARK: - Start / stop

    /// Asks for camera permission if needed, then starts the session.
    /// `completion` runs on the main thread with whether the camera is allowed.
    func start(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.configureIfNeeded()
                    self.sessionQueue.async {
                        if !self.session.isRunning { self.session.startRunning() }
                    }
                }
                completion(granted)
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Handed over by the preview, so rotation follows what's on screen.
    func attach(previewLayer layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device {
            startTrackingRotation(for: device)
        }
    }

    // MARK: - Session setup (same as HandPoseManager.configureSessionIfNeeded)

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        sessionQueue.async {
            CameraDevice.disableCenterStage()

            self.session.beginConfiguration()
            self.session.automaticallyConfiguresApplicationAudioSession = false
            self.session.sessionPreset = .hd1280x720

            guard
                let device = CameraDevice.widestCamera(at: .front),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                self.session.commitConfiguration()
                return
            }
            self.session.addInput(input)

            CameraDevice.selectWidestFormat(on: device, zoom: self.zoomMultiple, widthRange: self.captureWidths)

            self.output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            self.output.alwaysDiscardsLateVideoFrames = true
            self.output.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
            }

            if let connection = self.output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }

            self.session.commitConfiguration()

            DispatchQueue.main.async {
                self.startTrackingRotation(for: device)
            }
        }
    }

    // MARK: - Rotation (same as HandPoseManager)

    private func startTrackingRotation(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyRotationAngle(coordinator.videoRotationAngleForHorizonLevelPreview)

        rotationObservers = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.applyRotationAngle(angle) }
            }
        ]
    }

    /// One angle on *both* connections, so Vision's frame and the on-screen
    /// image always agree about which way is up.
    private func applyRotationAngle(_ angle: CGFloat) {
        let previewConnection = previewLayer?.connection
        let outputConnection = output.connection(with: .video)

        let acceptedEverywhere = [previewConnection, outputConnection]
            .compactMap { $0 }
            .allSatisfy { $0.isVideoRotationAngleSupported(angle) }
        guard acceptedEverywhere else { return }

        previewConnection?.videoRotationAngle = angle
        sessionQueue.async {
            self.output.connection(with: .video)?.videoRotationAngle = angle
        }
    }

    // MARK: - Frames

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
