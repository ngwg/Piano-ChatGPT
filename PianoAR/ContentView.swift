import SwiftUI

struct ContentView: View {
    @StateObject private var session   = ARSessionModel()
    @StateObject private var placement = PlacementManager()

    var body: some View {
        ZStack {
            ARPassthroughView(session: session, placement: placement)
                .ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    HUDPanel(session: session, placement: placement)
                        .padding(12)
                    Spacer()
                    if placement.state == .placed {
                        Button {
                            placement.reset(session: session)
                        } label: {
                            Text("Reset")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.red.opacity(0.7))
                                .foregroundStyle(.white)
                                .cornerRadius(8)
                        }
                        .padding(12)
                    }
                }
                Spacer()
                if placement.state == .readyToPlace {
                    Text("Tap a flat surface to place the keyboard")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.6))
                        .cornerRadius(10)
                        .padding(.bottom, 40)
                }
            }
        }
        .background(Color.black)
    }
}

private struct HUDPanel: View {
    @ObservedObject var session:   ARSessionModel
    @ObservedObject var placement: PlacementManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PianoAR — Phase 1")
                .font(.caption.bold())
            Text("Tracking: \(session.trackingStateDescription)")
                .font(.caption2)
            Text("LiDAR: \(session.lidarAvailable ? "yes" : "no")")
                .font(.caption2)
            Text(stateLabel)
                .font(.caption2)
        }
        .padding(8)
        .background(.black.opacity(0.55))
        .foregroundStyle(.white)
        .cornerRadius(8)
    }

    private var stateLabel: String {
        switch placement.state {
        case .scanning:     return "Scanning for surfaces..."
        case .readyToPlace: return "Surface found — tap to place"
        case .placed:       return "Keyboard placed"
        }
    }
}
