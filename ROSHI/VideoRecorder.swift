import AVFoundation
import Foundation
import CoreImage

struct RecordingMetadata: Codable {
    let resolution: Resolution
    let fps: Double
    let cameraIntrinsics: CodableMatrix3x3?
    let frames: [FrameMetadata]
}

struct Resolution: Codable {
    let width: Int
    let height: Int
}

struct FrameMetadata: Codable {
    let frameIndex: Int
    let utcTimestamp: String  // ISO 8601 format
    let timestampSeconds: Double
    let detections: [TagDetection]
}

struct TagDetection: Codable {
    let id: Int
    let center: CodablePoint
    let corners: [CodablePoint]
    let position: CodableVector3
    let rotation: CodableMatrix3x3
    let distance: Float
}

struct CodablePoint: Codable {
    let x: CGFloat
    let y: CGFloat
}

struct CodableVector3: Codable {
    let x: Float
    let y: Float
    let z: Float
}

struct CodableMatrix3x3: Codable {
    let m11: Float, m12: Float, m13: Float
    let m21: Float, m22: Float, m23: Float
    let m31: Float, m32: Float, m33: Float
}

class VideoRecorder {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var _isRecording = false
    private let recordingQueue = DispatchQueue(label: "recording.queue", attributes: .concurrent)
    private var frameIndex = 0
    private var startTime: Date?
    private var metadata: [FrameMetadata] = []
    private var lastFrameTime: CMTime = CMTime.zero
    private let targetFPS: Double = 30.0
    private let frameInterval: CMTime
    private let ciContext: CIContext
    private var recordingResolution: CGSize?
    private var recordingFPS: Double = 30.0
    private var recordingIntrinsics: CodableMatrix3x3?
    private var stopTime: Date?
    private let trimDuration: TimeInterval = 3.0 // Remove last 3 seconds
    
    init() {
        frameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }
    
    func startRecording(resolution: CGSize, fps: Double = 30.0) {
        recordingQueue.async(flags: .barrier) {
            guard !self._isRecording else { return }
            
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let videoURL = documentsPath.appendingPathComponent("recording_\(timestamp).mp4")
            let metadataURL = documentsPath.appendingPathComponent("recording_\(timestamp)_metadata.json")
            
            // Remove existing file if any
            try? FileManager.default.removeItem(at: videoURL)
            
            do {
                self.assetWriter = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
                
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(resolution.width),
                    AVVideoHeightKey: Int(resolution.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 5_000_000,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                    ]
                ]
                
                self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                self.videoInput?.expectsMediaDataInRealTime = true
                
                let sourcePixelBufferAttributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(resolution.width),
                    kCVPixelBufferHeightKey as String: Int(resolution.height)
                ]
                
                self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: self.videoInput!,
                    sourcePixelBufferAttributes: sourcePixelBufferAttributes
                )
                
                if self.assetWriter!.canAdd(self.videoInput!) {
                    self.assetWriter!.add(self.videoInput!)
                }
                
                self.assetWriter!.startWriting()
                self._isRecording = true
                self.frameIndex = 0
                self.startTime = Date()
                self.metadata = []
                self.lastFrameTime = CMTime.zero
                self.recordingResolution = resolution
                self.recordingFPS = fps
                self.recordingIntrinsics = nil // Will be set on first frame
                
                print("Recording started: \(videoURL.path)")
                print("Metadata will be saved to: \(metadataURL.path)")
                
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }
    
    func appendFrame(pixelBuffer: CVPixelBuffer, sampleBuffer: CMSampleBuffer, detections: [AprilTag3D], intrinsics: matrix_float3x3?) {
        recordingQueue.async {
            guard self._isRecording,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  let adaptor = self.adaptor,
                  writer.status == .writing else { return }
            
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            // Maintain fixed FPS by calculating frame time
            if self.lastFrameTime == CMTime.zero {
                writer.startSession(atSourceTime: presentationTime)
                self.lastFrameTime = presentationTime
            } else {
                // Calculate next frame time based on fixed FPS
                self.lastFrameTime = CMTimeAdd(self.lastFrameTime, self.frameInterval)
            }
            
            // Convert pixel buffer to BGRA format for recording using Core Image
            var bgraBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                adaptor.pixelBufferPool!,
                &bgraBuffer
            )
            
            guard status == kCVReturnSuccess, let bgra = bgraBuffer else {
                print("Failed to create pixel buffer")
                return
            }
            
            // Use Core Image to convert YUV to BGRA
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            self.ciContext.render(ciImage, to: bgra)
            
            // Append frame
            if input.isReadyForMoreMediaData {
                adaptor.append(bgra, withPresentationTime: self.lastFrameTime)
                
                // Store metadata
                let utcTime = Date()
                let timestamp = utcTime.timeIntervalSince1970
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                
                let tagDetections = detections.map { tag -> TagDetection in
                    let rotation = tag.rotation
                    return TagDetection(
                        id: tag.id,
                        center: CodablePoint(x: tag.center.x, y: tag.center.y),
                        corners: tag.corners.map { CodablePoint(x: $0.x, y: $0.y) },
                        position: CodableVector3(x: tag.position.x, y: tag.position.y, z: tag.position.z),
                        rotation: CodableMatrix3x3(
                            m11: rotation.columns.0.x, m12: rotation.columns.1.x, m13: rotation.columns.2.x,
                            m21: rotation.columns.0.y, m22: rotation.columns.1.y, m23: rotation.columns.2.y,
                            m31: rotation.columns.0.z, m32: rotation.columns.1.z, m33: rotation.columns.2.z
                        ),
                        distance: tag.distance
                    )
                }
                
                // Store intrinsics only once (on first frame)
                if self.recordingIntrinsics == nil, let intrinsics = intrinsics {
                    self.recordingIntrinsics = CodableMatrix3x3(
                        m11: intrinsics.columns.0.x, m12: intrinsics.columns.1.x, m13: intrinsics.columns.2.x,
                        m21: intrinsics.columns.0.y, m22: intrinsics.columns.1.y, m23: intrinsics.columns.2.y,
                        m31: intrinsics.columns.0.z, m32: intrinsics.columns.1.z, m33: intrinsics.columns.2.z
                    )
                }
                
                let frameMeta = FrameMetadata(
                    frameIndex: self.frameIndex,
                    utcTimestamp: isoFormatter.string(from: utcTime),
                    timestampSeconds: timestamp,
                    detections: tagDetections
                )
                
                self.metadata.append(frameMeta)
                self.frameIndex += 1
            }
        }
    }
    
    func stopRecording(completion: @escaping (URL?, URL?) -> Void) {
        recordingQueue.async(flags: .barrier) {
            guard self._isRecording else {
                completion(nil, nil)
                return
            }
            
            // Record stop time and calculate cutoff (3 seconds before stop)
            self.stopTime = Date()
            let cutoffTime = (self.stopTime?.timeIntervalSince1970 ?? 0) - self.trimDuration
            
            self._isRecording = false
            
            guard let writer = self.assetWriter,
                  let input = self.videoInput else {
                completion(nil, nil)
                return
            }
            
            input.markAsFinished()
            
            writer.finishWriting {
                let originalVideoURL = writer.outputURL
                
                // Filter metadata to remove last 3 seconds
                let filteredMetadata = self.metadata.filter { frame in
                    frame.timestampSeconds < cutoffTime
                }
                
                print("Original frames: \(self.metadata.count), After trimming last 3 seconds: \(filteredMetadata.count)")
                
                // Create temporary file for trimmed video
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let timestamp = ISO8601DateFormatter().string(from: self.startTime ?? Date())
                    .replacingOccurrences(of: ":", with: "-")
                let tempVideoURL = documentsPath.appendingPathComponent("recording_\(timestamp)_temp.mp4")
                
                // Trim video file to remove last 3 seconds
                self.trimVideo(inputURL: originalVideoURL, outputURL: tempVideoURL, trimDuration: self.trimDuration) { trimmedURL in
                    // Replace original with trimmed version
                    if let trimmedURL = trimmedURL {
                        try? FileManager.default.removeItem(at: originalVideoURL)
                        try? FileManager.default.moveItem(at: trimmedURL, to: originalVideoURL)
                    }
                    let finalVideoURL = originalVideoURL
                    
                    // Save metadata with recording info (filtered)
                    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let timestamp = ISO8601DateFormatter().string(from: self.startTime ?? Date())
                        .replacingOccurrences(of: ":", with: "-")
                    let metadataURL = documentsPath.appendingPathComponent("recording_\(timestamp)_metadata.json")
                    
                    do {
                        let resolution = Resolution(
                            width: Int(self.recordingResolution?.width ?? 0),
                            height: Int(self.recordingResolution?.height ?? 0)
                        )
                        
                        let recordingMetadata = RecordingMetadata(
                            resolution: resolution,
                            fps: self.recordingFPS,
                            cameraIntrinsics: self.recordingIntrinsics,
                            frames: filteredMetadata
                        )
                        
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let jsonData = try encoder.encode(recordingMetadata)
                        try jsonData.write(to: metadataURL)
                        print("Metadata saved to: \(metadataURL.path)")
                    } catch {
                        print("Failed to save metadata: \(error)")
                    }
                    
                    DispatchQueue.main.async {
                        completion(finalVideoURL, metadataURL)
                    }
                }
            }
        }
    }
    
    private func trimVideo(inputURL: URL, outputURL: URL, trimDuration: TimeInterval, completion: @escaping (URL?) -> Void) {
        let asset = AVAsset(url: inputURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            print("Failed to create export session")
            completion(nil)
            return
        }
        
        // Calculate new duration (original - trim duration)
        let duration = asset.duration.seconds
        let newDuration = max(0, duration - trimDuration)
        
        if newDuration <= 0 {
            print("Video too short to trim")
            completion(nil)
            return
        }
        
        let startTime = CMTime.zero
        let endTime = CMTime(seconds: newDuration, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = timeRange
        
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                print("Video trimmed successfully")
                completion(outputURL)
            case .failed, .cancelled:
                print("Video trim failed: \(exportSession.error?.localizedDescription ?? "unknown error")")
                completion(nil)
            default:
                completion(nil)
            }
        }
    }
    
    var recording: Bool {
        return recordingQueue.sync { _isRecording }
    }
}
