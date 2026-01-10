import SwiftUI
import AVFoundation
import Combine
import CoreVideo
import CoreMedia
import simd

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var zoomLevel: CGFloat = 1.0
    
    // UI State for buttons
    @State private var resLabel: String = "720p"
    @State private var fpsLabel: String = "30 FPS"
    
    // Format duration as MM:SS
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var body: some View {
        ZStack {
            // 1. Camera Preview
            CameraPreview(session: model.cameraManager.session)
                .ignoresSafeArea()
                .scaleEffect(x: model.isFront ? -1 : 1, y: 1)
                .animation(.easeInOut, value: model.isFront)
            
            // 2. AR Overlay
            GeometryReader { geometry in
                let screenW = geometry.size.width
                let screenH = geometry.size.height
                
                // Read Dynamic Video Dimensions
                let videoW = model.videoW
                let videoH = model.videoH
                
                let scale = max(screenW / videoW, screenH / videoH)
                let offsetX = (videoW * scale - screenW) / 2.0
                let offsetY = (videoH * scale - screenH) / 2.0
                
                let map2D = { (point: CGPoint) -> CGPoint in
                    var x = (point.x * scale) - offsetX
                    let y = (point.y * scale) - offsetY
                    // Keep overlay aligned with the mirrored preview when using the front camera.
                    if model.isFront {
                        x = screenW - x
                    }
                    return CGPoint(x: x, y: y)
                }
                
                let project = { (point: simd_float3, tag: AprilTag3D) -> CGPoint? in
                    let p_cam = (tag.rotation * point) + tag.position
                    if p_cam.z <= 0 { return nil }
                    let p_pixel = tag.intrinsics * p_cam
                    let x = CGFloat(p_pixel.x / p_pixel.z)
                    let y = CGFloat(p_pixel.y / p_pixel.z)
                    return map2D(CGPoint(x: x, y: y))
                }
                
                ForEach(model.detectedTags, id: \.id) { tag in
                    // Green Box
                    Path { path in
                        let pts = tag.corners.map { map2D($0) }
                        path.move(to: pts[0])
                        path.addLine(to: pts[1])
                        path.addLine(to: pts[2])
                        path.addLine(to: pts[3])
                        path.closeSubpath()
                    }
                    .stroke(Color.green, lineWidth: 3)
                    
                    // 3D Axes - RAW AprilTag/Camera coordinates (matches recorded data)
                    // Camera convention: X right, Y DOWN, Z INTO scene (away from camera)
                    let axisLen = Float(model.tagSizeMeters) * 0.8
                    let origin = simd_float3(0, 0, 0)
                    let x3 = simd_float3(axisLen, 0, 0)      // X: right
                    let y3 = simd_float3(0, axisLen, 0)      // Y: down (raw)
                    let z3 = simd_float3(0, 0, axisLen)      // Z: into scene / away from camera (raw)
                    
                    if let pO = project(origin, tag),
                       let pX = project(x3, tag),
                       let pY = project(y3, tag),
                       let pZ = project(z3, tag) {
                        Path { p in p.move(to: pO); p.addLine(to: pX) }.stroke(Color.red, lineWidth: 4)
                        Path { p in p.move(to: pO); p.addLine(to: pY) }.stroke(Color.green, lineWidth: 4)
                        Path { p in p.move(to: pO); p.addLine(to: pZ) }.stroke(Color.blue, lineWidth: 4)
                    }
                    
                    // Info Panel
                    VStack(alignment: .leading) {
                        Text("ID: \(tag.id)").bold().foregroundColor(.yellow)
                        Text(String(format: "Dist: %.2fm", tag.distance)).bold().foregroundColor(.white)
                        Text(String(format: "X: %.2f", tag.position.x)).foregroundColor(.red).font(.caption)
                        Text(String(format: "Y: %.2f", tag.position.y)).foregroundColor(.green).font(.caption)
                        Text(String(format: "Z: %.2f", tag.position.z)).foregroundColor(.blue).font(.caption)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    .position(map2D(tag.center))
                    .offset(y: -80)
                }
            }
            .ignoresSafeArea()
            
            // 3. Countdown Overlay (when using front camera)
            if model.isCountdownActive {
                ZStack {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                    
                    Text("\(model.countdownValue)")
                        .font(.system(size: 120, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .scaleEffect(model.countdownScale)
                        .animation(.easeOut(duration: 0.3), value: model.countdownValue)
                }
            }
            
            // 4. UI Layer (Buttons & Controls)
            VStack {
                // Top Bar: Two Buttons + FPS Counter
                HStack(spacing: 12) {
                    
                    // Button 1: Resolution Cycle (1080p <-> 720p)
                    Button(action: {
                        if resLabel == "1080p" {
                            resLabel = "720p"
                        } else {
                            resLabel = "1080p"
                        }
                        model.updateResolution(resLabel)
                    }) {
                        Text(resLabel)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 80, height: 40)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            )
                    }
                    
                    // Button 2: FPS Cycle (30 -> 20 -> 15 -> 10)
                    Button(action: {
                        // Cycle Logic
                        if fpsLabel == "30 FPS" { fpsLabel = "20 FPS" }
                        else if fpsLabel == "20 FPS" { fpsLabel = "15 FPS" }
                        else if fpsLabel == "15 FPS" { fpsLabel = "10 FPS" }
                        else { fpsLabel = "30 FPS" }
                        
                        // Parse "30 FPS" -> 30.0
                        let fpsValue = Double(fpsLabel.components(separatedBy: " ")[0]) ?? 30.0
                        model.cameraManager.setFPS(fpsValue)
                    }) {
                        Text(fpsLabel)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 80, height: 40)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            )
                    }
                    
                    Spacer()
                    
                    // Receiver Status Indicator
                    Button(action: {
                        model.showReceiverSettings = true
                    }) {
                        HStack(spacing: 6) {
                            // Connection Status Dot
                            Circle()
                                .fill(model.isReceiverConnected ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                            
                            Image(systemName: "network")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                    }
                    
                    // Actual FPS Readout
                    Text(String(format: "FPS: %.0f", model.fps))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(8)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                }
                .padding(.top, 10)
                .padding(.horizontal)
                
                Spacer()
                
                // Recording Duration Display (above zoom so it doesn't shift layout)
                if model.isRecording {
                    Text(formatDuration(model.recordingDuration))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(8)
                        .padding(.bottom, 8)
                }
                
                // Bottom Controls (Zoom & Flip)
                HStack {
                    Image(systemName: "minus.magnifyingglass").foregroundColor(.white)
                    Slider(value: Binding(
                        get: { zoomLevel },
                        set: { val in
                            zoomLevel = val
                            model.cameraManager.setZoom(val)
                        }
                    ), in: 1.0...5.0).accentColor(.green)
                    Image(systemName: "plus.magnifyingglass").foregroundColor(.white)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 10)
                
                ZStack {
                    // Record Button (Centered)
                    Button(action: {
                        // Only allow recording if connected
                        guard model.isReceiverConnected else { return }
                        
                        if model.isRecording {
                            model.stopRecording()
                        } else {
                            model.startRecording()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(model.isRecording ? Color.red : (model.isReceiverConnected ? Color.white : Color.gray))
                                .frame(width: 70, height: 70)
                            if model.isRecording {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white)
                                    .frame(width: 24, height: 24)
                            } else {
                                Circle()
                                    .fill(model.isReceiverConnected ? Color.red : Color.gray.opacity(0.5))
                                    .frame(width: 60, height: 60)
                            }
                        }
                    }
                    .disabled(!model.isReceiverConnected && !model.isRecording)
                    .opacity(model.isReceiverConnected || model.isRecording ? 1.0 : 0.5)
                    
                    // Camera Flip Button (Right side)
                    HStack {
                        Spacer()
                        Button(action: { model.switchCamera() }) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                .font(.title)
                                .frame(width: 60, height: 60)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            model.cameraManager.start()
            // Prevent screen from locking while app is active
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            // Re-enable idle timer when view disappears
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $model.showReceiverSettings) {
            ReceiverSettingsView(model: model)
        }
    }
}

// MARK: - Receiver Settings View
struct ReceiverSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var hostText: String = ""
    @State private var portText: String = "50000"
    @State private var showDetails: Bool = false
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Circle()
                            .fill(model.isReceiverConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)
                        Text(model.isReceiverConnected ? "Connected" : "Disconnected")
                            .foregroundColor(model.isReceiverConnected ? .green : .red)
                    }
                } header: {
                    Text("Connection Status")
                }
                
                Section(header: Text("Receiver Address")) {
                    Button(action: {
                        showDetails.toggle()
                    }) {
                        HStack {
                            Text("Current Address")
                                .foregroundColor(.primary)
                            Spacer()
                            if showDetails {
                                Text(model.receiverAddress)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "eye.slash")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    if showDetails {
                        HStack {
                            Text("IP Address")
                            Spacer()
                            TextField("e.g., 10.103.76.0", text: $hostText)
                                .keyboardType(.numbersAndPunctuation)
                                .autocapitalization(.none)
                                .multilineTextAlignment(.trailing)
                        }
                        
                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("50000", text: $portText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .navigationTitle("Receiver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                if showDetails {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            saveSettings()
                        }
                    }
                }
            }
            .onAppear {
                // Load current settings
                let parts = model.receiverAddress.split(separator: ":")
                if parts.count == 2 {
                    hostText = String(parts[0])
                    portText = String(parts[1])
                }
            }
        }
    }
    
    private func saveSettings() {
        guard let port = UInt16(portText), !hostText.isEmpty else {
            return
        }
        model.updateReceiver(host: hostText, port: port)
        dismiss()
    }
}

// MARK: - AppModel
class AppModel: ObservableObject, CameraManagerDelegate, FileTransferServiceDelegate {
    let cameraManager = CameraManager()
    let detector = AprilTagDetector()
    let videoRecorder = VideoRecorder()
    let fileTransferService = FileTransferService()
    
    @Published var detectedTags: [AprilTag3D] = []
    @Published var isFront: Bool = true
    @Published var fps: Double = 0
    @Published var isRecording: Bool = false
    @Published var transferProgress: Double = 0.0
    @Published var isTransferring: Bool = false
    @Published var isReceiverConnected: Bool = false
    @Published var showReceiverSettings: Bool = false
    
    // Countdown state
    @Published var isCountdownActive: Bool = false
    @Published var countdownValue: Int = 3
    @Published var countdownScale: CGFloat = 1.0
    
    // Recording duration
    @Published var recordingDuration: TimeInterval = 0
    private var recordingStartTime: Date?
    private var recordingTimer: Timer?
    
    private var countdownTimer: Timer?
    
    var receiverAddress: String {
        return fileTransferService.receiverAddress
    }
    
    // Video Dimensions
    @Published var videoW: CGFloat = 720
    @Published var videoH: CGFloat = 1280
    
    // FPS Calc
    private var frameCount = 0
    private var lastTime: TimeInterval = 0
    // Physical tag size (black square side length) in meters.
    let tagSizeMeters = 0.042
    
    init() {
        cameraManager.delegate = self
        fileTransferService.delegate = self
        // Initialize to 720p
        cameraManager.setResolution(.hd1280x720)
        DispatchQueue.main.async {
            self.videoW = self.cameraManager.videoDimensions.width
            self.videoH = self.cameraManager.videoDimensions.height
        }
        // Set receiver IP and port (update with your receiver's IP)
        // Default port is 50000, or use --port when starting receiver.py
        fileTransferService.setReceiver(host: "10.103.76.0", port: 50000)
    }
    
    func switchCamera() {
        cameraManager.switchCameraPos()
        DispatchQueue.main.async { self.isFront = self.cameraManager.isFront }
    }
    
    func updateResolution(_ res: String) {
        var preset: AVCaptureSession.Preset = .hd1920x1080
        if res == "720p" { preset = .hd1280x720 }
        
        cameraManager.setResolution(preset)
        
        DispatchQueue.main.async {
            self.videoW = self.cameraManager.videoDimensions.width
            self.videoH = self.cameraManager.videoDimensions.height
        }
    }
    
    func startRecording() {
        // Only allow recording if receiver is connected
        guard isReceiverConnected else {
            print("Cannot start recording: receiver not connected")
            return
        }
        
        // If using front camera, show countdown first
        if isFront {
            startCountdown()
        } else {
            startRecordingImmediately()
        }
    }
    
    private func startCountdown() {
        DispatchQueue.main.async {
            self.isCountdownActive = true
            self.countdownValue = 3
            self.countdownScale = 1.0
        }
        
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            DispatchQueue.main.async {
                self.countdownValue -= 1
                self.countdownScale = 1.3
                
                // Animate scale back
                withAnimation(.easeOut(duration: 0.3)) {
                    self.countdownScale = 1.0
                }
                
                if self.countdownValue <= 0 {
                    timer.invalidate()
                    self.countdownTimer = nil
                    self.isCountdownActive = false
                    self.startRecordingImmediately()
                }
            }
        }
    }
    
    private func startRecordingImmediately() {
        // Send start recording signal to receiver immediately (for IMU data)
        fileTransferService.sendStartRecordingSignal()
        
        let resolution = CGSize(width: videoW, height: videoH)
        let currentFPS = cameraManager.currentFPS
        videoRecorder.startRecording(resolution: resolution, fps: currentFPS)
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingDuration = 0
            self.recordingStartTime = Date()
            
            // Start timer to update duration every 0.1 seconds
            self.recordingTimer?.invalidate()
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }
    
    func stopRecording() {
        // Send stop recording signal to receiver (for IMU data)
        fileTransferService.sendStopRecordingSignal()
        
        // Stop recording timer
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        // Cancel countdown if active
        countdownTimer?.invalidate()
        countdownTimer = nil
        DispatchQueue.main.async {
            self.isCountdownActive = false
        }
        
        videoRecorder.stopRecording { [weak self] videoURL, metadataURL in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isRecording = false
            }
            
            if let videoURL = videoURL, let metadataURL = metadataURL {
                print("Recording saved, starting transfer...")
                DispatchQueue.main.async {
                    self.isTransferring = true
                    self.transferProgress = 0.0
                }
                // Transfer files immediately
                self.fileTransferService.sendFiles(videoURL: videoURL, metadataURL: metadataURL)
            }
        }
    }
    
    // MARK: - FileTransferServiceDelegate
    
    func transferProgress(_ progress: Double) {
        DispatchQueue.main.async {
            self.transferProgress = progress
        }
    }
    
    func transferCompleted() {
        DispatchQueue.main.async {
            self.isTransferring = false
            self.transferProgress = 1.0
            print("Transfer completed successfully")
        }
    }
    
    func transferFailed(_ error: Error) {
        DispatchQueue.main.async {
            self.isTransferring = false
            print("Transfer failed: \(error.localizedDescription)")
        }
    }
    
    func connectionStateChanged(_ isConnected: Bool) {
        DispatchQueue.main.async {
            self.isReceiverConnected = isConnected
        }
    }
    
    func updateReceiver(host: String, port: UInt16) {
        fileTransferService.setReceiver(host: host, port: port)
    }
    
    func didOutput(sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        if lastTime == 0 { lastTime = now }
        frameCount += 1
        if now - lastTime >= 1.0 {
            let currentFps = Double(frameCount) / (now - lastTime)
            DispatchQueue.main.async { self.fps = currentFps }
            frameCount = 0
            lastTime = now
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Keep UI overlay scaling in sync with the actual CVPixelBuffer dimensions.
        // (Session presets are not guaranteed to match the delivered pixel buffer size on all devices.)
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        if w != videoW || h != videoH {
            DispatchQueue.main.async {
                self.videoW = w
                self.videoH = h
            }
        }
        
        var intrinsics: matrix_float3x3? = nil
        let key = "CameraIntrinsicMatrix" as CFString
        if let attachment = CMGetAttachment(sampleBuffer, key: key, attachmentModeOut: nil) {
            let data = attachment as! Data
            intrinsics = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
        }
        
        let tags = detector.detect(pixelBuffer: pixelBuffer, tagSizeMeters: tagSizeMeters, intrinsics: intrinsics)
        DispatchQueue.main.async { self.detectedTags = tags }
        
        // Record frame if recording
        if videoRecorder.recording {
            videoRecorder.appendFrame(pixelBuffer: pixelBuffer, sampleBuffer: sampleBuffer, detections: tags, intrinsics: intrinsics)
        }
    }
}

// MARK: - THE MISSING STRUCT!
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? PreviewView else { return }
        view.videoPreviewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}