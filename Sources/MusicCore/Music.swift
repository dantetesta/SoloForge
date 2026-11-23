import Foundation

public let pitchNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
public let tuning = [64, 59, 55, 50, 45, 40]
public func pitchClass(_ midi: Int) -> Int { (midi % 12 + 12) % 12 }

public protocol Choice: RawRepresentable, CaseIterable, Codable, Hashable where RawValue == String {}
public enum Level: String, Choice {
    case beginner = "Iniciante", basic = "Básico", intermediate = "Intermediário", advanced = "Avançado"
    public var index: Int { Self.allCases.firstIndex(of: self)! }
}
public enum Mood: String, Choice {
    case subtle = "Discreto", moving = "Emocionante", energetic = "Enérgico"
}
public enum Genre: String, Choice {
    case varied = "Variados", blues = "Blues", rock = "Rock", melodic = "Melódico", soul = "Soul"
}
public enum Placement: String, Choice {
    case intro = "Intro", answer = "Resposta à voz", transition = "Transição", chorus = "Refrão", ending = "Final"
}
public enum Instrument: String, Choice {
    case clean = "Guitarra limpa", driven = "Guitarra saturada", acoustic = "Violão"
}
public enum Technique: String, Choice {
    case picked = "Palhetada", hammer = "Ligado", slide = "Slide", vibrato = "Vibrato", bend = "Bend", harmonic = "Harmônico natural"
}
public struct Key: Codable, Equatable, Sendable {
    public var root: Int
    public var minor: Bool
    public init(root: Int = 0, minor: Bool = false) { self.root = pitchClass(root); self.minor = minor }
    public var label: String { pitchNames[pitchClass(root)] + (minor ? " menor" : " maior") }
    public var scale: [Int] { (minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { pitchClass(root + $0) } }
}
public enum ChordQuality: String, Choice {
    case major = "Maior", minor = "Menor", diminished = "Diminuto", dominant = "7 dominante", minor7 = "Menor 7", major7 = "Maior 7", sus4 = "Sus4"
    public var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .diminished: [0, 3, 6]
        case .dominant: [0, 4, 7, 10]
        case .minor7: [0, 3, 7, 10]
        case .major7: [0, 4, 7, 11]
        case .sus4: [0, 5, 7]
        }
    }
    public var suffix: String {
        switch self {
        case .major: ""; case .minor: "m"; case .diminished: "°"; case .dominant: "7"
        case .minor7: "m7"; case .major7: "maj7"; case .sus4: "sus4"
        }
    }
}
public struct Chord: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var root: Int
    public var quality: ChordQuality
    public var confidence: Double
    public init(start: Double, end: Double, root: Int, minor: Bool, confidence: Double = 0) {
        self.start = start; self.end = end; self.root = pitchClass(root)
        self.quality = minor ? .minor : .major; self.confidence = confidence
    }
    public var tones: [Int] { quality.intervals.map { pitchClass(root + $0) } }
    public var label: String { pitchNames[pitchClass(root)] + quality.suffix }
}
public struct Passage: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var start: Double
    public var end: Double
    public init(_ name: String, _ start: Double, _ end: Double) { self.name = name; self.start = start; self.end = end }
}
public struct AudioMap: Codable, Equatable {
    public var duration: Double
    public var waveform: [Float]
    public var bpm: Double
    public var beatOffset: Double
    public var meter: Int
    public var key: Key
    public var keyConfidence: Double
    public var tempoConfidence: Double
    public var chords: [Chord]
    public var sections: [Passage]
    public var vocalHints: [VocalHint]?
    public var globalChroma: [Double]?
    public var writtenHarmony: WrittenHarmony?
    public init(duration: Double, waveform: [Float] = [], bpm: Double = 100, beatOffset: Double = 0,
                meter: Int = 4, key: Key = Key(), keyConfidence: Double = 0, tempoConfidence: Double = 0,
                chords: [Chord] = [], sections: [Passage] = []) {
        self.duration = duration; self.waveform = waveform; self.bpm = bpm; self.beatOffset = beatOffset
        self.meter = meter; self.key = key; self.keyConfidence = keyConfidence; self.tempoConfidence = tempoConfidence
        self.chords = chords; self.sections = sections
    }

    public func key(at time: Double) -> Key {
        guard let writtenHarmony, writtenHarmony.start <= time, time < writtenHarmony.end else { return key }
        return writtenHarmony.key
    }
}
public struct WrittenHarmony: Codable, Equatable {
    var start: Double
    var end: Double
    var key: Key
}
public struct VocalHint: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var confidence: Double
    public init(start: Double, end: Double, confidence: Double) {
        self.start = start; self.end = end; self.confidence = confidence
    }
}
public struct Tone: Codable, Hashable {
    public var drive: Double
    public var room: Double
    public var delay: Double
    public var sustain: Double
    public static func suggested(_ instrument: Instrument) -> Tone {
        switch instrument {
        case .clean: Tone(drive: 0.10, room: 0.24, delay: 0.12, sustain: 0.58)
        case .driven: Tone(drive: 0.70, room: 0.21, delay: 0.17, sustain: 0.74)
        case .acoustic: Tone(drive: 0, room: 0.16, delay: 0.04, sustain: 0.40)
        }
    }
}
public struct TonePreset: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var instrument: Instrument
    public var tone: Tone
    public init(name: String, instrument: Instrument, tone: Tone) {
        self.name = name; self.instrument = instrument; self.tone = tone
    }
}
public struct Preferences: Codable, Equatable {
    public var level: Level = .basic
    public var mood: Mood = .moving
    public var placement: Placement = .transition
    public var instrument: Instrument = .clean
    public var position: Int = 5
    public var genre: Genre?
    public init() {}
}
public struct Event: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var time: Double
    public var duration: Double
    public var string: Int
    public var fret: Int
    public var velocity: Double
    public var technique: Technique
    public var amount: Int
    public var capo: Int?
    public init(time: Double, duration: Double, string: Int, fret: Int, velocity: Double, technique: Technique = .picked, amount: Int = 0) {
        self.time = time; self.duration = duration; self.string = string; self.fret = fret
        self.velocity = velocity; self.technique = technique; self.amount = amount
    }
    public var end: Double { time + duration }
    public static let harmonicIntervals = [5: 24, 7: 19, 12: 12]
    public var relativeFret: Int { fret - (capo ?? 0) }
    public var pitch: Int {
        let open = tuning.indices.contains(string) ? tuning[string] : -100
        if technique == .harmonic, let offset = Self.harmonicIntervals[relativeFret] {
            return open + (capo ?? 0) + offset
        }
        return open + fret
    }
    public var label: String {
        let f = relativeFret
        switch technique {
        case .harmonic: return "<\(f)>"
        case .picked: return "\(f)"
        case .hammer: return "h\(f)"
        case .slide: return "\(f)/\(f + amount)"
        case .vibrato: return "\(f)~"
        case .bend: return "\(f)b+\(amount)"
        }
    }
    public func pitchOffset(at fraction: Double) -> Double {
        let t = min(1, max(0, fraction))
        switch technique {
        case .bend:
            let rise = min(1, max(0, (t - 0.08) / 0.40))
            return Double(amount) * rise * rise * (3 - 2 * rise)
        case .slide: return Double(amount) * min(1, max(0, (t - 0.1) / 0.35))
        case .vibrato: return 0.28 * min(1, t * 2) * sin(t * duration * 2 * .pi * 5.3)
        case .hammer: return -0.12 * max(0, 1 - t * 16)
        case .picked, .harmonic: return 0
        }
    }
}
public struct Phrase: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var explanation: String
    public var events: [Event]
    public var uncertainStudyLine: Bool?
    public var approved = false
    public var level: Level
    public init(name: String, explanation: String, events: [Event], level: Level) {
        self.name = name; self.explanation = explanation; self.events = events; self.level = level
    }
    public func active(at time: Double) -> Event? { events.first { $0.time <= time && time < $0.end } }
}
public struct Lyric: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var time: Double
    public var text: String
    public var words: [TimedWord]?
    public init(time: Double, text: String, words: [TimedWord]? = nil) {
        self.time = time; self.text = text; self.words = words
    }
}
public struct TimedWord: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}
public struct RecordingStudy: Codable, Equatable {
    public static let currentAnalysisVersion = 4
    public var analysisVersion: Int?
    public var map: AudioMap
    public var passage: Passage
    public var lines: [Phrase]
    public var referenceSheet: String?
    public var usedGuitarTrack: Bool
    public var lyrics: [Lyric]?
    public init(map: AudioMap, passage: Passage, lines: [Phrase], usedGuitarTrack: Bool) {
        self.map = map
        self.passage = passage
        self.lines = lines
        self.analysisVersion = Self.currentAnalysisVersion
        self.usedGuitarTrack = usedGuitarTrack
    }
}

public struct Project: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var sourceHash: String
    public var map: AudioMap
    public var passage: Passage
    public var preferences = Preferences()
    public var tone = Tone.suggested(.clean)
    public var tonePresets: [TonePreset]?
    public var alternatives: [Phrase] = []
    public var selected: UUID?
    public var lyrics: [Lyric] = []
    public var chordSheet = false
    public var recordingStudy: RecordingStudy?
    public var arrangement: SoloArrangement?
    public var activeSection: UUID?
    public var ampPreset: AmpPreset?
    public var capoFret: Int?
    public var capo: Int { capoFret ?? 0 }
    public var capoLabel: String { capo == 0 ? "Sem capo" : "Capo \(capo) · casas relativas" }
    public var shapeTranspose: Int { transpose - capo }
    public var transpose = 0
    public var transposeRecording = false
    public var musicVolume = 0.72
    public var leadVolume = 0.78
    public var loop = false
    public var speed = 1.0
    public init(name: String, sourceHash: String, map: AudioMap) {
        self.name = name; self.sourceHash = sourceHash; self.map = map
        self.passage = Passage("Meu trecho", 0, min(map.duration, 16))
    }
    public var phrase: Phrase? { alternatives.first { $0.id == selected } ?? alternatives.first }
    public var presentedKey: Key {
        let key = map.key(at: phrase?.events.first?.time ?? passage.start)
        return Key(root: key.root + transpose, minor: key.minor)
    }
}
