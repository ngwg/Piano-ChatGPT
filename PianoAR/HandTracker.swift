import ARKit
import Vision
import simd

final class HandTracker: ObservableObject {
    @Published var detectedHandCount: Int = 0

    struct HandResult {
        let isLeft: Bool
        var joints:   [VNHumanHandPoseObservation.JointName: SIMD3<Float>]
        var joints2D: [VNHumanHandPoseObservation.JointName: CGPoint]
    }

    static let allJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP,  .ringPIP,  .ringDIP,  .ringTip,
        .littleMCP,.littlePIP,.littleDIP,.littleTip,
    ]

    static let boneConnections: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,4),
        (0,5),(5,6),(6,7),(7,8),
        (0,9),(9,10),(10,11),(11,12),
        (0,13),(13,14),(14,15),(15,16),
        (0,17),(17,18),(18,19),(19,20),
        (5,9),(9,13),(13,17),
    ]

    private var _hands: [HandResult] = []
    private let lock         = NSLock()
    private var isProcessing = false
    private var frameCount   = 0
    private let visionQueue  = DispatchQueue(label: "com.piano.vision", qos: .userInteractive)
    private var smoothed3D:  [String: SIMD3<Float>] = [:]
    private var smoothed2D:  [String: CGPoint]      = [:]

    weak var sceneView: ARSCNView?

    // MARK: - Public

    func maybeProcess(_ frame: ARFrame, viewportSize: CGSize) {
        frameCount += 1
        guard frameCount % 3 == 0, !isProcessing else { return }
        isProcessing = true

        let pixelBuffer      = frame.capturedImage
        let camera           = frame.camera
        // Capture display transform on the calling thread (ARKit frame data is not thread-safe).
        // This transform maps from the camera's raw landscape image normalized coords
        // (top-left origin, [0,1]×[0,1]) to portrait viewport normalized coords (top-left origin).
        let displayTransform = frame.displayTransform(for: .portrait, viewportSize: viewportSize)
        let planeY: Float    = frame.anchors
            .first { $0.name == "keyboard" || $0.name == "keyboard_calibrated" }
            .map { $0.transform.columns.3.y } ?? -0.3

        visionQueue.async { [weak self] in
            self?.run(pixelBuffer: pixelBuffer, camera: camera,
                      planeY: planeY, displayTransform: displayTransform,
                      viewportSize: viewportSize)
        }
    }

    func snapshot() -> [HandResult] {
        lock.lock(); defer { lock.unlock() }
        return _hands
    }

    // MARK: - Vision

    private func run(pixelBuffer: CVPixelBuffer, camera: ARCamera, planeY: Float,
                     displayTransform: CGAffineTransform, viewportSize: CGSize) {
        defer { isProcessing = false }

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2

        // Use .up (no orientation correction) so Vision returns coordinates in the
        // raw landscape camera image space (y-up, bottom-left origin).
        // We then map these through ARKit's displayTransform which correctly handles
        // the 90° rotation + aspect-fill crop needed to match the ARSCNView display.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty
        else { commit([], count: 0); return }

        var planeTransform = matrix_identity_float4x4
        planeTransform.columns.3 = SIMD4<Float>(0, planeY, 0, 1)

        var results: [HandResult] = []

        for obs in observations {
            let side = obs.chirality == .left ? "L" : "R"
            var joints3D: [VNHumanHandPoseObservation.JointName: SIMD3<Float>] = [:]
            var joints2D: [VNHumanHandPoseObservation.JointName: CGPoint]      = [:]

            for name in HandTracker.allJoints {
                guard let pt = try? obs.recognizedPoint(name), pt.confidence > 0.2 else { continue }

                // Vision returns (x,y) with y-up, origin bottom-left.
                // ARKit's displayTransform expects standard image coords: y-down, origin top-left.
                // So flip y before applying the transform.
                let imageNorm = CGPoint(x: CGFloat(pt.location.x),
                                        y: 1.0 - CGFloat(pt.location.y))

                // Map to viewport-normalized coords [0,1] (top-left origin, portrait).
                let vpNorm = imageNorm.applying(displayTransform)

                // Convert to screen pixels.
                let vp = CGPoint(x: vpNorm.x * viewportSize.width,
                                 y: vpNorm.y * viewportSize.height)

                // Exponential moving average for jitter reduction (2D).
                let key2 = "\(side)_2d_\(name.rawValue)"
                let s2: CGPoint
                if let prev = smoothed2D[key2] {
                    s2 = CGPoint(x: prev.x + 0.4 * (vp.x - prev.x),
                                 y: prev.y + 0.4 * (vp.y - prev.y))
                } else {
                    s2 = vp
                }
                smoothed2D[key2] = s2
                joints2D[name] = s2

                // 3D position via LiDAR-informed unproject onto keyboard plane.
                if let world = camera.unprojectPoint(
                    s2, ontoPlane: planeTransform,
                    orientation: .portrait, viewportSize: viewportSize
                ) {
                    let key3 = "\(side)_3d_\(name.rawValue)"
                    let s3: SIMD3<Float>
                    if let prev = smoothed3D[key3] {
                        s3 = prev + 0.35 * (world - prev)
                    } else {
                        s3 = world
                    }
                    smoothed3D[key3] = s3
                    joints3D[name] = s3
                }
            }

            if !joints2D.isEmpty {
                results.append(HandResult(isLeft: obs.chirality == .left,
                                          joints: joints3D, joints2D: joints2D))
            }
        }

        commit(results, count: observations.count)
    }

    private func commit(_ hands: [HandResult], count: Int) {
        lock.lock(); _hands = hands; lock.unlock()
        DispatchQueue.main.async { self.detectedHandCount = count }
    }
}
