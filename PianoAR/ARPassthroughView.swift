import SwiftUI
import ARKit
import SceneKit

// Simple transfer type: pre-projected 2D segments ready to draw.
struct HandOverlayHand {
    let isLeft: Bool
    let segments: [(CGPoint, CGPoint)]
    let isPalmSegment: [Bool]   // parallel to segments — wider stroke for palm bones
}

struct ARPassthroughView: UIViewRepresentable {
    let session:     ARSessionModel
    let placement:   PlacementManager
    let calibration: CalibrationManager
    let handTracker: HandTracker
    let onTap:       (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(placement: placement, calibration: calibration,
                    handTracker: handTracker, onTap: onTap)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session           = session.session
        view.delegate          = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously          = true
        view.preferredFramesPerSecond     = 60
        view.contentMode                  = .scaleAspectFill
        view.debugOptions                 = []

        placement.sceneView   = view
        calibration.sceneView = view

        // 2-D hand silhouette overlay sits on top of the AR scene.
        let overlay = HandOverlayView(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isOpaque                  = false
        overlay.backgroundColor           = .clear
        overlay.isUserInteractionEnabled  = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        context.coordinator.handOverlay = overlay

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        placement.sceneView   = uiView
        calibration.sceneView = uiView
        context.coordinator.onTap = onTap
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let placement:   PlacementManager
        let calibration: CalibrationManager
        let handTracker: HandTracker
        var onTap: (CGPoint) -> Void
        weak var handOverlay: HandOverlayView?

        // Indices into boneConnections that connect wrist→MCP or cross the palm knuckles.
        // These get a wider stroke for a filled-palm look.
        private static let palmBoneIndices: Set<Int> = [4, 8, 12, 16, 20, 21, 22]

        init(placement: PlacementManager, calibration: CalibrationManager,
             handTracker: HandTracker, onTap: @escaping (CGPoint) -> Void) {
            self.placement   = placement
            self.calibration = calibration
            self.handTracker = handTracker
            self.onTap       = onTap
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? ARSCNView else { return }
            onTap(g.location(in: v))
        }

        // MARK: Per-frame update

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let sceneView = renderer as? ARSCNView,
                  let frame    = sceneView.session.currentFrame
            else { return }

            handTracker.maybeProcess(frame)

            // Project each 3D world joint to 2D screen coords using SceneKit's own
            // camera transform — the same one used to render everything else, so the
            // overlay will be pixel-perfect regardless of coordinate space quirks.
            let hands = handTracker.snapshot()
            var overlayHands: [HandOverlayHand] = []

            for hand in hands {
                var segs:   [(CGPoint, CGPoint)] = []
                var palms:  [Bool]               = []

                for (idx, (fi, ti)) in HandTracker.boneConnections.enumerated() {
                    guard let a = hand.joints[HandTracker.allJoints[fi]],
                          let b = hand.joints[HandTracker.allJoints[ti]] else { continue }

                    let pa = sceneView.projectPoint(SCNVector3(a.x, a.y, a.z))
                    let pb = sceneView.projectPoint(SCNVector3(b.x, b.y, b.z))

                    // z in SceneKit projectPoint is NDC [0,1]; outside = behind camera.
                    guard pa.z > 0, pa.z < 1, pb.z > 0, pb.z < 1 else { continue }

                    segs.append((CGPoint(x: Double(pa.x), y: Double(pa.y)),
                                 CGPoint(x: Double(pb.x), y: Double(pb.y))))
                    palms.append(Self.palmBoneIndices.contains(idx))
                }

                if !segs.isEmpty {
                    overlayHands.append(HandOverlayHand(isLeft: hand.isLeft,
                                                        segments: segs,
                                                        isPalmSegment: palms))
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.handOverlay?.update(overlayHands)
            }
        }

        // MARK: Anchor → node

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            if anchor.name == "keyboard" { return KeyboardNode.make() }
            if anchor.name == "keyboard_calibrated" {
                let node = KeyboardNode.make()
                if let d = calibration.calibrationData {
                    node.scale = SCNVector3(d.widthScale, 1, d.depthScale)
                }
                return node
            }
            if let name = anchor.name, name.hasPrefix("corner_") { return makeCornerMarker() }
            if let plane = anchor as? ARPlaneAnchor {
                placement.onPlaneAdded()
                return makePlaneNode(for: plane)
            }
            return nil
        }

        func renderer(_ renderer: SCNSceneRenderer,
                      didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor else { return }
            updatePlaneNode(node, for: plane)
        }

        // MARK: Small helpers

        private func makeCornerMarker() -> SCNNode {
            let s = SCNSphere(radius: 0.012)
            let m = SCNMaterial()
            m.diffuse.contents  = UIColor.orange
            m.emission.contents = UIColor.orange.withAlphaComponent(0.6)
            s.materials = [m]
            return SCNNode(geometry: s)
        }

        private func makePlaneNode(for anchor: ARPlaneAnchor) -> SCNNode {
            let root = SCNNode()
            let geo  = SCNPlane(width: CGFloat(anchor.planeExtent.width),
                                height: CGFloat(anchor.planeExtent.height))
            let mat  = SCNMaterial()
            mat.diffuse.contents = UIColor.cyan.withAlphaComponent(0.22)
            mat.isDoubleSided    = true
            geo.materials        = [mat]
            let child = SCNNode(geometry: geo)
            child.name            = "planeGeom"
            child.eulerAngles.x   = -.pi / 2
            child.simdPosition    = anchor.center
            root.addChildNode(child)
            return root
        }

        private func updatePlaneNode(_ node: SCNNode, for anchor: ARPlaneAnchor) {
            guard let child = node.childNode(withName: "planeGeom", recursively: false),
                  let geo   = child.geometry as? SCNPlane else { return }
            geo.width         = CGFloat(anchor.planeExtent.width)
            geo.height        = CGFloat(anchor.planeExtent.height)
            child.simdPosition = anchor.center
        }
    }
}

// MARK: - 2-D hand silhouette overlay

/// Draws Quest-style transparent hand fills using pre-projected 2D segments.
/// All coordinate math lives in the Coordinator; this view just paints lines.
final class HandOverlayView: UIView {
    private var hands: [HandOverlayHand] = []

    func update(_ hands: [HandOverlayHand]) {
        self.hands = hands
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.clear(rect)
        for hand in hands { drawHand(hand, in: ctx) }
    }

    private func drawHand(_ hand: HandOverlayHand, in ctx: CGContext) {
        let fill = UIColor(red: 0.05, green: 0.90, blue: 0.95, alpha: 0.55)
        let glow = UIColor(red: 0.00, green: 0.80, blue: 1.00, alpha: 0.70)

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: .zero, blur: 22, color: glow.cgColor)
        ctx.setStrokeColor(fill.cgColor)

        for (i, (a, b)) in hand.segments.enumerated() {
            ctx.setLineWidth(hand.isPalmSegment[i] ? 44 : 30)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
