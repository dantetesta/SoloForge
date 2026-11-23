import AVFoundation
import Foundation
import MusicCore

struct LeadRender {
    let url: URL
    let offset: Int64

    static func tail(_ project: Project) -> Double {
        project.ampPreset == .space ? 1.28 : min(0.92, 0.40 + project.tone.delay * 0.9)
    }

    static func create(events: [Event], project: Project, to url: URL) throws -> LeadRender {
        guard let first = events.first, let last = events.last else { throw WorkError.selectPhrase }
        let offset = Int64((first.time * AudioFiles.rate).rounded())
        let frames = Int((min(project.map.duration, last.end + tail(project)) * AudioFiles.rate).rounded()) - Int(offset)
        let file = try AudioFiles.writable(url)
        let block = AVAudioPCMBuffer(pcmFormat: AudioFiles.format, frameCapacity: 4_096)!
        let left = block.floatChannelData![0], right = block.floatChannelData![1]
        var instrument = try RecordedGuitar(project.preferences.instrument)
        var amplifier = GuitarAmplifier(instrument: project.preferences.instrument, preset: project.ampPreset, tone: project.tone, bpm: project.map.bpm)
        let framesAt = events.map { Int64(($0.time * AudioFiles.rate).rounded()) }
        var index = 0
        var cursor = 0
        var voice: GuitarVoice?
        var old: GuitarVoice?
        while cursor < frames {
            try Task.checkCancellation()
            let size = min(Int(block.frameCapacity), frames - cursor)
            block.frameLength = AVAudioFrameCount(size)
            for i in 0..<size {
                let absolute = Int64(cursor + i) + offset
                let time = Double(absolute) / AudioFiles.rate
                if index < events.count, absolute >= framesAt[index] {
                    old = voice
                    old?.damp(at: time)
                    voice = try instrument.note(events[index], ordinal: index, tone: project.tone)
                    index += 1
                }
                let dry = (voice?.sample(at: time) ?? 0) + (old?.sample(at: time) ?? 0)
                let stereo = amplifier.process(dry)
                left[i] = stereo.0
                right[i] = stereo.1
            }
            try file.write(from: block)
            cursor += size
        }
        return LeadRender(url: url, offset: offset)
    }
}

struct MixLevels {
    var music: Double
    var lead: Double
    init(project: Project, muteMusic: Bool = false, muteLead: Bool = false) {
        music = (muteMusic || (project.transpose != 0 && !project.transposeRecording)) ? 0 : project.musicVolume
        lead = muteLead ? 0 : project.leadVolume
    }
}

struct FramePlan {
    let songStart: Int64
    let songEnd: Int64
    let leadStart: Int64
    let leadCount: Int64
    let leadDelay: Int64
    init(start: Int64, end: Int64, leadOffset: Int64, leadLength: Int64) {
        songStart = start; songEnd = end
        let intersection = max(start, leadOffset)
        leadStart = max(0, intersection - leadOffset)
        leadCount = max(0, min(end, leadOffset + leadLength) - intersection)
        leadDelay = max(0, intersection - start)
    }
}

@MainActor
final class Transport {
    private let engine = AVAudioEngine()
    private let backing = AVAudioPlayerNode()
    private let solo = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let leadCompensation = AVAudioUnitTimePitch()
    private let speed = AVAudioUnitTimePitch()
    private let mixer = AVAudioMixerNode()
    private var recording: AVAudioFile?
    private var lead: AVAudioFile?
    private var leadOffset: Int64 = 0
    private var origin = 0.0
    private var stop = 0.0
    private var scheduleTime: AVAudioTime?
    private var fallbackStart: TimeInterval = 0
    private(set) var playing = false
    private(set) var position = 0.0
    var duration: Double { Double(recording?.length ?? 0) / AudioFiles.rate }

    init() {
        [backing, solo, pitch, leadCompensation, speed, mixer].forEach(engine.attach)
        let format = AudioFiles.format
        engine.connect(backing, to: pitch, format: format)
        engine.connect(pitch, to: mixer, format: format)
        engine.connect(solo, to: leadCompensation, format: format)
        engine.connect(leadCompensation, to: mixer, format: format)
        engine.connect(mixer, to: speed, format: format)
        engine.connect(speed, to: engine.mainMixerNode, format: format)
        pitch.bypass = true
        leadCompensation.bypass = true
        speed.bypass = true
    }

    func load(recording url: URL) throws {
        pause()
        recording = try AVAudioFile(forReading: url)
        lead = nil; leadOffset = 0; position = 0
    }

    func load(lead render: LeadRender?) throws {
        pause()
        lead = try render.map { try AVAudioFile(forReading: $0.url) }
        leadOffset = render?.offset ?? 0
    }

    func configure(levels: MixLevels, rate: Double, semitones: Int) {
        backing.volume = Float(levels.music * 0.85)
        solo.volume = Float(levels.lead * 0.80)
        speed.rate = Float(rate)
        speed.bypass = abs(rate - 1) < 0.001
        pitch.pitch = Float(semitones * 100)
        pitch.bypass = semitones == 0
        leadCompensation.bypass = semitones == 0
    }

    func play(from time: Double, until end: Double) throws {
        guard let recording else { throw WorkError.files }
        pause()
        let startFrame = min(recording.length, max(0, Int64((time * AudioFiles.rate).rounded())))
        let endFrame = min(recording.length, Int64((end * AudioFiles.rate).rounded()))
        guard endFrame > startFrame else { return }
        if !engine.isRunning { try engine.start() }
        let plan = FramePlan(start: startFrame, end: endFrame, leadOffset: leadOffset, leadLength: lead?.length ?? 0)
        let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.075))
        scheduleTime = startTime
        backing.scheduleSegment(recording, startingFrame: startFrame, frameCount: AVAudioFrameCount(endFrame - startFrame), at: AVAudioTime(sampleTime: 0, atRate: AudioFiles.rate))
        if let lead, plan.leadCount > 0 {
            solo.scheduleSegment(lead, startingFrame: plan.leadStart, frameCount: AVAudioFrameCount(plan.leadCount), at: AVAudioTime(sampleTime: plan.leadDelay, atRate: AudioFiles.rate))
        }
        backing.play(at: startTime)
        solo.play(at: startTime)
        origin = Double(startFrame) / AudioFiles.rate
        position = origin
        stop = Double(endFrame) / AudioFiles.rate
        fallbackStart = ProcessInfo.processInfo.systemUptime + 0.075
        playing = true
    }

    func update() -> Bool {
        guard playing else { return false }
        if let scheduleTime, mach_absolute_time() < scheduleTime.hostTime { return false }
        let elapsed: Double
        if let renderTime = backing.lastRenderTime, let player = backing.playerTime(forNodeTime: renderTime), player.isSampleTimeValid {
            let latency = (speed.bypass ? 0 : speed.auAudioUnit.latency) + (pitch.bypass ? 0 : pitch.auAudioUnit.latency) + engine.outputNode.presentationLatency
            elapsed = max(0, Double(player.sampleTime) / player.sampleRate - latency * Double(speed.rate))
        } else {
            elapsed = max(0, ProcessInfo.processInfo.systemUptime - fallbackStart) * Double(speed.rate)
        }
        position = min(stop, origin + elapsed)
        if position >= stop - 0.002 {
            backing.stop(); solo.stop()
            position = stop; playing = false
            return true
        }
        return false
    }

    func seek(_ time: Double) {
        pause()
        position = max(0, min(time, duration))
    }

    func pause() {
        if playing { _ = update() }
        backing.stop(); solo.stop(); playing = false
    }
}

enum AudioExport {
    static func render(project: Project, recording: URL, lead: LeadRender, range: ClosedRange<Double>,
                       levels: MixLevels, to destination: URL, progress: (Double) -> Void) throws {
        let file = try AVAudioFile(forReading: recording)
        let leadFile = try AVAudioFile(forReading: lead.url)
        let start = Int64((range.lowerBound * AudioFiles.rate).rounded())
        let end = min(file.length, Int64((range.upperBound * AudioFiles.rate).rounded()))
        guard end > start else { throw MusicError.invalidRange }
        let plan = FramePlan(start: start, end: end, leadOffset: lead.offset, leadLength: leadFile.length)
        let word = AVAudioPCMBuffer(pcmFormat: AudioFiles.format, frameCapacity: 8_192)!
        let notes = AVAudioPCMBuffer(pcmFormat: AudioFiles.format, frameCapacity: 8_192)!
        let output = try AudioFiles.writable(destination)
        let transposition = levels.music > 0 && project.transposeRecording ? project.transpose : 0
        let shiftedURL = FileManager.default.temporaryDirectory.appendingPathComponent("pitch-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: shiftedURL) }
        var shifted: AVAudioFile?
        var transposer: OfflinePitch?
        if transposition != 0 {
            if let ffmpeg = AudioFiles.ffmpeg {
                try shiftRecording(ffmpeg, recording: recording, start: start, end: end, amount: transposition, to: shiftedURL)
                shifted = try AVAudioFile(forReading: shiftedURL)
            } else {
                transposer = try OfflinePitch(file: file, start: start, end: end, semitones: transposition)
            }
        }
        file.framePosition = start
        leadFile.framePosition = plan.leadStart
        var cursor: Int64 = 0
        while start + cursor < end {
            try Task.checkCancellation()
            let size = AVAudioFrameCount(min(8_192, end - start - cursor))
            if levels.music > 0 {
                if let transposer { try transposer.read(size, into: word) }
                else { try (shifted ?? file).read(into: word, frameCount: size) }
            }
            let from = max(cursor, plan.leadDelay)
            let through = min(cursor + Int64(size), plan.leadDelay + plan.leadCount)
            let leadCount = max(0, through - from)
            if leadCount > 0 { try leadFile.read(into: notes, frameCount: AVAudioFrameCount(leadCount)) }
            let backingCount = levels.music > 0 ? Int(word.frameLength) : 0
            word.frameLength = size
            for channel in 0..<2 {
                let a = word.floatChannelData![channel], b = notes.floatChannelData![channel]
                for i in 0..<Int(size) {
                    let j = Int64(i) + cursor - from
                    let musicSample = i < backingCount ? a[i] * Float(levels.music * 0.85) : 0
                    let leadSample = j >= 0 && j < leadCount ? b[Int(j)] * Float(levels.lead * 0.80) : 0
                    a[i] = min(0.99, max(-0.99, musicSample + leadSample))
                }
            }
            try output.write(from: word)
            cursor += Int64(size)
            progress(Double(cursor) / Double(end - start))
        }
    }

    private static func shiftRecording(_ ffmpeg: String, recording: URL, start: Int64, end: Int64, amount: Int, to output: URL) throws {
        let ratio = pow(2, Double(amount) / 12)
        let rate = Int((AudioFiles.rate * ratio).rounded())
        let length = end - start
        let filter = "atrim=start_sample=\(start):end_sample=\(end),asetpts=PTS-STARTPTS,asetrate=\(rate),aresample=44100,atempo=\(1 / ratio),apad=whole_len=\(length),atrim=end_sample=\(length)"
        let job = try MediaProcess.start(ffmpeg, ["-i", recording.path, "-af", filter, "-c:a", "pcm_s16le", output.path])
        try MediaProcess.finish(job, message: "A gravação não pôde ser transposta pelo FFmpeg local.")
    }
}

private final class OfflinePitch {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    init(file: AVAudioFile, start: Int64, end: Int64, semitones: Int) throws {
        let unit = AVAudioUnitTimePitch()
        unit.pitch = Float(semitones * 100)
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: AudioFiles.format)
        engine.connect(unit, to: engine.mainMixerNode, format: AudioFiles.format)
        try engine.enableManualRenderingMode(.offline, format: AudioFiles.format, maximumFrameCount: 8_192)
        try engine.start()
        player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(end - start), at: nil)
        player.play()
        let latency = AVAudioFrameCount((unit.auAudioUnit.latency * AudioFiles.rate).rounded())
        if latency > 0 {
            let scratch = AVAudioPCMBuffer(pcmFormat: AudioFiles.format, frameCapacity: 8_192)!
            var remaining = latency
            while remaining > 0 {
                let count = min(remaining, 8_192)
                try read(count, into: scratch)
                remaining -= count
            }
        }
    }
    func read(_ frames: AVAudioFrameCount, into buffer: AVAudioPCMBuffer) throws {
        for _ in 0..<8 {
            switch try engine.renderOffline(frames, to: buffer) {
            case .success: return
            case .cannotDoInCurrentContext: continue
            default: throw WorkError.audio("Falha ao transpor o áudio durante a exportação.")
            }
        }
        throw WorkError.audio("O motor de transposição não conseguiu entregar as amostras.")
    }
    deinit { player.stop(); engine.stop() }
}
