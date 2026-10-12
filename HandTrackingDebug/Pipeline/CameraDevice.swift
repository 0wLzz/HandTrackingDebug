//
//  CameraDevice.swift
//  HandTrackingDebug
//
//  COPY of the static helpers in PlayFeat/Camera/CameraManager.swift
//  (PlayFeat commit bd4fa6d): Center Stage, widest camera, widest format.
//  Keep it in sync with the game. Permission handling lives in CameraFeed here.
//

import AVFoundation
import CoreGraphics

enum CameraDevice {
    /// Switches Center Stage off for this app.
    ///
    /// Center Stage is a system-wide setting the user owns — on a MacBook it lives
    /// in Control Center's video menu. Turning it off cooperatively lets the camera
    /// reach the real limits of the hardware without cropping player hands out of view.
    static func disableCenterStage() {
        if AVCaptureDevice.centerStageControlMode == .user {
            AVCaptureDevice.centerStageControlMode = .cooperative
        }
        if AVCaptureDevice.isCenterStageEnabled {
            AVCaptureDevice.isCenterStageEnabled = false
        }
    }

    /// Finds the widest-angle camera available at the specified device position.
    static func widestCamera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Selects the capture format that sees the most of the room, then zooms out within it.
    static func selectWidestFormat(
        on device: AVCaptureDevice,
        zoom: CGFloat,
        widthRange: ClosedRange<Int32>
    ) {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard widthRange.contains(dimensions.width), dimensions.height > 0 else { return false }
            return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }

        let widest = candidates.max { a, b in ranking(of: a) < ranking(of: b) }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if let widest {
                device.activeFormat = widest
                let thirty = CMTime(value: 1, timescale: 30)
                if widest.videoSupportedFrameRateRanges.contains(where: {
                    $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                }) {
                    device.activeVideoMinFrameDuration = thirty
                }
            }

            let widestZoom = device.minAvailableVideoZoomFactor
            device.videoZoomFactor = zoomFactor(
                multiple: zoom,
                widest: widestZoom,
                maximum: device.maxAvailableVideoZoomFactor
            )

            #if DEBUG
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            print("""
                [CameraManager] \(device.localizedName): \
                \(dimensions.width)×\(dimensions.height), \
                \(Int(device.activeFormat.videoFieldOfView))° h-FOV, \
                zoom \(device.videoZoomFactor) (floor \(widestZoom)), \
                Center Stage active: \(device.isCenterStageActive)
                """)
            #endif
        } catch {
            #if DEBUG
            print("[CameraManager] Couldn't configure camera format: \(error.localizedDescription)")
            #endif
        }
    }

    /// Turns a zoom multiple into a valid `videoZoomFactor` clamped to device capabilities.
    static func zoomFactor(multiple: CGFloat, widest: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(widest * max(multiple, 0.01), widest), maximum)
    }

    /// Ranks formats based on field-of-view and resolution.
    static func ranking(of format: AVCaptureDevice.Format) -> (CGFloat, CGFloat, CGFloat) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return ranking(
            horizontalFieldOfView: CGFloat(format.videoFieldOfView),
            width: dimensions.width,
            height: dimensions.height
        )
    }

    /// Ranks format specifications by (horizontal° FOV, vertical° FOV, width).
    static func ranking(
        horizontalFieldOfView horizontal: CGFloat,
        width: Int32,
        height: Int32
    ) -> (CGFloat, CGFloat, CGFloat) {
        guard width > 0, horizontal > 0 else { return (horizontal, 0, CGFloat(width)) }

        let aspect = CGFloat(height) / CGFloat(width)
        let halfHorizontal = horizontal * .pi / 360
        let vertical = 2 * atan(tan(halfHorizontal) * aspect) * 180 / .pi
        return (horizontal, vertical, CGFloat(width))
    }
}
