import Foundation
import UIKit
import AVFoundation
import simd

struct AprilTag3D {
    let id: Int
    let center: CGPoint
    let corners: [CGPoint]
    // 3D Pose Data
    let position: simd_float3       // t (Translation)
    let rotation: simd_float3x3     // R (Rotation Matrix)
    let intrinsics: simd_float3x3   // K (Camera Lens Data)
    let distance: Float
}

class AprilTagDetector {
    
    private var tf: UnsafeMutablePointer<apriltag_family_t>?
    private var td: UnsafeMutablePointer<apriltag_detector_t>?
    
    init() {
        tf = tag36h11_create()
        td = apriltag_detector_create()
        if let tf = tf, let td = td {
            apriltag_detector_add_family_bits(td, tf, 2)
        }
        td?.pointee.nthreads = 2
        // Higher accuracy corner localization (at a cost of CPU).
        // If you need more FPS, try 1.5–2.0.
        td?.pointee.quad_decimate = 1.5
        td?.pointee.quad_sigma = 0.0
        td?.pointee.refine_edges = true
    }
    
    deinit {
        if let td = td { apriltag_detector_destroy(td) }
        if let tf = tf { tag36h11_destroy(tf) }
    }
    
    func detect(pixelBuffer: CVPixelBuffer, tagSizeMeters: Double, intrinsics: matrix_float3x3?) -> [AprilTag3D] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        let stride = Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        
        var image = image_u8_t(width: width, height: height, stride: stride, buf: baseAddress?.assumingMemoryBound(to: UInt8.self))
        
        guard let detections = apriltag_detector_detect(td, &image) else { return [] }
        defer { apriltag_detections_destroy(detections) }
        
        var results: [AprilTag3D] = []
        let count = zarray_size(detections)
        
        // Default calibration
        var fx = Double(width)
        var fy = Double(width)
        var cx = Double(width) / 2.0
        var cy = Double(height) / 2.0
        
        // Use real intrinsics if available
        if let k = intrinsics {
            fx = Double(k.columns.0.x)
            fy = Double(k.columns.1.y)
            cx = Double(k.columns.2.x)
            cy = Double(k.columns.2.y)
        }
        
        let validIntrinsics = intrinsics ?? matrix_float3x3(rows: [
            simd_float3(Float(fx), 0, Float(cx)),
            simd_float3(0, Float(fy), Float(cy)),
            simd_float3(0, 0, 1)
        ])
        
        for i in 0..<count {
            var detection: UnsafeMutablePointer<apriltag_detection_t>?
            zarray_get(detections, i, &detection)
            
            if let det = detection?.pointee {
                let center = CGPoint(x: det.c.0, y: det.c.1)
                let c = det.p
                let corners = [
                    CGPoint(x: c.0.0, y: c.0.1),
                    CGPoint(x: c.1.0, y: c.1.1),
                    CGPoint(x: c.2.0, y: c.2.1),
                    CGPoint(x: c.3.0, y: c.3.1)
                ]
                
                var info = apriltag_detection_info_t(det: detection, tagsize: tagSizeMeters, fx: fx, fy: fy, cx: cx, cy: cy)
                var pose = apriltag_pose_t()
                estimate_tag_pose(&info, &pose)
                
                // 1. Extract Translation (t)
                var px: Float = 0, py: Float = 0, pz: Float = 0
                if let tMat = pose.t, let data = tMat.pointee.data {
                    px = Float(data[0]); py = Float(data[1]); pz = Float(data[2])
                }
                let position = simd_float3(px, py, pz)
                
                // 2. Extract Rotation (R)
                var r1: SIMD3<Float> = .zero
                var r2: SIMD3<Float> = .zero
                var r3: SIMD3<Float> = .zero
                
                if let R = pose.R, let data = R.pointee.data {
                    // AprilTag R is Row-Major
                    r1 = SIMD3<Float>(Float(data[0]), Float(data[1]), Float(data[2]))
                    r2 = SIMD3<Float>(Float(data[3]), Float(data[4]), Float(data[5]))
                    r3 = SIMD3<Float>(Float(data[6]), Float(data[7]), Float(data[8]))
                }
                // Construct Matrix (Swift matrices are Column-Major, so we initialize carefully)
                // Actually, passing rows to the constructor works intuitively in simd
                let rotation = simd_float3x3(rows: [r1, r2, r3])
                
                let dist = sqrt(px*px + py*py + pz*pz)
                
                results.append(AprilTag3D(id: Int(det.id), center: center, corners: corners, position: position, rotation: rotation, intrinsics: validIntrinsics, distance: dist))
            }
        }
        return results
    }
}
