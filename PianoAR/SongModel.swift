import Foundation

struct SongNote: Codable {
    let key:           String   // "C4", "F#3", "Bb5"
    let startBeat:     Double
    let durationBeats: Double
    let hand:          String?  // "left" | "right" | nil

    var isLeft: Bool { hand == "left" }

    // MIDI note number (21–108 for 88-key piano). "C4" = 60, "A4" = 69.
    var midiNote: Int? {
        guard !key.isEmpty else { return nil }
        let letters   = ["C", "D", "E", "F", "G", "A", "B"]
        let semitones = [  0,   2,   4,   5,   7,   9,  11]

        var s = key

        // Octave digit is always the last character.
        guard let lastCh = s.last, let octave = Int(String(lastCh)) else { return nil }
        s = String(s.dropLast())

        var accidental = 0
        if      s.hasSuffix("#") { accidental =  1; s = String(s.dropLast()) }
        else if s.hasSuffix("b") { accidental = -1; s = String(s.dropLast()) }

        guard let idx = letters.firstIndex(of: s) else { return nil }
        // MIDI: C(-1) = 0, C0 = 12, C4 = 60
        return (octave + 1) * 12 + semitones[idx] + accidental
    }
}

struct Song: Codable {
    let title: String?
    let bpm:   Double
    let notes: [SongNote]

    static func load(named name: String) -> Song? {
        guard let url  = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Song.self, from: data)
    }
}
