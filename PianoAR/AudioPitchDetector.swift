import AVFoundation
import Accelerate
import Combine
import Foundation
import QuartzCore

struct DetectedNote {
    let keyIndex: Int       // 0...87
    let midiNote: Int       // 21...108
    let magnitude: Float    // 0...1 normalized within the current frame
    let isOnset: Bool       // true only on the first analysis frame of an attack
}

struct PitchSnapshot {
    let activeNotes: [DetectedNote]
    let timestamp: TimeInterval
}

/// Conservative microphone note/onset detector.
///
/// This is intentionally a confidence/debug signal, not a replacement for the
/// LiDAR + hand trajectory press detector. It is best at clear attacks and
/// monophonic or sparse passages; dense chords should be treated as hints.
final class AudioPitchDetector: ObservableObject {
    @Published var lastDetected: String = ""
    @Published var fingerDebugLines: [String] = []
    @Published private(set) var microphoneState: String = "mic off"

    // FFT parameters: 8192 samples gives useful low-note resolution, while the
    // hop keeps UI feedback responsive enough for press corroboration.
    private let fftN = 8192
    private let hop = 2048
    private let log2n: vDSP_Length = 13

    private let silenceRMS: Float = 0.00035
    private let onsetRatio: Float = 2.6
    private let activeFloorRatio: Float = 1.7
    private let onsetFloorRatio: Float = 2.4
    private let maxPublishedNotes = 6
    private let minOnsetInterval: TimeInterval = 0.09

    // Computed from the actual input sample rate in configureAndStart().
    private var binRes: Float = 1
    private var keyBins: [Int] = []

    // A0 (27.5 Hz) through C8 (4186 Hz).
    private static let keyFreqs: [Float] = (0..<88).map {
        440.0 * powf(2.0, Float(21 + $0 - 69) / 12.0)
    }

    // Pre-allocated FFT buffers.
    private var fftSetup: FFTSetup!
    private var window: [Float]
    private var frame: [Float]
    private var rp: [Float]
    private var ip: [Float]
    private var mag: [Float]

    // Circular sample buffer.
    private var ring: [Float]
    private var ringW = 0
    private var hopAcc = 0

    // Per-key state.
    private var energy: [Float] = .init(repeating: 0, count: 88)
    private var prevEnergy: [Float] = .init(repeating: 0, count: 88)
    private var active: [Bool] = .init(repeating: false, count: 88)
    private var decayCnt: [Int] = .init(repeating: 0, count: 88)
    private var lastOnsetTime: [TimeInterval] = .init(repeating: 0, count: 88)

    private let engine = AVAudioEngine()
    private let stateQueue = DispatchQueue(label: "com.pianoar.audio-detector.state")
    private var tapInstalled = false
    private var running = false

    // Thread-safe snapshot for the render thread.
    private let lock = NSLock()
    private var _snap = PitchSnapshot(activeNotes: [], timestamp: 0)
    private var lastUI: TimeInterval = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftN)
        vDSP_hann_window(&window, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))

        frame = .init(repeating: 0, count: fftN)
        rp = .init(repeating: 0, count: fftN / 2)
        ip = .init(repeating: 0, count: fftN / 2)
        mag = .init(repeating: 0, count: fftN / 2)
        ring = .init(repeating: 0, count: fftN)
    }

    deinit {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Start / Stop

    func start() {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            stateQueue.async { [weak self] in self?.configureAndStart() }
        case .denied:
            publishState("mic denied")
            publishSnapshot([], timestamp: CACurrentMediaTime())
        case .undetermined:
            publishState("mic permission")
            session.requestRecordPermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.stateQueue.async { self.configureAndStart() }
                } else {
                    self.publishState("mic denied")
                    self.publishSnapshot([], timestamp: CACurrentMediaTime())
                }
            }
        @unknown default:
            publishState("mic unavailable")
            publishSnapshot([], timestamp: CACurrentMediaTime())
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.tapInstalled {
                self.engine.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
            self.engine.stop()
            self.running = false
            self.resetAudioState()
            self.publishSnapshot([], timestamp: CACurrentMediaTime())
            self.publishState("mic off")
        }
    }

    /// Thread-safe read for the render thread.
    func snapshot() -> PitchSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return _snap
    }

    private func configureAndStart() {
        guard !running else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .mixWithOthers]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(Double(hop) / 48_000.0)
            try session.setActive(true)

            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }

            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
                publishState("mic unavailable")
                return
            }

            binRes = Float(fmt.sampleRate) / Float(fftN)
            keyBins = Self.keyFreqs.map { Int(($0 / binRes).rounded()) }
            resetAudioState()

            input.installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(hop),
                format: fmt
            ) { [weak self] buf, _ in
                self?.ingest(buf)
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
            running = true
            publishState("mic listening")
        } catch {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            running = false
            publishState("mic error")
            publishSnapshot([], timestamp: CACurrentMediaTime())
        }
    }

    // MARK: - Audio ingest

    private func ingest(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }

        let s = ch[0]
        for i in 0..<n {
            ring[ringW] = s[i]
            ringW = (ringW + 1) % fftN
        }

        hopAcc += n
        if hopAcc >= hop {
            hopAcc = 0
            analyze()
        }
    }

    // MARK: - FFT + note detection

    private func analyze() {
        for i in 0..<fftN {
            frame[i] = ring[(ringW + i) % fftN]
        }

        let rms = rootMeanSquare(frame)
        let now = CACurrentMediaTime()
        guard rms >= silenceRMS else {
            decayForSilence(timestamp: now)
            return
        }

        for i in 0..<fftN {
            frame[i] *= window[i]
        }
        performFFT()
        computeKeyEnergies()

        let floor = noiseFloor()
        suppressHarmonics(floor: floor)
        let detected = trackNotes(floor: floor, timestamp: now)

        publishSnapshot(detected, timestamp: now)
        publishUI(detected, floor: floor, rms: rms, timestamp: now)
    }

    private func rootMeanSquare(_ values: [Float]) -> Float {
        var sum: Float = 0
        for v in values {
            sum += v * v
        }
        return sqrtf(sum / Float(max(values.count, 1)))
    }

    private func decayForSilence(timestamp: TimeInterval) {
        for i in 0..<88 {
            energy[i] = 0
            prevEnergy[i] *= 0.4
            decayCnt[i] += 1
            if decayCnt[i] > 2 {
                active[i] = false
            }
        }
        publishSnapshot([], timestamp: timestamp)

        guard timestamp - lastUI > 0.15 else { return }
        lastUI = timestamp
        DispatchQueue.main.async { [weak self] in
            self?.lastDetected = ""
            self?.fingerDebugLines = ["rms below gate"]
        }
    }

    private func performFFT() {
        rp.withUnsafeMutableBufferPointer { rpBuf in
            ip.withUnsafeMutableBufferPointer { ipBuf in
                var split = DSPSplitComplex(
                    realp: rpBuf.baseAddress!,
                    imagp: ipBuf.baseAddress!
                )

                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(
                        raw.bindMemory(to: DSPComplex.self).baseAddress!,
                        2,
                        &split,
                        1,
                        vDSP_Length(self.fftN / 2)
                    )
                }

                vDSP_fft_zrip(
                    self.fftSetup,
                    &split,
                    1,
                    self.log2n,
                    FFTDirection(kFFTDirection_Forward)
                )

                self.mag.withUnsafeMutableBufferPointer { mBuf in
                    vDSP_zvmags(
                        &split,
                        1,
                        mBuf.baseAddress!,
                        1,
                        vDSP_Length(self.fftN / 2)
                    )
                }
            }
        }
    }

    private func computeKeyEnergies() {
        let halfN = fftN / 2
        for i in 0..<88 {
            guard i < keyBins.count else {
                energy[i] = 0
                continue
            }

            let bin = keyBins[i]
            guard bin > 1, bin < halfN - 2 else {
                energy[i] = 0
                continue
            }

            var e = mag[bin - 1] + mag[bin] + mag[bin + 1]

            // Acoustic piano fundamentals can be weak, especially in the bass.
            for (h, w) in [(2, Float(0.42)), (3, Float(0.28)), (4, Float(0.16))] {
                let hb = bin * h
                guard hb > 0, hb < halfN - 1 else { continue }
                e += (mag[hb - 1] + mag[hb] + mag[hb + 1]) * w
            }

            energy[i] = e
        }
    }

    private func noiseFloor() -> Float {
        var sorted = energy
        sorted.sort()
        return max(sorted[22] * 3.0, 1e-10)
    }

    private func suppressHarmonics(floor: Float) {
        for i in 0..<87 {
            guard energy[i] > floor else { continue }
            let freq = Self.keyFreqs[i]

            for h in 2...6 {
                let harmonicFreq = freq * Float(h)
                for j in (i + 1)..<88 {
                    let candidateFreq = Self.keyFreqs[j]
                    if candidateFreq > harmonicFreq * 1.03 { break }

                    let cents = fabsf(1200.0 * log2f(harmonicFreq / candidateFreq))
                    guard cents < 50 else { continue }

                    let expected = energy[i] * (0.3 / Float(h))
                    if energy[j] < expected * 2.5 {
                        energy[j] *= 0.05
                    }
                }
            }
        }
    }

    private struct NoteCandidate {
        let index: Int
        let energy: Float
        let onset: Bool
    }

    private func trackNotes(floor: Float, timestamp: TimeInterval) -> [DetectedNote] {
        var candidates: [NoteCandidate] = []

        for i in 0..<88 {
            let e = energy[i]
            let strong = e > floor * activeFloorRatio
            let rising = e > max(prevEnergy[i] * onsetRatio, floor * onsetFloorRatio)
            let onset = rising && timestamp - lastOnsetTime[i] > minOnsetInterval

            if onset {
                lastOnsetTime[i] = timestamp
            }

            if strong {
                decayCnt[i] = 0
                active[i] = true
            } else {
                decayCnt[i] += 1
                if decayCnt[i] > 4 {
                    active[i] = false
                }
            }

            prevEnergy[i] = e

            if active[i] {
                candidates.append(NoteCandidate(index: i, energy: e, onset: onset))
            }
        }

        guard let strongest = candidates.map(\.energy).max(), strongest > 0 else {
            return []
        }

        let publishFloor = max(floor * activeFloorRatio, strongest * 0.08)
        let filtered = candidates
            .filter { $0.energy >= publishFloor }
            .sorted { $0.energy > $1.energy }
            .prefix(maxPublishedNotes)

        return filtered
            .sorted { $0.index < $1.index }
            .map { candidate in
                DetectedNote(
                    keyIndex: candidate.index,
                    midiNote: 21 + candidate.index,
                    magnitude: min(1.0, candidate.energy / max(strongest, 1e-10)),
                    isOnset: candidate.onset
                )
            }
    }

    // MARK: - Publishing

    private func publishSnapshot(_ notes: [DetectedNote], timestamp: TimeInterval) {
        let snap = PitchSnapshot(activeNotes: notes, timestamp: timestamp)
        lock.lock()
        _snap = snap
        lock.unlock()
    }

    private func publishUI(_ notes: [DetectedNote],
                           floor: Float,
                           rms: Float,
                           timestamp: TimeInterval) {
        guard timestamp - lastUI > 0.08 else { return }
        lastUI = timestamp

        let onsets = notes
            .filter(\.isOnset)
            .map { KeyboardLayout.keys[$0.keyIndex].noteName }
        let actives = notes.map { KeyboardLayout.keys[$0.keyIndex].noteName }

        let label: String
        if !onsets.isEmpty {
            label = onsets.joined(separator: " ")
        } else if !actives.isEmpty {
            label = actives.joined(separator: " ")
        } else {
            label = ""
        }

        var dbg = notes.prefix(10).map { note -> String in
            let name = KeyboardLayout.keys[note.keyIndex].noteName
            let magText = String(format: "%.2f", note.magnitude)
            return "\(name) \(magText)\(note.isOnset ? " ON" : "")"
        }
        dbg.append(String(format: "rms %.4f floor %.2e", rms, floor))

        DispatchQueue.main.async { [weak self] in
            self?.lastDetected = label
            self?.fingerDebugLines = dbg
        }
    }

    private func publishState(_ value: String) {
        DispatchQueue.main.async { [weak self] in
            self?.microphoneState = value
        }
    }

    private func resetAudioState() {
        ring = .init(repeating: 0, count: fftN)
        frame = .init(repeating: 0, count: fftN)
        mag = .init(repeating: 0, count: fftN / 2)
        ringW = 0
        hopAcc = 0
        energy = .init(repeating: 0, count: 88)
        prevEnergy = .init(repeating: 0, count: 88)
        active = .init(repeating: false, count: 88)
        decayCnt = .init(repeating: 0, count: 88)
        lastOnsetTime = .init(repeating: 0, count: 88)
    }
}
