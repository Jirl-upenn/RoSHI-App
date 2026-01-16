import AVFoundation
import Foundation
import CoreImage

struct RecordingMetadata: Codable {
    let resolution: Resolution
    let fps: Double
    let cameraIntrinsics: CodableMatrix3x3?
    /// Suggested calibration timing derived on-device from AprilTag detections.
    /// This is useful to decide how long the calibration segment is (server-side: `--calib-duration-sec`).
    let calibrationSegment: CalibrationSegment?
    let frames: [FrameMetadata]
}

struct CalibrationSegment: Codable {
    /// How this segment marker was computed.
    /// - `all_required_tags_first_seen`: first time when all required tags have been observed at least once
    let method: String

    /// Tag IDs that must be detected (0..8 for pelvis/shoulders/elbows/hips/knees).
    let requiredTagIds: [Int]

    /// TimestampSeconds of the first recorded frame (UTC seconds since epoch).
    let recordingStartTimestampSeconds: Double?

    /// True if we have seen all required tags at least once (possibly across multiple frames).
    let allRequiredTagsSeen: Bool
    let missingTagIds: [Int]

    /// First moment the recording has cumulatively seen all required tags.
    let allRequiredTagsSeenFrameIndex: Int?
    let allRequiredTagsSeenTimestampSeconds: Double?
    let allRequiredTagsSeenElapsedSec: Double?

    /// Convenience: recommended value to use for server-side `--calib-duration-sec`.
    let suggestedCalibDurationSec: Double?

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

    // AprilTag coverage tracking for calibration segment marking.
    // Tag IDs used by the server calibration pipeline:
    // 0: pelvis, 1: left-shoulder, 2: right-shoulder, 3: left-elbow, 4: right-elbow,
    // 5: left-hip, 6: right-hip, 7: left-knee, 8: right-knee
    private let requiredTagIds: Set<Int> = Set([0, 1, 2, 3, 4, 5, 6, 7, 8])
    private var seenTagIds: Set<Int> = []
    private var recordingStartTimestampSeconds: Double?
    private var allRequiredTagsSeenTimestampSeconds: Double?
    private var allRequiredTagsSeenFrameIndex: Int?
    private var allRequiredTagsPresentInFrameTimestampSeconds: Double?
    private var allRequiredTagsPresentInFrameFrameIndex: Int?
    
    init() {
        ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }
    
    func startRecording(resolution: CGSize, fps: Double = 30.0) {
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
                self.seenTagIds = []
                self.recordingStartTimestampSeconds = nil
                self.allRequiredTagsSeenTimestampSeconds = nil
                self.allRequiredTagsSeenFrameIndex = nil
                self.allRequiredTagsPresentInFrameTimestampSeconds = nil
                self.allRequiredTagsPresentInFrameFrameIndex = nil
                
                print("Recording started: \(videoURL.path)")
                print("Metadata will be saved to: \(metadataURL.path)")
                
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }
    
    func appendFrame(pixelBuffer: CVPixelBuffer, sampleBuffer: CMSampleBuffer, detections: [AprilTag3D], intrinsics: matrix_float3x3?) {
        // IMPORTANT: Extract presentation time SYNCHRONOUSLY before async dispatch
        // CMSampleBuffer is recycled after this callback returns!
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Create CIImage synchronously to capture the pixel data
        // CIImage holds a reference to the pixel buffer data
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        recordingQueue.async {
            guard self._isRecording,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  let adaptor = self.adaptor,
                  writer.status == .writing else { return }
            
            // Check if pixel buffer pool is available
            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                print("Pixel buffer pool not ready yet, skipping frame")
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
                print("Failed to create pixel buffer, status: \(createStatus)")
                return
            }
            
            // Render the captured CIImage to the BGRA buffer
            self.ciContext.render(ciImage, to: bgra)
            
            // Append frame - check if input is ready
            guard input.isReadyForMoreMediaData else {
                print("Input not ready for more data, skipping frame \(self.frameIndex)")
                return
            }
            
            let appendSuccess = adaptor.append(bgra, withPresentationTime: presentationTime)
            if !appendSuccess {
                print("Failed to append frame \(self.frameIndex), writer status: \(writer.status.rawValue)")
                if let error = writer.error {
                    print("Writer error: \(error)")
                }
                return
            }
            self.framesWritten += 1
            
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

            // Update calibration-segment markers based on which tags we've seen so far.
            if self.recordingStartTimestampSeconds == nil {
                self.recordingStartTimestampSeconds = timestamp
            }
            let idsInFrame = Set(tagDetections.map { $0.id })
            self.seenTagIds.formUnion(idsInFrame)

            if self.allRequiredTagsSeenTimestampSeconds == nil && self.requiredTagIds.isSubset(of: self.seenTagIds) {
                self.allRequiredTagsSeenTimestampSeconds = timestamp
                self.allRequiredTagsSeenFrameIndex = self.frameIndex
            }
            if self.allRequiredTagsPresentInFrameTimestampSeconds == nil && idsInFrame.isSuperset(of: self.requiredTagIds) {
                self.allRequiredTagsPresentInFrameTimestampSeconds = timestamp
                self.allRequiredTagsPresentInFrameFrameIndex = self.frameIndex
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
            print("Stopping recording. Frames written: \(framesWrittenCount), session started: \(self.sessionStarted)")
            
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
                    let allSeenTs = self.allRequiredTagsSeenTimestampSeconds
                    let allSeenElapsed = (startTs != nil && allSeenTs != nil) ? (allSeenTs! - startTs!) : nil
                    let presentTs = self.allRequiredTagsPresentInFrameTimestampSeconds
                    let presentElapsed = (startTs != nil && presentTs != nil) ? (presentTs! - startTs!) : nil

                    let calibSegment = CalibrationSegment(
                        method: "all_required_tags_first_seen",
                        requiredTagIds: required,
                        recordingStartTimestampSeconds: startTs,
                        allRequiredTagsSeen: missing.isEmpty,
                        missingTagIds: missing,
                        allRequiredTagsSeenFrameIndex: self.allRequiredTagsSeenFrameIndex,
                        allRequiredTagsSeenTimestampSeconds: allSeenTs,
                        allRequiredTagsSeenElapsedSec: allSeenElapsed,
                        suggestedCalibDurationSec: allSeenElapsed,
                        allRequiredTagsPresentInFrame: presentTs != nil,
                        allRequiredTagsPresentInFrameFrameIndex: self.allRequiredTagsPresentInFrameFrameIndex,
                        allRequiredTagsPresentInFrameTimestampSeconds: presentTs,
                        allRequiredTagsPresentInFrameElapsedSec: presentElapsed
                    )
                    
                    let recordingMetadata = RecordingMetadata(
                        resolution: resolution,
                        fps: self.recordingFPS,
                        cameraIntrinsics: self.recordingIntrinsics,
                        calibrationSegment: calibSegment,
                        frames: self.metadata
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
                    completion(videoURL, metadataURL)
                }
            }
        }
    }
    
    var recording: Bool {
        return recordingQueue.sync { _isRecording }
    }
}
