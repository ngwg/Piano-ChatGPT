import Foundation
import Combine
import QuartzCore

final class SongPlayer: ObservableObject {
    @Published var isPlaying = false

    // Set once at load/play, stable during playback.
    // Render thread reads these without a lock — benign on ARM64
    // because writes happen on the main thread and the values are
    // stable once playback starts.
    private(set) var song:          Song?    = nil
    private(set) var notes:         [SongNote] = []
    private(set) var startHostTime: Double   = 0
    private(set) var bpm:           Double   = 120

    // Pre-built lookup so the render thread never allocates.
    private(set) var midiToKeyIndex: [Int: Int] = [:]

    // MARK: - Control (call from main thread)

    func load(_ song: Song) {
        self.song          = song
        self.notes         = song.notes
        self.bpm           = song.bpm
        self.midiToKeyIndex = Dictionary(
            uniqueKeysWithValues: KeyboardLayout.keys.map { ($0.midiNote, $0.index) }
        )
    }

    func play() {
        guard song != nil else { return }
        // Offset so beat 0 maps to now.
        startHostTime = CACurrentMediaTime()
        isPlaying     = true
    }

    func stop() {
        isPlaying = false
    }

    func restart() {
        guard song != nil else { return }
        startHostTime = CACurrentMediaTime()
        isPlaying     = true
    }

    // MARK: - Render-thread query (call from SCNSceneRenderer delegate)

    /// Current playback beat, computed from wall time. Pure read — safe to call from any thread.
    func beatNow() -> Double {
        guard isPlaying else { return 0 }
        let raw = (CACurrentMediaTime() - startHostTime) * bpm / 60.0
        // Loop using modulo so no state is mutated from the render thread.
        if let last = notes.last {
            let totalBeats = last.startBeat + last.durationBeats + 2.0
            return raw.truncatingRemainder(dividingBy: totalBeats)
        }
        return raw
    }
}
