import AVFoundation
import CoreML
import Foundation
import MusicCore

/// Basic Pitch uses 22.05 kHz mono, with 15 frames of context at each window edge.
enum RecordedMelody {
    private static let samples = 43_844
    private static let context = 15 * 256
    private static let hop = samples - 2 * context

    static func transcribe(_ recording: URL, passage: Passage, audioOrigin: Double = 0, mix: URL? = nil, vocalHints: [VocalHint] = [], progress: (Double) -> Void) throws -> [Phrase] {
        var url = Bundle.main.resourceURL?.appendingPathComponent("BasicPitch/nmp.mlpackage")
        #if DEBUG
        if url.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Models/BasicPitch/nmp.mlpackage")
        }
        #endif
        guard let url else { throw WorkError.audio("Modelo de transcrição ausente.") }
        let compiled = try MLModel.compileModel(at: url)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiled, configuration: config)
        let file = try AVAudioFile(forReading: recording)
        let format = file.processingFormat
        guard format.sampleRate == AudioFiles.rate, format.channelCount >= 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(2 * samples)) else {
            throw WorkError.audio("A transcrição requer o áudio de trabalho a 44,1 kHz.")
        }
        let input = try MLMultiArray(shape: [1, NSNumber(value: samples), 1], dataType: .float32)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input_2": MLFeatureValue(multiArray: input)])
        let first = Int64(((passage.start - audioOrigin) * AudioFiles.rate).rounded())
        let last = min(file.length, Int64(((passage.end - audioOrigin) * AudioFiles.rate).rounded()))
        let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
        let mixFile = try mix.map { try AVAudioFile(forReading: $0) }
        let mixBuffer = mixFile.flatMap { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: AVAudioFrameCount(2 * samples)) }
        if let mixFile, (mixFile.processingFormat.sampleRate != AudioFiles.rate || mixBuffer == nil) { throw WorkError.files }
        var tracker = LeadTracker()
        var envelope = EnergyEnvelope(origin: passage.start)
        for start in stride(from: first, to: last, by: 2 * hop) {
            try Task.checkCancellation()
            try autoreleasepool {
                let windowStart = start - Int64(2 * context)
                let from = max(windowStart, first)
                file.framePosition = from
                let frames = min(last - from, windowStart + Int64(2 * samples) - from)
                try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
                guard let data = buffer.floatChannelData else { throw WorkError.files }
                ptr.update(repeating: 0, count: samples)
                let right = data[Int(format.channelCount) > 1 ? 1 : 0]
                let padding = Int(from - windowStart) / 2
                for i in 0..<(Int(buffer.frameLength) / 2) {
                    let j = i * 2
                    ptr[i + padding] = (data[0][j] + right[j] + data[0][j + 1] + right[j + 1]) * 0.25
                }
                if let mixFile, let mixBuffer {
                    mixFile.framePosition = from + Int64((audioOrigin * AudioFiles.rate).rounded())
                    try mixFile.read(into: mixBuffer, frameCount: buffer.frameLength)
                    guard mixBuffer.frameLength == buffer.frameLength else { throw WorkError.files }
                }
                let result = try model.prediction(from: provider)
                guard let notes = result.featureValue(for: "Identity_1")?.multiArrayValue,
                      let contour = result.featureValue(for: "Identity")?.multiArrayValue,
                      let onsets = result.featureValue(for: "Identity_2")?.multiArrayValue,
                      contour.shape == [1, 172, 264], contour.dataType == .float32,
                      notes.shape == [1, 172, 88], onsets.shape == notes.shape,
                      notes.dataType == .float32, onsets.dataType == .float32 else { throw WorkError.files }
                for frame in 15..<157 {
                    let t = audioOrigin + Double(start) / AudioFiles.rate + Double(frame - 15) * Double(hop) / (142 * 22_050)
                    guard t < passage.end else { break }
                    let center = Int(((t - audioOrigin) * 22_050).rounded()) - Int(windowStart / 2)
                    let rms = envelope.append(ptr + center)
                    var relativeLevel: Float = 1
                    if let mixBuffer, let channels = mixBuffer.floatChannelData {
                        let index = 2 * (center - padding)
                        let n = min(512, Int(mixBuffer.frameLength) - index)
                        if index >= 0 && n > 0 {
                            var power: Float = 0
                            let right = channels[mixBuffer.format.channelCount > 1 ? 1 : 0]
                            for i in index..<(index + n) { power += channels[0][i] * channels[0][i] + right[i] * right[i] }
                            relativeLevel = rms / max(0.0001, sqrt(power / Float(2 * n)))
                        }
                    }
                    tracker.frame(notes, onsets, contour, index: frame, at: t, rms: rms, relativeLevel: relativeLevel)
                }
            }
            progress(min(1, Double(start - first + Int64(2 * hop)) / Double(max(1, last - first))))
        }
        return try tracker.finish(at: min(passage.end, audioOrigin + Double(last) / AudioFiles.rate), automatic: mixFile != nil, voices: vocalHints, envelope: envelope)
    }

    // Input is in semitones at the network frame rate (~86 Hz).
    static func hasVibrato(_ curve: [Float]) -> Bool {
        guard curve.count >= 35 else { return false }
        let sorted = curve.sorted()
        let span = sorted[sorted.count * 9 / 10] - sorted[sorted.count / 10]
        guard (0.24...1.25).contains(span) else { return false }
        let centered = curve.map { $0 - sorted[sorted.count / 2] }
        var direction = 0, crossings = 0
        for v in centered where abs(v) > span * 0.18 {
            let next = v > 0 ? 1 : -1
            if direction != 0 && next != direction { crossings += 1 }
            direction = next
        }
        guard crossings >= 4 else { return false }
        return (9...20).contains { lag in
            var product: Float = 0, left: Float = 0, right: Float = 0
            for i in lag..<centered.count {
                let a = centered[i], b = centered[i - lag]
                product += a * b
                left += a * a
                right += b * b
            }
            return product > 0.65 * sqrt(max(0.000001, left * right))
        }
    }

    private struct EnergyEnvelope {
        let origin: Double
        var levels: [Float] = []
        private let spacing = Double(hop) / (142 * 4 * 22_050)

        init(origin: Double) { self.origin = origin }

        mutating func append(_ samples: UnsafePointer<Float>) -> Float {
            var peak: Float = 0
            for subframe in 0..<4 {
                var power: Float = 0
                for i in 0..<64 { power += samples[subframe * 64 + i] * samples[subframe * 64 + i] }
                let rms = sqrt(power / 64)
                levels.append(rms)
                peak = max(peak, rms)
            }
            return peak
        }

        // Pitch activation can pulse at each vibrato cycle. A second pick of the
        // same string also excites the waveform, or follows a measurable silence.
        func hasFreshAttack(at time: Double) -> Bool {
            let i = Int(((time - origin) / spacing).rounded())
            guard i >= 18, i + 11 < levels.count else { return true }
            let before = levels[(i - 18)..<(i - 4)].sorted()
            let baseline = before[before.count / 2]
            let after = levels[(i - 4)...(i + 11)].sorted()
            let crest = after[after.count * 3 / 4]
            return crest > baseline * 1.35 || before[2] < crest * 0.38
        }

        func refine(_ notes: inout [Event], until limit: Double) {
            guard !levels.isEmpty else { return }
            func bounds(_ lower: Double, _ upper: Double) -> Range<Int> {
                let first = min(levels.count, max(0, Int((lower - origin) / spacing)))
                let after = min(levels.count, max(first, Int((upper - origin) / spacing) + 1))
                return first..<after
            }
            for i in notes.indices {
                let note = notes[i]
                let next = i + 1 < notes.count ? notes[i + 1].time : limit
                let around = bounds(note.time - 0.025, min(note.time + 0.065, note.end))
                var start = note.time, end = note.end
                if let peak = levels[around].max(), let quiet = levels[around.prefix(4)].min(),
                   quiet < peak * 0.20, peak > 0.001 {
                    // Localize the pick after a quiet interval, preserving legato when
                    // the envelope gives no clear new attack.
                    if let attack = around.first(where: { levels[$0] > peak * 0.17 && levels[min(levels.count - 1, $0 + 1)] > peak * 0.17 }) {
                        start = origin + Double(attack) * spacing
                    }
                }
                let release = bounds(max(start + 0.06, note.end - 0.095), min(next, note.end + 0.045))
                let body = bounds(start, min(note.end, start + 0.16))
                if let peak = levels[body].max(), release.count >= 5,
                   let last = release.last(where: { levels[$0] > peak * 0.09 }),
                   release.upperBound - last >= 5 {
                    end = origin + Double(last + 1) * spacing
                }
                let previousEnd = i == 0 ? origin : notes[i - 1].end
                start = max(previousEnd, min(start, next - 0.061))
                end = min(next, max(start + 0.061, end))
                if end - start >= 0.06 {
                    notes[i].time = start
                    notes[i].duration = end - start
                }
            }
        }
    }

    private struct LeadTracker {
        var pitch: Int?
        var since = 0.0
        var peak: Float = 0
        var attackArmed = false
        var proposed: Int?
        var proposedSince = 0.0
        var proposedFrames = 0
        var peakRMS: Float = 0
        var proposedRMS: Float = 0
        var previous = [Float](repeating: 0, count: 87)
        var notes: [Event] = []
        struct Evidence {
            let time: Double
            let clear: Bool
            let audible: Bool
            let pitch: Int?
            let detune: Float
        }
        var evidence: [Evidence] = []

        mutating func frame(_ activations: MLMultiArray, _ attacks: MLMultiArray, _ contour: MLMultiArray, index: Int, at time: Double, rms: Float, relativeLevel: Float) {
            let values = activations.dataPointer.assumingMemoryBound(to: Float.self) + index * activations.strides[1].intValue
            let onsets = attacks.dataPointer.assumingMemoryBound(to: Float.self) + index * attacks.strides[1].intValue
            let pitchStride = activations.strides[2].intValue
            let attackStride = attacks.strides[2].intValue
            var best: Int?
            var strength: Float = 0
            var score: Float = 0
            var attack: Float = 0
            var strongest: Float = 0, second: Float = 0, third: Float = 0
            for midi in 40...86 {
                let bin = midi - 21
                let p = values[bin * pitchStride]
                let rise = max(0, p - previous[midi])
                previous[midi] = p
                guard rms > 0.00045, p >= (pitch == midi ? 0.24 : 0.36) else { continue }
                if p >= strongest { third = second; second = strongest; strongest = p }
                else if p >= second { third = second; second = p }
                else { third = max(third, p) }
                let onset = onsets[bin * attackStride]
                // A new pick can lead while a lower open string is still ringing.
                // Favour a continuing line over jumps to a backing chord or bass.
                let continuity: Float = pitch == midi ? 0.12 : 0
                let register = Float(min(24, midi - 40)) * 0.005
                let distance = pitch.map { Float(min(14, abs($0 - midi))) * 0.011 } ?? 0
                let weight = p + register + continuity + 0.30 * onset + 0.50 * rise - distance
                if weight > score { best = midi; strength = p; score = weight; attack = onset }
            }
            // A strummed chord has several equally plausible notes. Do not
            // arpeggiate it merely because their confidence curves cross.
            var detune: Float = 0
            if let best {
                let curve = contour.dataPointer.assumingMemoryBound(to: Float.self) + index * contour.strides[1].intValue
                let center = (best - 21) * 3
                var total: Float = 0
                for offset in -2...2 {
                    let p = curve[(center + offset) * contour.strides[2].intValue]
                    let weight = p * p * p
                    total += weight
                    detune += Float(offset) * weight
                }
                detune /= max(0.00001, 3 * total)
            }
            evidence.append(Evidence(time: time, clear: strength > 0.45 && strength == strongest && second < strength * 0.69,
                                     audible: relativeLevel >= 0.20, pitch: best, detune: detune))
            if third > 0.43 && third > strongest * 0.76 { best = nil; strength = 0; attack = 0 }
            if best != pitch {
                if proposedFrames == 0 || proposed != best {
                    proposed = best
                    proposedFrames = 0
                    proposedSince = time
                    proposedRMS = 0
                }
                proposedFrames += 1
                proposedRMS = max(proposedRMS, rms)
                // Bridge brief dropouts. Backdate confirmed changes to their first frame.
                if proposedFrames < (best == nil ? 4 : 3) { return }
                close(at: proposedSince)
                since = proposedSince
                pitch = best
                peak = strength
                peakRMS = proposedRMS
                attackArmed = false
            } else if pitch != nil {
                if attack < 0.27 { attackArmed = true }
                if attackArmed && attack > 0.52 && time - since >= 0.075 {
                    close(at: time)
                    since = time
                    peak = 0
                    peakRMS = 0
                    attackArmed = false
                }
                peak = max(peak, strength)
                peakRMS = max(peakRMS, rms)
            }
            proposedFrames = 0
        }

        mutating func close(at end: Double) {
            guard let pitch, end - since >= 0.065, peak >= 0.42,
                  let string = tuning.firstIndex(where: { (0...22).contains(pitch - $0) }) else { return }
            notes.append(Event(time: since, duration: end - since, string: string,
                               fret: pitch - tuning[string], velocity: Double(max(0.0001, peakRMS))))
        }

        mutating func finish(at end: Double, automatic: Bool, voices: [VocalHint], envelope: EnergyEnvelope) throws -> [Phrase] {
            close(at: end)
            var articulated: [Event] = []
            for note in notes {
                if let previous = articulated.last, previous.pitch == note.pitch,
                   note.time - previous.end < 0.035, !envelope.hasFreshAttack(at: note.time) {
                    let i = articulated.count - 1
                    articulated[i].duration = note.end - previous.time
                    articulated[i].velocity = max(previous.velocity, note.velocity)
                } else { articulated.append(note) }
            }
            notes = articulated
            envelope.refine(&notes, until: end)
            // The model reports certainty, not playing strength. Scale the measured
            // envelope against this take, retaining accents and soft attacks.
            let levels = notes.map(\.velocity).sorted()
            let reference = levels.isEmpty ? 1 : levels[Int(Double(levels.count - 1) * 0.90)]
            for i in notes.indices {
                notes[i].velocity = min(1, max(0.13, 0.88 * pow(notes[i].velocity / reference, 0.62)))
            }
            var groups: [[Event]] = []
            for note in notes {
                if let group = groups.last, let first = group.first, let last = group.last,
                   note.time - last.end < 1.1,
                   !(note.time - first.time >= 12 && note.time - last.end >= 0.32),
                   note.time - first.time < 48 {
                    groups[groups.count - 1].append(note)
                } else { groups.append([note]) }
            }
            func coverage(_ hints: [VocalHint], from: Double, to: Double) -> Double {
                hints.reduce(0.0) { $0 + max(0, min(to, $1.end) - max(from, $1.start)) } / max(0.01, to - from)
            }
            var candidates: [(Phrase, Double)] = []
            var cursor = 0
            for var group in groups where group.count >= 3 && Set(group.map(\.pitch)).count >= 2 {
                let start = group[0].time
                while cursor < evidence.count && evidence[cursor].time < start { cursor += 1 }
                var observations: [(frames: Int, clear: Int, audible: Int)] = []
                for k in group.indices {
                    let note = group[k]
                    var curve: [Float] = []
                    while cursor < evidence.count && evidence[cursor].time < note.time { cursor += 1 }
                    var count = 0, clear = 0, audible = 0
                    while cursor < evidence.count && evidence[cursor].time < note.end {
                        let frame = evidence[cursor]
                        count += 1
                        if frame.pitch == note.pitch && frame.time >= note.time + 0.055 && frame.time < note.end - 0.035 {
                            curve.append(frame.detune)
                        }
                        if frame.clear { clear += 1 }
                        if frame.audible { audible += 1 }
                        cursor += 1
                    }
                    if curve.count >= Int((note.duration - 0.09) * 76), RecordedMelody.hasVibrato(curve) {
                        group[k].technique = .vibrato
                    }
                    observations.append((count, clear, audible))
                }
                func evidenceFor(_ range: Range<Int>) -> (likely: Bool, score: Double) {
                    let slice = observations[range]
                    let frames = Double(max(1, slice.reduce(0) { $0 + $1.frames }))
                    let clarity = Double(slice.reduce(0) { $0 + $1.clear }) / frames
                    let presence = Double(slice.reduce(0) { $0 + $1.audible }) / frames
                    let pitches = group[range].map(\.pitch)
                    let moving = zip(pitches, pitches.dropFirst()).filter { (1...5).contains(abs($0 - $1)) }.count
                    let motion = Double(moving) / Double(max(1, range.count - 1))
                    let span = group[range.upperBound - 1].end - group[range.lowerBound].time
                    let likely = span >= 1.2 && range.count >= 4 && clarity >= 0.50 && presence >= 0.32 && motion >= 0.17
                    return (likely, clarity * 0.45 + presence * 0.34 + motion * 0.21)
                }
                // Search inside a long run: a guitar can move from comping to lead without a rest.
                var covered = Array(repeating: !automatic, count: group.count)
                if automatic {
                    let width = min(8, group.count)
                    for i in 0...(group.count - width) {
                        let window = i..<(i + width)
                        if evidenceFor(window).likely {
                            for j in window { covered[j] = true }
                        }
                    }
                }
                var i = 0
                while i < group.count {
                    var j = i + 1
                    while j < group.count && covered[j] == covered[i] { j += 1 }
                    let range = i..<j
                    defer { i = j }
                    guard range.count >= 3 else { continue }
                    let uncertain = automatic && !covered[i]
                    let vocal = min(1, coverage(voices, from: group[i].time, to: group[j - 1].end))
                    let rank = evidenceFor(range).score - vocal * 0.07 + (uncertain ? 0 : 1)
                    let events = try Music.fingering(Array(group[range]), semitones: 0, position: 5, level: .advanced)
                    let name = automatic ? (uncertain ? "Frase incerta" : "Possível solo") : "Guitarra"
                    var phrase = Phrase(name: name, explanation: "Linha melódica estimada da gravação.", events: events, level: .advanced)
                    if uncertain { phrase.uncertainStudyLine = true }
                    candidates.append((phrase, rank))
                }
            }
            return candidates.sorted { $0.1 > $1.1 }.map { $0.0 }
        }
    }
}
