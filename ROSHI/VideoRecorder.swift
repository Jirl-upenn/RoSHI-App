import AVFoundation
import Foundation
import CoreImage

struct FrameMetadata: Codable {
    let frameIndex: Int
    let utcTimestamp: String  // ISO 8601 format
    let timestampSeconds: Double
    let cameraIntrinsics: CodableMatrix3x3?
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
    
    init() {
        frameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }
    
    func startRecording(resolution: CGSize) {
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
                
                // Convert intrinsics to codable format
                let codableIntrinsics: CodableMatrix3x3? = intrinsics.map { k in
                    CodableMatrix3x3(
                        m11: k.columns.0.x, m12: k.columns.1.x, m13: k.columns.2.x,
                        m21: k.columns.0.y, m22: k.columns.1.y, m23: k.columns.2.y,
                        m31: k.columns.0.z, m32: k.columns.1.z, m33: k.columns.2.z
                    )
                }
                
                let frameMeta = FrameMetadata(
                    frameIndex: self.frameIndex,
                    utcTimestamp: isoFormatter.string(from: utcTime),
                    timestampSeconds: timestamp,
                    cameraIntrinsics: codableIntrinsics,
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
            
            self._isRecording = false
            
            guard let writer = self.assetWriter,
                  let input = self.videoInput else {
                completion(nil, nil)
                return
            }
            
            input.markAsFinished()
            
            writer.finishWriting {
                let videoURL = writer.outputURL
                
                // Save metadata
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let timestamp = ISO8601DateFormatter().string(from: self.startTime ?? Date())
                    .replacingOccurrences(of: ":", with: "-")
                let metadataURL = documentsPath.appendingPathComponent("recording_\(timestamp)_metadata.json")
                
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let jsonData = try encoder.encode(self.metadata)
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
