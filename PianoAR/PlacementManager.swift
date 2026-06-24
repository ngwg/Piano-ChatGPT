import ARKit
import SceneKit
import Combine

enum PlacementState {
    case scanning       // looking for horizontal planes
    case readyToPlace   // at least one plane found, waiting for tap
    case placed         // keyboard anchor created
}

final class PlacementManager: ObservableObject {
    @Published var state: PlacementState = .scanning

    weak var sceneView: ARSCNView?

    // Called from ARSCNViewDelegate on the rendering thread when a plane anchor appears.
    func onPlaneAdded() {
        guard state == .scanning else { return }
        DispatchQueue.main.async { self.state = .readyToPlace }
    }

    // Called from a tap gesture on the main thread.
    func handleTap(at screenPoint: CGPoint) {
        guard state == .readyToPlace, let sv = sceneView else { return }

        guard let query = sv.raycastQuery(
            from: screenPoint,
            allowing: .estimatedPlane,
            alignment: .horizontal
        ) else { return }

        guard let hit = sv.session.raycast(query).first else { return }

        let anchor = ARAnchor(name: "keyboard", transform: hit.worldTransform)
        sv.session.add(anchor: anchor)
        state = .placed
    }

    // Remove the keyboard anchor so the user can re-place it.
    func reset(session: ARSessionModel) {
        if let frame = session.session.currentFrame {
            for anchor in frame.anchors where anchor.name == "keyboard" {
                session.session.remove(anchor: anchor)
            }
            let hasPlanes = frame.anchors.contains { $0 is ARPlaneAnchor }
            DispatchQueue.main.async {
                self.state = hasPlanes ? .readyToPlace : .scanning
            }
        } else {
            DispatchQueue.main.async { self.state = .scanning }
        }
    }
}
