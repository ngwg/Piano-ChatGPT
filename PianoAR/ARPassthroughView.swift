import SwiftUI
import ARKit
import SceneKit

struct ARPassthroughView: UIViewRepresentable {
    let session: ARSessionModel
    let placement: PlacementManager

    func makeCoordinator() -> Coordinator {
        Coordinator(placement: placement)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session.session
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.contentMode = .scaleAspectFill
        view.debugOptions = []

        // Give PlacementManager access for raycasting
        placement.sceneView = view

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Keep the sceneView reference current in case the view is recycled
        placement.sceneView = uiView
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let placement: PlacementManager

        init(placement: PlacementManager) {
            self.placement = placement
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ARSCNView else { return }
            placement.handleTap(at: gesture.location(in: view))
        }

        // MARK: ARSCNViewDelegate

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            if let plane = anchor as? ARPlaneAnchor {
                placement.onPlaneAdded()
                return makePlaneVisualizationNode(for: plane)
            }
            if anchor.name == "keyboard" {
                return KeyboardNode.make()
            }
            return nil
        }

        func renderer(_ renderer: SCNSceneRenderer,
                      didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor else { return }
            updatePlaneNode(node, for: plane)
        }

        // MARK: Plane visualization helpers

        private func makePlaneVisualizationNode(for anchor: ARPlaneAnchor) -> SCNNode {
            let root = SCNNode()
            let plane = SCNPlane(
                width:  CGFloat(anchor.planeExtent.width),
                height: CGFloat(anchor.planeExtent.height)
            )
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.cyan.withAlphaComponent(0.22)
            mat.isDoubleSided = true
            plane.materials = [mat]

            let geomNode = SCNNode(geometry: plane)
            geomNode.name = "planeGeom"
            // SCNPlane is in the XY plane; ARKit horizontal planes are XZ — rotate to match
            geomNode.eulerAngles.x = -.pi / 2
            geomNode.simdPosition = anchor.center
            root.addChildNode(geomNode)
            return root
        }

        private func updatePlaneNode(_ node: SCNNode, for anchor: ARPlaneAnchor) {
            guard
                let geomNode = node.childNode(withName: "planeGeom", recursively: false),
                let plane = geomNode.geometry as? SCNPlane
            else { return }
            plane.width  = CGFloat(anchor.planeExtent.width)
            plane.height = CGFloat(anchor.planeExtent.height)
            geomNode.simdPosition = anchor.center
        }
    }
}
