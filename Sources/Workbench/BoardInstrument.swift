import AVFoundation
import MusicCore

// The mouse updates control values once per gesture event. The audio thread
// consumes them once per buffer and glides to the requested pitch sample by sample.
struct BoardVoice {
    var string: GuitarVoice
    var amp: GuitarAmplifier
    var age = 0.0
    var releaseAt: Double?
    var releaseTime = 0.14
    var ratio = 1.0
    var finished: Bool { releaseAt.map { age >= $0 + releaseTime } ?? false }

    mutating func next(target: Double) -> (Float, Float) {
        let release = releaseAt.map { max(0, min(1, 1 - (age - $0) / releaseTime)) } ?? 1
        ratio += (target - ratio) * 0.005
        let output = amp.process(string.sample(at: age, bendRatio: ratio))
        age += 1 / AudioFiles.rate
        let gain = Float(release * release)
        return (output.0 * gain, output.1 * gain)
    }
}

private final class BoardRenderer {
    private let lock = NSLock()
    private var pending: BoardVoice?
    private var requestedRatio = 1.0
    private var released = false
    private var target = 1.0
    private var voice: BoardVoice?
    private var previous: BoardVoice?

    func press(_ note: BoardVoice) {
        lock.lock()
        pending = note
        released = false
        requestedRatio = 1
        lock.unlock()
    }

    func bend(_ semitones: Double) {
        lock.lock()
        requestedRatio = pow(2, min(2, max(0, semitones)) / 12)
        lock.unlock()
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func render(_ frames: Int, _ output: UnsafeMutableAudioBufferListPointer) {
        if lock.try() {
            if let pending {
                if var ringing = voice {
                    if ringing.releaseAt == nil { ringing.releaseAt = ringing.age; ringing.releaseTime = 0.012 }
                    previous = ringing
                }
                voice = pending
                self.pending = nil
            }
            target = requestedRatio
            if released, let age = voice?.age, voice?.releaseAt == nil {
                voice?.releaseAt = max(0.12, age)
            }
            lock.unlock()
        }
        guard output.count == 2, let left = output[0].mData?.assumingMemoryBound(to: Float.self),
              let right = output[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        guard voice != nil || previous != nil else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }
        let tailRatio = previous?.ratio ?? 1
        for i in 0..<frames {
            let note = voice?.next(target: target) ?? (0, 0)
            let tail = previous?.next(target: tailRatio) ?? (0, 0)
            left[i] = note.0 + tail.0
            right[i] = note.1 + tail.1
            if voice?.finished == true { voice = nil }
            if previous?.finished == true { previous = nil }
        }
    }
}

@MainActor
final class BoardInstrument: ObservableObject {
    private let engine = AVAudioEngine()
    private let renderer = BoardRenderer()
    private var source: AVAudioSourceNode?
    private var guitar: RecordedGuitar?
    private var instrument: Instrument?
    private var ordinal = 0

    func press(string: Int, fret: Int, velocity: Double, project: Project, harmonic: Bool = false) throws {
        let family = project.preferences.instrument
        if instrument != family {
            guitar = try RecordedGuitar(family)
            instrument = family
        }
        var event = Event(time: 0, duration: 600, string: string, fret: fret, velocity: velocity,
                          technique: harmonic ? .harmonic : .picked)
        event.capo = project.capoFret
        guard let voice = try guitar?.note(event, ordinal: ordinal, tone: project.tone, heldByPlayer: true) else { return }
        ordinal += 1
        if source == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: AudioFiles.rate, channels: 2)!
            let node = AVAudioSourceNode(format: format) { [renderer] _, _, frames, list in
                renderer.render(Int(frames), UnsafeMutableAudioBufferListPointer(list))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node
        }
        // The fretboard is a monitoring instrument, independent of the recorded solo stem.
        engine.mainMixerNode.outputVolume = 0.78
        if !engine.isRunning { try engine.start() }
        renderer.press(BoardVoice(string: voice, amp: GuitarAmplifier(instrument: family, preset: project.ampPreset,
                                                                      tone: project.tone, bpm: project.map.bpm)))
    }

    func bend(_ semitones: Double) { renderer.bend(semitones) }
    func release() { renderer.release() }
    func close() {
        renderer.release()
        engine.stop()
    }
}
