import AVFoundation
import UIKit

protocol CameraManagerDelegate: AnyObject {
    func didOutput(sampleBuffer: CMSampleBuffer)
}

class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.queue")
    
    var isFront = true
    private var currentPosition: AVCaptureDevice.Position = .front
    
    // Settings State
    var currentResolution: AVCaptureSession.Preset = .hd1280x720
    var currentFPS: Double = 30.0
    
    // Dimensions for UI (Default 720p Portrait)
    var videoDimensions: CGSize = CGSize(width: 720, height: 1280)
    
    weak var delegate: CameraManagerDelegate?
    
    override init() {
        super.init()
    }
    
    func start() {
        checkPermissions()
    }
    
    // MARK: - Configuration API
    
    func setResolution(_ preset: AVCaptureSession.Preset) {
        // Prevent restarting if already on this resolution
        guard preset != currentResolution else { return }
        currentResolution = preset
        
        // Update dimensions
        switch preset {
        case .hd1280x720: videoDimensions = CGSize(width: 720, height: 1280)
        case .hd1920x1080: videoDimensions = CGSize(width: 1080, height: 1920)
        default: break // Should not happen given we removed 4K
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(preset) {
                self.session.sessionPreset = preset
            }
            self.session.commitConfiguration()
            
            // Important: Changing preset resets FPS, so we re-apply it immediately
            self.setFPS(self.currentFPS)
        }
    }
    
    func setFPS(_ fps: Double) {
        currentFPS = fps
        guard let input = session.inputs.first as? AVCaptureDeviceInput else { return }
        let device = input.device
        
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            print("FPS Error: \(error)")
        }
    }
    
    func setZoom(_ factor: CGFloat) {
        guard let input = session.inputs.first as? AVCaptureDeviceInput else { return }
        do {
            try input.device.lockForConfiguration()
            let maxZoom = min(input.device.activeFormat.videoMaxZoomFactor, 5.0)
            input.device.videoZoomFactor = max(1.0, min(factor, maxZoom))
            input.device.unlockForConfiguration()
        } catch { print(error) }
    }
    
    func switchCameraPos() {
        currentPosition = (currentPosition == .back) ? .front : .back
        isFront = (currentPosition == .front)
        setupCamera()
    }
    
    // MARK: - Internal Setup
    
    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.setupCamera() }
            }
        default: break
        }
    }
    
    private func setupCamera() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.currentPosition),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                self.session.commitConfiguration()
                return
            }
            
            if self.session.canAddInput(input) { self.session.addInput(input) }
            
            if self.session.outputs.isEmpty {
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            }
            
            if self.session.canSetSessionPreset(self.currentResolution) {
                self.session.sessionPreset = self.currentResolution
            }
            
            if let connection = self.output.connection(with: .video) {
                connection.videoOrientation = .portrait
                // Treat front camera like a "normal" camera (no selfie mirroring).
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                if connection.isCameraIntrinsicMatrixDeliverySupported {
                    connection.isCameraIntrinsicMatrixDeliveryEnabled = true
                }
            }
            
            self.session.commitConfiguration()
            self.setFPS(self.currentFPS)
            
            if !self.session.isRunning { self.session.startRunning() }
        }
    }
    
    func pauseSession() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func resumeSession() {
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delegate?.didOutput(sampleBuffer: sampleBuffer)
    }
}
