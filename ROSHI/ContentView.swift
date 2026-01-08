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
    @State private var resLabel: String = "1080p"
    @State private var fpsLabel: String = "30 FPS"
    
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
                    
                    // 3D Axes
                    let axisLen = Float(model.tagSizeMeters) * 0.8
                    let origin = simd_float3(0,0,0)
                    let x3 = simd_float3(axisLen,0,0)
                    let y3 = simd_float3(0,axisLen,0)
                    let z3 = simd_float3(0,0,-axisLen)
                    
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
            
            // 3. UI Layer (Buttons & Controls)
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
                    
                    // Actual FPS Readout
                    Text(String(format: "FPS: %.0f", model.fps))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(8)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                }
                .padding(.top, 50)
                .padding(.horizontal)
                
                Spacer()
                
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
                
                Button(action: { model.switchCamera() }) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.title)
                        .frame(width: 60, height: 60)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .foregroundColor(.white)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear { model.cameraManager.start() }
    }
}

// MARK: - AppModel
class AppModel: ObservableObject, CameraManagerDelegate {
    let cameraManager = CameraManager()
    let detector = AprilTagDetector()
    
    @Published var detectedTags: [AprilTag3D] = []
    @Published var isFront: Bool = false
    @Published var fps: Double = 0
    
    // Video Dimensions
    @Published var videoW: CGFloat = 1080
    @Published var videoH: CGFloat = 1920
    
    // FPS Calc
    private var frameCount = 0
    private var lastTime: TimeInterval = 0
    let tagSizeMeters = 0.05
    
    init() { cameraManager.delegate = self }
    
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
        
        var intrinsics: matrix_float3x3? = nil
        let key = "CameraIntrinsicMatrix" as CFString
        if let attachment = CMGetAttachment(sampleBuffer, key: key, attachmentModeOut: nil) {
            let data = attachment as! Data
            intrinsics = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
        }
        
        let tags = detector.detect(pixelBuffer: pixelBuffer, tagSizeMeters: tagSizeMeters, intrinsics: intrinsics)
        DispatchQueue.main.async { self.detectedTags = tags }
    }
}

// MARK: - THE MISSING STRUCT!
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.frame
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}