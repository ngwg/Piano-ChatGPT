import SwiftUI
import ARKit
import SceneKit

/// Phase 0: bare ARKit passthrough using ARSCNView so we can later attach
/// SceneKit-anchored content (keyboard overlay, fingertip markers) without
/// switching renderers. RealityKit would also work; SceneKit keeps the
/// dependency surface and learning curve smaller for early phases.
struct ARPassthroughView: UIViewRepresentable {
    let session: ARSessionModel

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session.session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.contentMode = .scaleAspectFill

        // Lightweight debug visualization while we're confirming the AR
        // session is alive on-device. Remove once Phase 0 is signed off.
        view.debugOptions = [.showWorldOrigin, .showFeaturePoints]
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
