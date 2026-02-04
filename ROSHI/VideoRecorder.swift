import AVFoundation
import Foundation
import CoreImage

struct RecordingMetadata: Codable {
    let resolution: Resolution
    let fps: Double  // Requested FPS setting
    let actualFps: Double?  // Actual achieved FPS (frames written / duration)
    let framesWritten: Int?
    let framesDropped: Int?
    let cameraIntrinsics: CodableMatrix3x3?
    /// Suggested calibration timing derived on-device from AprilTag detections.
    /// This is useful to decide how long the calibration segment is (server-side: `--calib-duration-sec`).
    let calibrationSegment: CalibrationSegment?
    let frames: [FrameMetadata]
}

struct CalibrationSegment: Codable {
    /// Always "per_tag_min_detections". Suggested duration is only set when all tags reach the app target.
    let method: String

    /// Tag IDs that must be detected (0..8 for pelvis/shoulders/elbows/hips/knees).
    let requiredTagIds: [Int]

    /// TimestampSeconds of the first recorded frame (UTC seconds since epoch).
    let recordingStartTimestampSeconds: Double?

    /// True if we have seen all required tags at least once (possibly across multiple frames).
    let allRequiredTagsSeen: Bool
    let missingTagIds: [Int]

    /// Deprecated; always nil. Kept for JSON compatibility.
    let allRequiredTagsSeenFrameIndex: Int?
    let allRequiredTagsSeenTimestampSeconds: Double?
    let allRequiredTagsSeenElapsedSec: Double?

    /// Recommended value for server-side `--calib-duration-sec`; set only when all tags reached minDetectionsPerTag.
    let suggestedCalibDurationSec: Double?

    /// Per-tag minimum detection count (app setting, e.g. 200). Used to compute suggestedCalibDurationSec.
    let minDetectionsPerTag: Int?
    /// True if every required tag reached `minDetectionsPerTag` detections (counted once per frame).
    let allRequiredTagsHaveMinDetections: Bool?
    let allRequiredTagsHaveMinDetectionsFrameIndex: Int?
    let allRequiredTagsHaveMinDetectionsTimestampSeconds: Double?
    let allRequiredTagsHaveMinDetectionsElapsedSec: Double?

    /// First moment a single frame contains *all* required tags simultaneously.
    let allRequiredTagsPresentInFrame: Bool
    let allRequiredTagsPresentInFrameFrameIndex: Int?
    let allRequiredTagsPresentInFrameTimestampSeconds: Double?
    let allRequiredTagsPresentInFrameElapsedSec: Double?
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
    // IMPORTANT: Use serial queue to prevent race conditions with frame timing
    private let recordingQueue = DispatchQueue(label: "recording.queue")
    private var frameIndex = 0
    private var startTime: Date?
    private var metadata: [FrameMetadata] = []
    private var sessionStartTime: CMTime = CMTime.zero
    private let ciContext: CIContext
    private var recordingResolution: CGSize?
    private var recordingFPS: Double = 30.0
    private var recordingIntrinsics: CodableMatrix3x3?
    private var sessionStarted = false
    private var framesWritten = 0
    private var framesDropped = 0  // Track dropped frames for debugging

    // AprilTag coverage tracking for calibration segment marking.
    // Tag IDs used by the server calibration pipeline:
    // 0: pelvis, 1: left-shoulder, 2: right-shoulder, 3: left-elbow, 4: right-elbow,
    // 5: left-hip, 6: right-hip, 7: left-knee, 8: right-knee
    private let requiredTagIds: Set<Int> = Set([0, 1, 2, 3, 4, 5, 6, 7, 8])
    private var seenTagIds: Set<Int> = []
    private var recordingStartTimestampSeconds: Double?
    private var allRequiredTagsPresentInFrameTimestampSeconds: Double?
    private var allRequiredTagsPresentInFrameFrameIndex: Int?

    // Optional: "enough detections per tag" tracking to make suggestedCalibDurationSec robust.
    private var minDetectionsPerTagForSuggestion: Int = 0
    private var tagFrameCounts: [Int: Int] = [:]
    private var allRequiredTagsHaveMinDetectionsTimestampSeconds: Double?
    private var allRequiredTagsHaveMinDetectionsFrameIndex: Int?
    
    init() {
        ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }
    
    func startRecording(resolution: CGSize, fps: Double = 30.0, minDetectionsPerTagForSuggestion: Int = 0) {
        // Use serial queue - no barrier needed
        recordingQueue.async {
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
                self.sessionStartTime = CMTime.zero
                self.recordingResolution = resolution
                self.recordingFPS = fps
                self.recordingIntrinsics = nil // Will be set on first frame
                self.sessionStarted = false
                self.framesWritten = 0
                self.framesDropped = 0
                self.seenTagIds = []
                self.recordingStartTimestampSeconds = nil
                self.allRequiredTagsPresentInFrameTimestampSeconds = nil
                self.allRequiredTagsPresentInFrameFrameIndex = nil

                // Tag coverage thresholds for calibration recommendation.
                self.minDetectionsPerTagForSuggestion = max(0, minDetectionsPerTagForSuggestion)
                self.tagFrameCounts = Dictionary(uniqueKeysWithValues: self.requiredTagIds.map { ($0, 0) })
                self.allRequiredTagsHaveMinDetectionsTimestampSeconds = nil
                self.allRequiredTagsHaveMinDetectionsFrameIndex = nil
                
                print("Recording started: \(videoURL.path)")
                print("Metadata will be saved to: \(metadataURL.path)")
                
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }
    
    func appendFrame(pixelBuffer: CVPixelBuffer, sampleBuffer: CMSampleBuffer, detections: [AprilTag3D], intrinsics: matrix_float3x3?) {
        // IMPORTANT: Capture ALL timing-sensitive data SYNCHRONOUSLY before async dispatch
        // CMSampleBuffer is recycled after this callback returns!
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Capture UTC timestamp NOW (when camera delivers frame), not later when async runs
        let captureTime = Date()
        let captureTimestamp = captureTime.timeIntervalSince1970
        
        // Pre-format the ISO timestamp synchronously
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let captureTimeISO = isoFormatter.string(from: captureTime)
        
        // Create CIImage synchronously to capture the pixel data
        // CIImage holds a reference to the pixel buffer data
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Pre-convert detections to codable format synchronously
        // This ensures the tag data matches the exact frame being processed
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
        
        // Pre-convert intrinsics if available
        let codableIntrinsics: CodableMatrix3x3? = intrinsics.map { intr in
            CodableMatrix3x3(
                m11: intr.columns.0.x, m12: intr.columns.1.x, m13: intr.columns.2.x,
                m21: intr.columns.0.y, m22: intr.columns.1.y, m23: intr.columns.2.y,
                m31: intr.columns.0.z, m32: intr.columns.1.z, m33: intr.columns.2.z
            )
        }
        
        recordingQueue.async {
            guard self._isRecording,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  let adaptor = self.adaptor,
                  writer.status == .writing else { return }
            
            // Check if pixel buffer pool is available
            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                print("⚠️ FRAME DROPPED: Pixel buffer pool not ready yet")
                self.framesDropped += 1
                return
            }
            
            // Start session on first frame
            if !self.sessionStarted {
                writer.startSession(atSourceTime: presentationTime)
                self.sessionStartTime = presentationTime
                self.sessionStarted = true
                print("Recording session started at time: \(presentationTime.seconds)")
            }
            
            // Convert pixel buffer to BGRA format for recording using Core Image
            var bgraBuffer: CVPixelBuffer?
            let createStatus = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pixelBufferPool,
                &bgraBuffer
            )
            
            guard createStatus == kCVReturnSuccess, let bgra = bgraBuffer else {
                print("⚠️ FRAME DROPPED: Failed to create pixel buffer, status: \(createStatus)")
                self.framesDropped += 1
                return
            }
            
            // Render the captured CIImage to the BGRA buffer
            self.ciContext.render(ciImage, to: bgra)
            
            // Append frame - check if input is ready
            guard input.isReadyForMoreMediaData else {
                print("⚠️ FRAME DROPPED: Encoder backpressure (input not ready), frame would be \(self.frameIndex)")
                self.framesDropped += 1
                return
            }
            
            let appendSuccess = adaptor.append(bgra, withPresentationTime: presentationTime)
            if !appendSuccess {
                print("⚠️ FRAME DROPPED: Append failed for frame \(self.frameIndex), writer status: \(writer.status.rawValue)")
                if let error = writer.error {
                    print("   Writer error: \(error)")
                }
                self.framesDropped += 1
                return
            }
            self.framesWritten += 1
            
            // SUCCESS: Frame was written to video, now save matching metadata
            // All data below was captured SYNCHRONOUSLY when camera delivered the frame,
            // ensuring perfect alignment between video frame and metadata.
            
            // Update calibration-segment markers based on which tags we've seen so far.
            if self.recordingStartTimestampSeconds == nil {
                self.recordingStartTimestampSeconds = captureTimestamp
            }
            let idsInFrame = Set(tagDetections.map { $0.id })
            self.seenTagIds.formUnion(idsInFrame)

            // Maintain per-tag counts (at most once per frame) for a stronger suggestion signal.
            if self.minDetectionsPerTagForSuggestion > 0 {
                for id in idsInFrame {
                    if self.requiredTagIds.contains(id) {
                        self.tagFrameCounts[id, default: 0] += 1
                    }
                }
                if self.allRequiredTagsHaveMinDetectionsTimestampSeconds == nil {
                    let ok = self.requiredTagIds.allSatisfy { (self.tagFrameCounts[$0] ?? 0) >= self.minDetectionsPerTagForSuggestion }
                    if ok {
                        self.allRequiredTagsHaveMinDetectionsTimestampSeconds = captureTimestamp
                        self.allRequiredTagsHaveMinDetectionsFrameIndex = self.frameIndex
                    }
                }
            }

            if self.allRequiredTagsPresentInFrameTimestampSeconds == nil && idsInFrame.isSuperset(of: self.requiredTagIds) {
                self.allRequiredTagsPresentInFrameTimestampSeconds = captureTimestamp
                self.allRequiredTagsPresentInFrameFrameIndex = self.frameIndex
            }
            
            // Store intrinsics only once (on first frame)
            if self.recordingIntrinsics == nil, let intr = codableIntrinsics {
                self.recordingIntrinsics = intr
            }
            
            let frameMeta = FrameMetadata(
                frameIndex: self.frameIndex,
                utcTimestamp: captureTimeISO,
                timestampSeconds: captureTimestamp,
                detections: tagDetections
            )
            
            self.metadata.append(frameMeta)
            self.frameIndex += 1
        }
    }
    
    func stopRecording(completion: @escaping (URL?, URL?) -> Void) {
        // Use serial queue - no barrier needed
        recordingQueue.async {
            guard self._isRecording else {
                DispatchQueue.main.async {
                    completion(nil, nil)
                }
                return
            }
            
            self._isRecording = false
            
            guard let writer = self.assetWriter,
                  let input = self.videoInput else {
                DispatchQueue.main.async {
                    completion(nil, nil)
                }
                return
            }
            
            // Check if we actually wrote any frames
            let framesWrittenCount = self.framesWritten
            let framesDroppedCount = self.framesDropped
            let metadataCount = self.metadata.count
            
            print("Stopping recording:")
            print("  Frames written to video: \(framesWrittenCount)")
            print("  Frames dropped: \(framesDroppedCount)")
            print("  Metadata entries: \(metadataCount)")
            print("  Session started: \(self.sessionStarted)")
            
            // Validate alignment
            if framesWrittenCount != metadataCount {
                print("❌ ALIGNMENT ERROR: Video frames (\(framesWrittenCount)) != Metadata entries (\(metadataCount))")
                print("   This indicates a bug in the recorder - please report!")
            } else {
                print("✅ Video and metadata are aligned (\(framesWrittenCount) frames)")
            }
            
            if framesDroppedCount > 0 {
                let totalAttempted = framesWrittenCount + framesDroppedCount
                let dropRate = Double(framesDroppedCount) / Double(totalAttempted) * 100.0
                print("⚠️ Drop rate: \(String(format: "%.1f", dropRate))% (\(framesDroppedCount)/\(totalAttempted))")
                if dropRate > 10 {
                    print("   High drop rate may indicate CPU/encoder overload. Try lower resolution or FPS.")
                }
            }
            
            // Need at least some frames for a valid video
            if framesWrittenCount == 0 || !self.sessionStarted {
                print("⚠️ No frames were written! Cancelling writer instead of finishing.")
                writer.cancelWriting()
                // Clean up the empty file
                try? FileManager.default.removeItem(at: writer.outputURL)
                DispatchQueue.main.async {
                    completion(nil, nil)
                }
                return
            }
            
            // If very few frames, wait a moment for encoder to catch up
            if framesWrittenCount < 10 {
                print("⚠️ Very short recording (\(framesWrittenCount) frames), encoder may fail")
            }
            
            input.markAsFinished()
            
            writer.finishWriting {
                // Check writer status after finishing
                if writer.status == .failed {
                    print("❌ Writer failed: \(writer.error?.localizedDescription ?? "unknown error")")
                    DispatchQueue.main.async {
                        completion(nil, nil)
                    }
                    return
                }
                
                let videoURL = writer.outputURL
                
                // Verify the file was actually written
                if let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
                   let fileSize = attrs[.size] as? UInt64 {
                    print("Video file size: \(fileSize) bytes, frames written: \(framesWrittenCount)")
                    if fileSize == 0 {
                        print("⚠️ Video file is 0 bytes!")
                    }
                }
                
                // Save metadata with recording info
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let timestamp = ISO8601DateFormatter().string(from: self.startTime ?? Date())
                    .replacingOccurrences(of: ":", with: "-")
                let metadataURL = documentsPath.appendingPathComponent("recording_\(timestamp)_metadata.json")
                
                do {
                    let resolution = Resolution(
                        width: Int(self.recordingResolution?.width ?? 0),
                        height: Int(self.recordingResolution?.height ?? 0)
                    )

                    let required = Array(self.requiredTagIds).sorted()
                    let missing = Array(self.requiredTagIds.subtracting(self.seenTagIds)).sorted()
                    let startTs = self.recordingStartTimestampSeconds
                    let presentTs = self.allRequiredTagsPresentInFrameTimestampSeconds
                    let presentElapsed = (startTs != nil && presentTs != nil) ? (presentTs! - startTs!) : nil

                    let minDetections = self.minDetectionsPerTagForSuggestion > 0 ? self.minDetectionsPerTagForSuggestion : nil
                    let minDetTs = self.allRequiredTagsHaveMinDetectionsTimestampSeconds
                    let minDetElapsed = (startTs != nil && minDetTs != nil) ? (minDetTs! - startTs!) : nil
                    let hasMinDet = minDetTs != nil
                    let suggested = hasMinDet ? minDetElapsed : nil

                    let calibSegment = CalibrationSegment(
                        method: "per_tag_min_detections",
                        requiredTagIds: required,
                        recordingStartTimestampSeconds: startTs,
                        allRequiredTagsSeen: missing.isEmpty,
                        missingTagIds: missing,
                        allRequiredTagsSeenFrameIndex: nil,
                        allRequiredTagsSeenTimestampSeconds: nil,
                        allRequiredTagsSeenElapsedSec: nil,
                        suggestedCalibDurationSec: suggested,
                        minDetectionsPerTag: minDetections,
                        allRequiredTagsHaveMinDetections: hasMinDet,
                        allRequiredTagsHaveMinDetectionsFrameIndex: self.allRequiredTagsHaveMinDetectionsFrameIndex,
                        allRequiredTagsHaveMinDetectionsTimestampSeconds: minDetTs,
                        allRequiredTagsHaveMinDetectionsElapsedSec: minDetElapsed,
                        allRequiredTagsPresentInFrame: presentTs != nil,
                        allRequiredTagsPresentInFrameFrameIndex: self.allRequiredTagsPresentInFrameFrameIndex,
                        allRequiredTagsPresentInFrameTimestampSeconds: presentTs,
                        allRequiredTagsPresentInFrameElapsedSec: presentElapsed
                    )
                    
                    // Calculate actual achieved FPS from timestamps
                    var actualFps: Double? = nil
                    if self.metadata.count >= 2 {
                        let firstTs = self.metadata.first!.timestampSeconds
                        let lastTs = self.metadata.last!.timestampSeconds
                        let duration = lastTs - firstTs
                        if duration > 0 {
                            actualFps = Double(self.metadata.count - 1) / duration
                        }
                    }
                    
                    let recordingMetadata = RecordingMetadata(
                        resolution: resolution,
                        fps: self.recordingFPS,
                        actualFps: actualFps,
                        framesWritten: framesWrittenCount,
                        framesDropped: framesDroppedCount,
                        cameraIntrinsics: self.recordingIntrinsics,
                        calibrationSegment: calibSegment,
                        frames: self.metadata
                    )
                    
                    // Log actual vs requested FPS
                    if let actual = actualFps {
                        let fpsRatio = actual / self.recordingFPS * 100.0
                        print("Actual FPS: \(String(format: "%.1f", actual)) (\(String(format: "%.0f", fpsRatio))% of requested \(self.recordingFPS))")
                    }
                    
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let jsonData = try encoder.encode(recordingMetadata)
                    try jsonData.write(to: metadataURL)
                    print("Metadata saved to: \(metadataURL.path)")
                } catch {
                    print("Failed to save metadata: \(error)")
                }
                
                DispatchQueue.main.async {
                    completion(videoURL, metadataURL)
                }
            }
        }
    }
    
    var recording: Bool {
        return recordingQueue.sync { _isRecording }
    }
}
