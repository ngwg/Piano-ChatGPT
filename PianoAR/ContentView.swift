import SwiftUI

struct ContentView: View {
    @StateObject private var session = ARSessionModel()

    var body: some View {
        ZStack {
            ARPassthroughView(session: session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    HUDPanel(session: session)
                        .padding(12)
                    Spacer()
                }
                Spacer()
            }
        }
        .background(Color.black)
    }
}

private struct HUDPanel: View {
    @ObservedObject var session: ARSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PianoAR — Phase 0")
                .font(.caption.bold())
            Text("Tracking: \(session.trackingStateDescription)")
                .font(.caption2)
            Text("LiDAR: \(session.lidarAvailable ? "yes" : "no")")
                .font(.caption2)
            Text("Frames: \(session.frameCount)")
                .font(.caption2)
        }
        .padding(8)
        .background(.black.opacity(0.55))
        .foregroundStyle(.white)
        .cornerRadius(8)
    }
}
