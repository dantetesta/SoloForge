import AVFoundation
import Foundation
import MusicCore

struct RecordedGuitar {
    private struct Region {
        var file: URL
        var pitch: Int
        var string: Int?
        var layer: String
        var take: Int
    }
    private let regions: [Region]
    private let instrument: Instrument
    private var cache: [(URL, Wave)] = []

    init(_ instrument: Instrument) throws {
        self.instrument = instrument
        let acoustic = instrument == .acoustic
        let family = acoustic ? "Acoustic" : "Electric"
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Instruments/\(family)"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            throw WorkError.audio("A biblioteca de amostras de guitarra está ausente. Abra o aplicativo empacotado.")
        }
        regions = files.filter { $0.pathExtension == "wav" }.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard name.count == 3, let first = Int(name[0]), let number = Int(name[2]) else { return nil }
            if acoustic {
                guard let pitch = Int(name[1]), tuning.indices.contains(first) else { return nil }
                return Region(file: url, pitch: pitch, string: first, layer: number == 1 ? "mp" : "mf", take: 1)
            }
            return Region(file: url, pitch: first, string: nil, layer: String(name[1]), take: number)
        }
        guard !regions.isEmpty else { throw WorkError.audio("A biblioteca de instrumentos está vazia.") }
    }

    mutating func note(_ event: Event, ordinal: Int, tone: Tone, heldByPlayer: Bool = false) throws -> GuitarVoice {
        let acoustic = instrument == .acoustic
        let layer = event.velocity < (acoustic ? 0.68 : 0.71) || event.technique == .hammer ? "mp" : "mf"
        let take = (ordinal + event.fret).isMultiple(of: 2) ? 2 : 1
        func distance(_ region: Region) -> Int {
            let interval = abs(region.pitch - event.pitch) * 10
            let stringGap = region.string.map { abs($0 - event.string) * 21 } ?? 0
            return interval + stringGap + (region.layer == layer ? 0 : 8) + (region.take == take ? 0 : 1)
        }
        guard let region = regions.min(by: {
            let a = distance($0), b = distance($1)
            return a == b ? $0.file.lastPathComponent < $1.file.lastPathComponent : a < b
        }) else { throw WorkError.audio("Não foi possível encontrar uma amostra para o solo.") }
        let data = try sample(region.file, pitch: region.pitch)
        return GuitarVoice(event: event, sample: data, semitones: event.pitch - region.pitch, sustain: tone.sustain,
                           acoustic: acoustic, softer: region.layer == "mp", upstroke: !ordinal.isMultiple(of: 2), heldByPlayer: heldByPlayer)
    }

    private mutating func sample(_ url: URL, pitch: Int) throws -> Wave {
        if let match = cache.firstIndex(where: { $0.0 == url }) {
            let data = cache.remove(at: match); cache.append(data)
            return data.1
        }
        let audio = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(min(audio.length, 264_600))
        guard frames > 1, let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames) else {
            throw WorkError.audio("Uma amostra de guitarra está vazia.")
        }
        try audio.read(into: buffer, frameCount: frames)
        guard let channel = buffer.floatChannelData?.pointee, buffer.frameLength > 1 else {
            throw WorkError.audio("Uma amostra de guitarra está ilegível.")
        }
        let values = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let peak = values.prefix(13_230).reduce(Float(0)) { max($0, abs($1)) }
        let rate = audio.processingFormat.sampleRate
        let loop = SustainLoop(values: values, rate: rate, pitch: pitch)
        let wave = Wave(values: values, rate: rate, gain: min(12, 0.65 / max(0.02, peak)), loop: loop)
        cache.append((url, wave))
        if cache.count > 12 { cache.removeFirst() }
        return wave
    }
}

struct Wave {
    let values: [Float]
    let rate: Double
    let gain: Float
    var loop: SustainLoop?

    func read(_ cursor: Double) -> Float {
        let i = Int(cursor)
        guard i >= 0, i + 1 < values.count else { return 0 }
        return values[i] + (values[i + 1] - values[i]) * Float(cursor - Double(i))
    }
}

// Match two periods of the recorded string before crossfading back into its sustain.
struct SustainLoop {
    let start: Int
    let end: Int
    let blend: Int

    init?(values: [Float], rate: Double, pitch: Int) {
        let period = rate / (440 * pow(2, Double(pitch - 69) / 12))
        blend = max(8, Int((period * 2).rounded()))
        start = min(Int(rate * 0.17), values.count / 4)
        let target = start + Int((max(4, (rate * 0.18 / period).rounded()) * period).rounded())
        let search = max(1, Int(period / 2))
        guard target + search + blend + 2 < values.count else { return nil }
        var best = target
        var minimum = Float.infinity
        for candidate in (target - search)...(target + search) {
            var error: Float = 0
            for offset in stride(from: 0, to: blend, by: max(1, blend / 64)) {
                let diff = values[start + offset] - values[candidate + offset]
                error += diff * diff
            }
            if error < minimum { minimum = error; best = candidate }
        }
        end = best + blend
    }
}

struct GuitarVoice {
    let event: Event
    private let wave: Wave
    private let increment: Double
    private let sustain: Float
    private let loopMix: Float
    private let volume: Float
    private let hammer: Bool
    private var cursor: Double
    private var loopCursor: Double = 0
    private let pickFilter: Float
    private var smoothing: Float = 0
    private var phasePlayback: Double = 1
    private let harmonicStep: Double
    private var harmonicPhase = 0.0
    private var frame = 0
    private var dampAt: Double?

    init(event: Event, sample: Wave, semitones: Int, sustain: Double, acoustic: Bool, softer: Bool, upstroke: Bool = false, heldByPlayer: Bool = false) {
        self.event = event
        self.harmonicStep = event.technique == .harmonic ? 2 * .pi * 440 * pow(2, Double(event.pitch - 69) / 12) / AudioFiles.rate : 0
        self.wave = sample
        self.increment = sample.rate / AudioFiles.rate * pow(2, Double(semitones) / 12)
        self.sustain = Float(sustain)
        let pedal = acoustic ? 0 : Float(sustain * sustain)
        self.loopMix = heldByPlayer ? max(0.45, pedal) : pedal
        self.hammer = event.technique == .hammer
        self.volume = Float(pow(event.velocity, 0.70)) * (softer ? 0.84 : 1) * (acoustic ? 1.0 : 0.91)
        self.pickFilter = event.technique == .hammer ? 0.40 : (upstroke ? 0.59 : 0.68) + Float(event.velocity) * 0.17
        self.cursor = event.technique == .hammer ? min(sample.rate * 0.014, Double(sample.values.count - 2)) : 0
        self.loopCursor = self.cursor
    }

    mutating func damp(at time: Double) { dampAt = time }

    mutating func sample(at time: Double, bendRatio: Double = 1) -> Float {
        let age = max(0, time - event.time)
        let tail = max(0, time - event.end)
        let stringRelease = 0.025 + Double(sustain) * 0.065
        guard tail < stringRelease else { return 0 }
        if frame.isMultiple(of: 12) {
            let contour = event.pitchOffset(at: age / event.duration)
            let pickBend = hammer ? 0 : 0.027 * exp(-age * 55) * event.velocity
            phasePlayback = pow(2, (contour + pickBend) / 12)
        }
        frame += 1
        let advance = increment * phasePlayback * bendRatio
        let dry = wave.read(cursor)
        let fade = max(0, min(1, (Double(wave.values.count - 1) - cursor) / (wave.rate * 0.055)))
        var value = dry * Float(fade)
        if let loop = wave.loop, loopMix > 0 {
            if loopCursor >= Double(loop.end) {
                loopCursor = Double(loop.start + loop.blend) + (loopCursor - Double(loop.end))
            }
            var held = wave.read(loopCursor)
            let overlap = loopCursor - Double(loop.end - loop.blend)
            if overlap >= 0 {
                let mix = Float(overlap / Double(loop.blend))
                held += (wave.read(Double(loop.start) + overlap) - held) * mix
            }
            value += (held - value) * loopMix
            loopCursor += advance
        }
        cursor += advance
        smoothing += pickFilter * (value - smoothing)
        let excitation = max(0, min(1, age / (hammer ? 0.003 : 0.0007)))
        let release = max(0, 1 - tail / stringRelease)
        let damp = dampAt.map { max(0, 1 - (time - $0) / (hammer ? 0.020 : 0.010)) } ?? 1
        let dynamic = expf(-Float(age) * max(0, 0.62 - sustain * 0.86))
        var string = smoothing * wave.gain
        if harmonicStep > 0 {
            // At a node only multiples of the ringing partial survive. Retain a little pick noise.
            harmonicPhase += harmonicStep * bendRatio
            if harmonicPhase > 2 * .pi { harmonicPhase -= 2 * .pi }
            let ring = sin(harmonicPhase) + 0.24 * exp(-age * 2) * sin(2 * harmonicPhase)
                        + 0.09 * exp(-age * 5) * sin(3 * harmonicPhase)
            string = string * Float(0.28 * exp(-age * 22)) + Float(0.34 * ring * exp(-age * 0.72))
        }
        return string * volume * Float(excitation * release * release * damp) * dynamic
    }
}

struct GuitarAmplifier {
    private let acoustic: Bool
    private let preGain: Float
    private let powerGain: Float
    private let outputGain: Float
    private let bias: Float
    private let midDrive: Float
    private var inputBass: Float = 0
    private var preFilter: Float = 0
    private var gridBias: Float = 0
    private var supply: Float = 0
    private var previous: Float = 0
    private var postFilter: Float = 0
    private var speaker: CabinetFilter
    private var space: GuitarSpace

    init(instrument: Instrument, preset: AmpPreset?, tone: Tone, bpm: Double) {
        acoustic = instrument == .acoustic
        let driven = instrument == .driven
        let gain = Float(tone.drive)
        let tight = preset == .lead || (preset == nil && driven)
        preGain = acoustic ? 1.05 : tight ? 2.40 + gain * 6.5 : driven ? 1.65 + gain * 5.2 : 1.04 + gain * 3.25
        powerGain = tight ? 1.94 : driven ? 1.38 : 1.05
        outputGain = acoustic ? 0.89 : tight ? 0.52 : driven ? 0.58 : 0.85
        bias = acoustic ? 0 : tight ? 0.15 : 0.074
        midDrive = tight ? 0.33 : driven ? 0.23 : 0.12
        speaker = CabinetFilter(acoustic: acoustic, dark: tight)
        space = GuitarSpace(settings: GuitarSpaceProfile(preset: preset, room: Float(tone.room), delay: Float(tone.delay), bpm: bpm))
    }

    mutating func process(_ input: Float) -> (Float, Float) {
        inputBass += 0.011 * (input - inputBass)
        let highPassed = input - inputBass * (acoustic ? 0.78 : 0.97)
        preFilter += 0.105 * (highPassed - preFilter)
        gridBias += 0.0032 * (abs(highPassed) - gridBias)
        supply += (abs(preFilter) > supply ? 0.0017 : 0.00022) * (abs(preFilter) - supply)
        let shaped = highPassed * 0.73 + preFilter * (0.27 + midDrive)
        let gain = preGain / (1 + gridBias * 2.1 + supply * 2.4)
        let b = bias - min(0.09, gridBias * 0.31)
        var power: Float = 0
        for phase in 1...4 {
            let x = previous + (shaped - previous) * Float(phase) * 0.25
            let pre = clip(gain * x + b) - clip(b)
            let driven = clip(pre * powerGain - b * 0.37) - clip(-b * 0.37)
            postFilter += (acoustic ? 0.54 : 0.37) * (driven - postFilter)
            power += postFilter * 0.25
        }
        previous = shaped
        let source = acoustic ? highPassed * 0.83 + power * 0.17 : power
        let dry = speaker.process(source) * outputGain
        return space.process(dry)
    }

    private func clip(_ sample: Float) -> Float {
        let x = max(-3, min(3, sample))
        let squared = x * x
        return x * (27 + squared) / (27 + 9 * squared)
    }
}

private struct CabinetFilter {
    private var lows: Float = 0
    private var resonance: Float = 0
    private var lowMid: Float = 0
    private var high: Float = 0
    private var history = Array(repeating: Float(0), count: 43)
    private var head = 0
    let acoustic: Bool
    let dark: Bool
    init(acoustic: Bool, dark: Bool) { self.acoustic = acoustic; self.dark = dark }

    mutating func process(_ input: Float) -> Float {
        lows += 0.024 * (input - lows)
        lowMid += 0.071 * (input - lowMid)
        resonance += 0.154 * (input - resonance)
        let speaker = (input - lows * 0.78) + (resonance - lowMid) * (dark ? 0.72 : 0.35)
        high += (acoustic ? 0.73 : dark ? 0.33 : 0.51) * (speaker - high)
        let tap1 = history[(head + history.count - 11) % history.count]
        let tap2 = history[(head + history.count - 23) % history.count]
        let tap3 = history[(head + history.count - 37) % history.count]
        history[head] = high
        head = (head + 1) % history.count
        return acoustic ? high - tap1 * 0.035 : high * 0.93 - tap1 * 0.14 + tap2 * 0.09 - tap3 * 0.043
    }
}

private struct GuitarSpaceProfile {
    let space: Bool
    let delay: Float
    let room: Float
    let echo: Int
    init(preset: AmpPreset?, room: Float, delay: Float, bpm: Double) {
        space = preset == .space
        self.delay = delay
        self.room = room
        let subdivision = space ? 0.75 : 0.5
        echo = min(40_000, max(4_300, Int(60 / bpm * subdivision * AudioFiles.rate)))
    }
}

private struct GuitarSpace {
    let settings: GuitarSpaceProfile
    private var leftMemory = Array(repeating: Float(0), count: 46_500)
    private var rightMemory = Array(repeating: Float(0), count: 46_500)
    private var writeIndex = 0
    private var flutter: Float = 0
    private var cycles: Float = 0
    private var echoWarmL: Float = 0
    private var echoWarmR: Float = 0

    init(settings: GuitarSpaceProfile) { self.settings = settings }

    mutating func process(_ signal: Float) -> (Float, Float) {
        let count = leftMemory.count
        let i = writeIndex
        func tap(_ distance: Int) -> Int { (i + count - distance) % count }
        if settings.space && i.isMultiple(of: 32) {
            cycles += 0.0043
            if cycles >= 2 * .pi { cycles -= 2 * .pi }
            flutter = sinf(cycles) * 37
        }
        let echoL = leftMemory[tap(settings.echo)]
        let echoR = rightMemory[tap(settings.echo + 911)]
        echoWarmL += 0.28 * (echoL - echoWarmL)
        echoWarmR += 0.26 * (echoR - echoWarmR)
        let spreadL = settings.space ? leftMemory[tap(861 + Int(flutter))] * 0.13 : 0
        let spreadR = settings.space ? rightMemory[tap(1_136 - Int(flutter))] * 0.13 : 0
        let diffuseL = leftMemory[tap(1_531)] * 0.26 - rightMemory[tap(2_813)] * 0.19 + leftMemory[tap(5_297)] * 0.19 + rightMemory[tap(7_531)] * 0.12
        let diffuseR = rightMemory[tap(1_931)] * 0.26 + leftMemory[tap(3_479)] * 0.19 - rightMemory[tap(4_923)] * 0.19 + leftMemory[tap(8_387)] * 0.12
        let l = signal + echoWarmR * settings.delay * 0.47 + diffuseR * settings.room * 0.29
        let r = signal + echoWarmL * settings.delay * 0.47 + diffuseL * settings.room * 0.29
        leftMemory[i] = l
        rightMemory[i] = r
        writeIndex = (writeIndex + 1) % count
        let volume = settings.space ? 0.90 : 1.0 as Float
        return (cap(signal * volume + echoWarmL * settings.delay * 0.63 + diffuseL * settings.room + spreadL),
                cap(signal * volume + echoWarmR * settings.delay * 0.63 + diffuseR * settings.room + spreadR))
    }

    private func cap(_ x: Float) -> Float { min(0.995, max(-0.995, x)) }
}
