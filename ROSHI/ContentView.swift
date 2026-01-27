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
                    let x = (point.x * scale) - offsetX
                    let y = (point.y * scale) - offsetY
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
                        Text("ID: \(tag.id + 1)").bold().foregroundColor(.yellow)
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
                // Top Bar: Compact Controls
                HStack(spacing: 8) {
                    
                    // Button 1: Resolution
                    Button(action: {
                        if resLabel == "1080p" { resLabel = "720p" }
                        else { resLabel = "1080p" }
                        model.updateResolution(resLabel)
                    }) {
                        Text(resLabel)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 55, height: 32)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            )
                    }
                    
                    // Button 2: FPS Cycle
                    Button(action: {
                        if fpsLabel == "30 FPS" { fpsLabel = "20 FPS" }
                        else if fpsLabel == "20 FPS" { fpsLabel = "15 FPS" }
                        else if fpsLabel == "15 FPS" { fpsLabel = "10 FPS" }
                        else { fpsLabel = "30 FPS" }
                        
                        let fpsValue = Double(fpsLabel.components(separatedBy: " ")[0]) ?? 30.0
                        model.cameraManager.setFPS(fpsValue)
                    }) {
                        Text(fpsLabel.replacingOccurrences(of: " FPS", with: ""))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 32)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            )
                    }
                    
                    Spacer()
                    
                    // Receiver Status
                    Button(action: { model.showReceiverSettings = true }) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(model.isReceiverConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Image(systemName: "network")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(6)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(6)
                    }
                    
                    // Button 3: Target Cycle
                    Button(action: {
                        let current = model.requiredDetectionsPerTag
                        let next: Int
                        switch current {
                        case 100: next = 200
                        case 200: next = 300
                        case 300: next = 100
                        default: next = 200
                        }
                        model.requiredDetectionsPerTag = next
                    }) {
                        VStack(spacing: -1) {
                            Text("Target")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white.opacity(0.8))
                            Text("\(model.requiredDetectionsPerTag)")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .frame(width: 50, height: 32)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        )
                    }
                    
                    // FPS Readout
                    Text(String(format: "%.0f", model.fps))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(6)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(6)
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)

                // Tag detection tracker (starts when recording is initiated)
                TagDetectionTrackerView(
                    joints: AppModel.calibrationJoints,
                    counts: model.tagDetectionCounts,
                    targetDetections: model.requiredDetectionsPerTag,
                    showCounts: model.showTagDetectionCounts
                )
                // Slightly wider, but still within the screen bounds.
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .center)
                
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
        .alert("Low Detections Warning", isPresented: $model.shouldShowLowDetectionWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Some tags did not reach the target of \(model.requiredDetectionsPerTag) detections. The recording has been saved anyway.")
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

    struct CalibrationJoint: Identifiable {
        let id: Int        // Tag ID (also IMU ID)
        let name: String   // Full name (for A11y)
        let label: String  // Compact display text (e.g. "Shoulder")
    }
    
    // Fixed mapping: tag IDs (0..8) correspond to IMU placements / joints.
    static let calibrationJoints: [CalibrationJoint] = [
        CalibrationJoint(id: 0, name: "Pelvis", label: "Pelvis"),
        CalibrationJoint(id: 1, name: "Left Shoulder", label: "Shoulder"),
        CalibrationJoint(id: 2, name: "Right Shoulder", label: "Shoulder"),
        CalibrationJoint(id: 3, name: "Left Elbow", label: "Elbow"),
        CalibrationJoint(id: 4, name: "Right Elbow", label: "Elbow"),
        CalibrationJoint(id: 5, name: "Left Hip", label: "Hip"),
        CalibrationJoint(id: 6, name: "Right Hip", label: "Hip"),
        CalibrationJoint(id: 7, name: "Left Knee", label: "Knee"),
        CalibrationJoint(id: 8, name: "Right Knee", label: "Knee")
    ]
    
    @Published var requiredDetectionsPerTag: Int = 200
    
    @Published var detectedTags: [AprilTag3D] = []
    @Published var isFront: Bool = true
    @Published var fps: Double = 0
    @Published var isRecording: Bool = false
    @Published var transferProgress: Double = 0.0
    @Published var isTransferring: Bool = false
    @Published var isReceiverConnected: Bool = false
    @Published var showReceiverSettings: Bool = false

    // Per-tag detection counts (incremented once per frame per tag while recording)
    @Published var tagDetectionCounts: [Int: Int] = [:]
    @Published var showTagDetectionCounts: Bool = false
    @Published var shouldShowLowDetectionWarning: Bool = false
    
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

        // Prepare counters for this recording session (shows tracker immediately at 0/250)
        resetTagDetectionCounts()
        showTagDetectionCounts = false
        
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
        videoRecorder.startRecording(
            resolution: resolution,
            fps: currentFPS,
            minDetectionsPerTagForSuggestion: requiredDetectionsPerTag
        )
        DispatchQueue.main.async {
            self.isRecording = true
            self.showTagDetectionCounts = true
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
        
        var anyLowDetections = false
        // Check if any tag is below target
        let target = self.requiredDetectionsPerTag
        for joint in Self.calibrationJoints {
            let count = self.tagDetectionCounts[joint.id] ?? 0
            if count < target {
                anyLowDetections = true
                break
            }
        }
        
        videoRecorder.stopRecording { [weak self] videoURL, metadataURL in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isRecording = false
                if anyLowDetections {
                   self.shouldShowLowDetectionWarning = true
                }
                // Reset counts for next session (keep them visible until next start if desired, 
                // but user asked to reset "after recording is stopped". 
                // Usually better to keep them visible for review, but user said "reset".
                // I'll reset them here so they clear out.)
                self.resetTagDetectionCounts()
                self.showTagDetectionCounts = false
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

        // Capture recording state once (avoids blocking the main thread on recordingQueue.sync).
        let isRecordingFrame = videoRecorder.recording
        let tags = detector.detect(pixelBuffer: pixelBuffer, tagSizeMeters: tagSizeMeters, intrinsics: intrinsics)
        DispatchQueue.main.async {
            self.detectedTags = tags
            if isRecordingFrame {
                self.bumpTagDetectionCounts(with: tags)
            }
        }
        
        // Record frame if recording
        if isRecordingFrame {
            videoRecorder.appendFrame(pixelBuffer: pixelBuffer, sampleBuffer: sampleBuffer, detections: tags, intrinsics: intrinsics)
        }
    }

    private func resetTagDetectionCounts() {
        // Initialize all expected tags to 0 so the UI can show missing tags immediately.
        self.tagDetectionCounts = Dictionary(uniqueKeysWithValues: Self.calibrationJoints.map { ($0.id, 0) })
    }
    
    private func bumpTagDetectionCounts(with tags: [AprilTag3D]) {
        guard !tagDetectionCounts.isEmpty else { return }
        
        // Count at most once per frame per tag ID.
        let idsInFrame = Set(tags.map { $0.id })
        var next = tagDetectionCounts
        let target = self.requiredDetectionsPerTag
        for id in idsInFrame {
            guard let current = next[id] else { continue } // only expected tags
            guard current < target else { continue }       // saturate at target
            next[id] = min(target, current + 1)
        }
        if next != tagDetectionCounts {
            tagDetectionCounts = next
        }
    }
}

// MARK: - Tag Detection Tracker UI
struct TagDetectionTrackerView: View {
    let joints: [AppModel.CalibrationJoint]
    let counts: [Int: Int]
    let targetDetections: Int
    let showCounts: Bool
    
    var body: some View {
        // Prefer slightly wider chips (so "Shoulder" fits), but never overflow the available width.
        ViewThatFits(in: .horizontal) {
            tracker(chipWidth: 38)
            tracker(chipWidth: 36)
            tracker(chipWidth: 32)
        }
    }
    
    @ViewBuilder
    private func tracker(chipWidth: CGFloat) -> some View {
        let leftJoints = [joints[1], joints[3], joints[5], joints[7]] // LSh, LElb, LHip, LKnee
        let pelvis = joints[0]
        let rightJoints = [joints[2], joints[4], joints[6], joints[8]] // RSh, RElb, RHip, RKnee
        
        let chipSpacing: CGFloat = 1
        let groupPadding: CGFloat = 2
        let groupCorner: CGFloat = 6
        let outerSpacing: CGFloat = 6
        let outerPadding: CGFloat = 2
        
        HStack(spacing: outerSpacing) {
            // Left Group (Blue)
            HStack(spacing: chipSpacing) {
                ForEach(leftJoints) { j in
                    MiniChip(joint: j, count: counts[j.id] ?? 0, target: targetDetections, show: showCounts, width: chipWidth)
                }
            }
            .padding(groupPadding)
            .background(Color.blue.opacity(0.3))
            .cornerRadius(groupCorner)
            
            // Center (Pelvis)
            MiniChip(joint: pelvis, count: counts[pelvis.id] ?? 0, target: targetDetections, show: showCounts, width: chipWidth)
                .padding(groupPadding)
                .background(Color.white.opacity(0.2))
                .cornerRadius(groupCorner)
            
            // Right Group (Green)
            HStack(spacing: chipSpacing) {
                ForEach(rightJoints) { j in
                    MiniChip(joint: j, count: counts[j.id] ?? 0, target: targetDetections, show: showCounts, width: chipWidth)
                }
            }
            .padding(groupPadding)
            .background(Color.green.opacity(0.3))
            .cornerRadius(groupCorner)
        }
        .padding(outerPadding)
        .background(Color.black.opacity(0.5))
        .cornerRadius(10)
    }
}

private struct MiniChip: View {
    let joint: AppModel.CalibrationJoint
    let count: Int
    let target: Int
    let show: Bool
    let width: CGFloat
    
    var body: some View {
        let clamped = min(max(count, 0), target)
        let done = clamped >= target
        let progress = (show && target > 0) ? (CGFloat(clamped) / CGFloat(target)) : 0.0
        let barWidth = max(0, width - 6)
        
        VStack(spacing: 0) {
            Text(joint.label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
                .frame(height: 10)
            
            if show {
                Text("\(clamped)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(height: 10)
            } else {
                Text("#\(joint.id + 1)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(height: 10)
            }
            
            // Tiny progress bar
            ZStack(alignment: .leading) {
                Color.white.opacity(0.2)
                Color.white.opacity(0.9).frame(width: barWidth * progress)
            }
            .frame(width: barWidth, height: 2)
            .padding(.top, 2)
        }
        .frame(width: width, height: 28)
        .background((show ? (done ? Color.green : Color.red) : Color.gray).opacity(0.5))
        .cornerRadius(4)
    }
}

// MARK: - THE MISSING STRUCT!
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    private func configure(_ layer: AVCaptureVideoPreviewLayer) {
        // Treat front camera like a "normal" camera (no selfie mirroring).
        if let connection = layer.connection {
            connection.videoOrientation = .portrait
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }

    func makeUIView(context: Context) -> UIView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        configure(view.videoPreviewLayer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? PreviewView else { return }
        view.videoPreviewLayer.session = session
        configure(view.videoPreviewLayer)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Ensure mirroring settings are applied after the layer gets its connection
        // (e.g. after session reconfiguration / camera switch).
        if let connection = videoPreviewLayer.connection {
            connection.videoOrientation = .portrait
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }
}
