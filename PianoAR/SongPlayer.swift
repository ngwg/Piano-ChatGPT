import Foundation
import Combine
import QuartzCore

enum PracticePressResult {
    case ignored
    case correct(expectedKeyIndex: Int, noteName: String)
    case wrong(playedKeyIndex: Int, playedName: String, expectedKeyIndex: Int, expectedName: String)
}

final class SongPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var feedbackLine = ""

    // Set once at load/play, stable during playback.
    // Render thread reads these without a lock — benign on ARM64
    // because writes happen on the main thread and the values are
    // stable once playback starts.
    private(set) var song:          Song?    = nil
    private(set) var notes:         [SongNote] = []
    private(set) var startHostTime: Double   = 0
    private(set) var bpm:           Double   = 120
    private(set) var expectedIndex: Int      = 0
    private(set) var acceptedCount: Int      = 0
    private(set) var mistakeCount:  Int      = 0
    private(set) var guidedMode:    Bool     = true

    // Pre-built lookup so the render thread never allocates.
    private(set) var midiToKeyIndex: [Int: Int] = [:]
    private let countInBeats = 2.0

    // MARK: - Control (call from main thread)

    func load(_ song: Song) {
        self.song          = song
        self.notes         = song.notes.sorted {
            if $0.startBeat == $1.startBeat { return ($0.midiNote ?? 0) < ($1.midiNote ?? 0) }
            return $0.startBeat < $1.startBeat
        }
        self.bpm           = song.bpm
        self.midiToKeyIndex = Dictionary(
            uniqueKeysWithValues: KeyboardLayout.keys.map { ($0.midiNote, $0.index) }
        )
        expectedIndex = 0
        acceptedCount = 0
        mistakeCount  = 0
        feedbackLine  = "Ready: \(song.title ?? "Practice")"
    }

    func play() {
        guard song != nil else { return }
        expectedIndex = 0
        acceptedCount = 0
        mistakeCount  = 0
        startHostTime = CACurrentMediaTime() + countInBeats * 60.0 / bpm
        isPlaying     = true
        feedbackLine  = nextPrompt(prefix: "Get ready")
    }

    func stop() {
        isPlaying = false
        feedbackLine = "Stopped"
    }

    func restart() {
        guard song != nil else { return }
        play()
    }

    func expectedKeyIndexNow() -> Int? {
        guard guidedMode,
              isPlaying,
              expectedIndex < notes.count,
              let midi = notes[expectedIndex].midiNote
        else { return nil }
        return midiToKeyIndex[midi]
    }

    func registerPress(keyIndex: Int, noteName: String) -> PracticePressResult {
        guard isPlaying else { return .ignored }
        guard guidedMode else {
            return .correct(expectedKeyIndex: keyIndex, noteName: noteName)
        }
        guard expectedIndex < notes.count,
              let expectedMidi = notes[expectedIndex].midiNote,
              let expectedKeyIndex = midiToKeyIndex[expectedMidi]
        else {
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = false
                self?.feedbackLine = "Complete"
            }
            return .ignored
        }

        let expectedName = notes[expectedIndex].key
        guard keyIndex == expectedKeyIndex else {
            mistakeCount += 1
            DispatchQueue.main.async { [weak self] in
                self?.feedbackLine = "Try \(expectedName) again"
            }
            return .wrong(
                playedKeyIndex: keyIndex,
                playedName: noteName,
                expectedKeyIndex: expectedKeyIndex,
                expectedName: expectedName
            )
        }

        let acceptedBeat = notes[expectedIndex].startBeat
        expectedIndex += 1
        acceptedCount += 1
        startHostTime = CACurrentMediaTime() - acceptedBeat * 60.0 / bpm

        if expectedIndex >= notes.count {
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = false
                self?.feedbackLine = "Complete: \(self?.acceptedCount ?? 0) notes"
            }
        } else {
            let prompt = nextPrompt(prefix: "Good \(expectedName)")
            DispatchQueue.main.async { [weak self] in
                self?.feedbackLine = prompt
            }
        }

        return .correct(expectedKeyIndex: expectedKeyIndex, noteName: expectedName)
    }

    // MARK: - Render-thread query (call from SCNSceneRenderer delegate)

    /// Current playback beat, computed from wall time. Pure read — safe to call from any thread.
    func beatNow() -> Double {
        guard isPlaying else { return 0 }
        let raw = (CACurrentMediaTime() - startHostTime) * bpm / 60.0
        if guidedMode, expectedIndex < notes.count {
            return min(raw, notes[expectedIndex].startBeat)
        }
        // Loop using modulo so no state is mutated from the render thread.
        if let last = notes.last {
            let totalBeats = last.startBeat + last.durationBeats + 2.0
            return raw.truncatingRemainder(dividingBy: totalBeats)
        }
        return raw
    }

    private func nextPrompt(prefix: String) -> String {
        guard expectedIndex < notes.count else { return "\(prefix): done" }
        return "\(prefix): \(notes[expectedIndex].key)"
    }
}
