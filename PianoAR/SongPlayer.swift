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
    private(set) var acceptedGroupKeyIndices: Set<Int> = []

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
        acceptedGroupKeyIndices.removeAll()
        feedbackLine  = "Ready: \(song.title ?? "Practice")"
    }

    func play() {
        guard song != nil else { return }
        expectedIndex = 0
        acceptedCount = 0
        mistakeCount  = 0
        acceptedGroupKeyIndices.removeAll()
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

    func expectedKeyIndicesNow() -> Set<Int> {
        guard guidedMode,
              isPlaying,
              expectedIndex < notes.count
        else { return [] }

        return Set(currentExpectedGroup().compactMap { item in item.keyIndex })
    }

    func expectedKeyIndexNow() -> Int? {
        expectedKeyIndicesNow().sorted().first
    }

    func registerPress(keyIndex: Int, noteName: String) -> PracticePressResult {
        guard isPlaying else { return .ignored }
        guard guidedMode else {
            return .correct(expectedKeyIndex: keyIndex, noteName: noteName)
        }

        let group = currentExpectedGroup()
        let expectedKeyIndices = Set(group.compactMap { item in item.keyIndex })
        guard !group.isEmpty,
              !expectedKeyIndices.isEmpty
        else {
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = false
                self?.feedbackLine = "Complete"
            }
            return .ignored
        }

        let expectedName = promptFor(group: group, excluding: acceptedGroupKeyIndices)
        guard expectedKeyIndices.contains(keyIndex) else {
            mistakeCount += 1
            DispatchQueue.main.async { [weak self] in
                self?.feedbackLine = "Try \(expectedName) again"
            }
            return .wrong(
                playedKeyIndex: keyIndex,
                playedName: noteName,
                expectedKeyIndex: expectedKeyIndices.sorted().first ?? keyIndex,
                expectedName: expectedName
            )
        }

        if acceptedGroupKeyIndices.contains(keyIndex) {
            return .ignored
        }

        acceptedGroupKeyIndices.insert(keyIndex)
        acceptedCount += 1
        let acceptedNoteName = group.first { item in item.keyIndex == keyIndex }?.note.key ?? noteName

        let groupComplete = expectedKeyIndices.isSubset(of: acceptedGroupKeyIndices)
        if groupComplete {
            let acceptedBeat = notes[expectedIndex].startBeat
            advanceExpectedGroup()
            acceptedGroupKeyIndices.removeAll()
            startHostTime = CACurrentMediaTime() - acceptedBeat * 60.0 / bpm
        }

        if expectedIndex >= notes.count {
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = false
                self?.feedbackLine = "Complete: \(self?.acceptedCount ?? 0) notes"
            }
        } else {
            let prompt: String
            if groupComplete {
                prompt = nextPrompt(prefix: "Good \(acceptedNoteName)")
            } else {
                let remaining = promptFor(group: group, excluding: acceptedGroupKeyIndices)
                prompt = "Good \(acceptedNoteName): add \(remaining)"
            }
            DispatchQueue.main.async { [weak self] in
                self?.feedbackLine = prompt
            }
        }

        return .correct(expectedKeyIndex: keyIndex, noteName: acceptedNoteName)
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
        return "\(prefix): \(promptFor(group: currentExpectedGroup()))"
    }

    private func currentGroupRange() -> Range<Int>? {
        guard expectedIndex < notes.count else { return nil }
        let startBeat = notes[expectedIndex].startBeat
        var end = expectedIndex
        while end < notes.count,
              abs(notes[end].startBeat - startBeat) < 0.001 {
            end += 1
        }
        return expectedIndex..<end
    }

    private func currentExpectedGroup() -> [(note: SongNote, keyIndex: Int?)] {
        guard let range = currentGroupRange() else { return [] }
        return range.map { idx in
            let note = notes[idx]
            let keyIndex = note.midiNote.flatMap { midiToKeyIndex[$0] }
            return (note: note, keyIndex: keyIndex)
        }
    }

    private func advanceExpectedGroup() {
        guard let range = currentGroupRange() else { return }
        expectedIndex = range.upperBound
    }

    private func promptFor(group: [(note: SongNote, keyIndex: Int?)],
                           excluding accepted: Set<Int> = []) -> String {
        let names = group.compactMap { item -> String? in
            if let keyIndex = item.keyIndex, accepted.contains(keyIndex) {
                return nil
            }
            return item.note.key
        }
        return names.isEmpty ? "done" : names.joined(separator: " + ")
    }
}
