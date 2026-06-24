import Foundation

struct KeyboardLayout {
    static let whiteKeyWidth:       Float = 0.0235  // 23.5 mm
    static let whiteKeyDepth:       Float = 0.148   // 148 mm
    static let whiteKeyHeight:      Float = 0.015   // 15 mm
    static let blackKeyWidth:       Float = 0.0137  // 13.7 mm
    static let blackKeyDepth:       Float = 0.090   // 90 mm
    static let blackKeyExtraHeight: Float = 0.012   // how much black keys protrude above white
    static let totalWidth: Float = 52 * whiteKeyWidth  // ~1.222 m

    struct Key {
        let index:    Int    // 0–87 (A0 to C8)
        let midiNote: Int    // 21–108
        let noteName: String // "A0", "C#4", etc.
        let isBlack:  Bool
        let xCenter:  Float  // distance from left edge of keyboard to key center
    }

    static let keys: [Key] = buildKeys()

    private static func buildKeys() -> [Key] {
        let noteNames    = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let isBlackMap   = [false,true,false,true,false,
                            false,true,false,true,false,true,false]

        // First pass: assign white-key index to each key
        struct Raw {
            var midi: Int; var st: Int; var octave: Int
            var isBlack: Bool; var whiteIdx: Int
        }
        var raw: [Raw] = []
        raw.reserveCapacity(88)
        var wIdx = 0
        for i in 0..<88 {
            let midi  = 21 + i
            let st    = ((midi % 12) + 12) % 12
            let oct   = midi / 12 - 1
            let black = isBlackMap[st]
            raw.append(Raw(midi: midi, st: st, octave: oct,
                           isBlack: black, whiteIdx: black ? -1 : wIdx))
            if !black { wIdx += 1 }
        }

        // Second pass: compute xCenter
        // White keys: evenly spaced at (whiteIdx + 0.5) * whiteKeyWidth
        // Black keys: midpoint between their adjacent white key centers
        var result: [Key] = []
        result.reserveCapacity(88)
        for (i, r) in raw.enumerated() {
            let xc: Float
            if !r.isBlack {
                xc = (Float(r.whiteIdx) + 0.5) * whiteKeyWidth
            } else {
                let prevX: Float = raw[..<i]
                    .last(where: { !$0.isBlack })
                    .map { (Float($0.whiteIdx) + 0.5) * whiteKeyWidth } ?? 0
                let nextX: Float = raw[(i + 1)...]
                    .first(where: { !$0.isBlack })
                    .map { (Float($0.whiteIdx) + 0.5) * whiteKeyWidth } ?? (prevX + whiteKeyWidth)
                xc = (prevX + nextX) / 2
            }
            result.append(Key(
                index:    i,
                midiNote: r.midi,
                noteName: "\(noteNames[r.st])\(r.octave)",
                isBlack:  r.isBlack,
                xCenter:  xc
            ))
        }
        return result
    }
}
