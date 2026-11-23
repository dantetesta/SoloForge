import Foundation

public enum MusicError: LocalizedError {
    case invalidPhrase, unreachable, invalidRange, invalidProject, invalidArrangement, noCompleteSolo
    public var errorDescription: String? {
        switch self {
        case .noCompleteSolo: "Nenhuma proposta atingiu as \(SongStructure.minimumSoloPositions) posições diferentes e a duração mínima de um solo."
        case .invalidPhrase: "Verifique tempo, duração, corda, casa e técnica. As notas devem caber no trecho sem sobreposição."
        case .unreachable: "A frase não cabe nessa região ou nessa transposição com a digitação escolhida."
        case .invalidRange: "Defina um trecho de pelo menos um segundo dentro da gravação."
        case .invalidProject: "Os dados musicais do projeto estão incompletos ou fora dos limites."
        case .invalidArrangement: "O plano da IA está incompleto ou fora dos limites musicais. Gere outra versão."
        }
    }
}

public enum Music {
    public static func validate(_ events: [Event], in passage: Passage, level: Level) throws {
        guard !events.isEmpty, events.count <= 1_024 else { throw MusicError.invalidPhrase }
        var end = passage.start
        var previous: Event?
        for event in events {
            let allowed = allowedTechniques(level)
            guard event.time.isFinite, event.duration.isFinite, event.velocity.isFinite,
                  event.time >= end - 0.000001, event.end <= passage.end + 0.000001,
                  event.duration >= 0.06, (0.05...1).contains(event.velocity),
                  tuning.indices.contains(event.string), (0...12).contains(event.capo ?? 0), (0...22).contains(event.fret),
                  (0...maxFret(level)).contains(event.relativeFret),
                  allowed.contains(event.technique) else { throw MusicError.invalidPhrase }
            switch event.technique {
            case .harmonic:
                guard event.amount == 0, Event.harmonicIntervals[event.relativeFret] != nil else { throw MusicError.invalidPhrase }
            case .slide:
                guard [-2, -1, 1, 2].contains(event.amount),
                      (0...maxFret(level)).contains(event.relativeFret + event.amount), (0...22).contains(event.fret + event.amount) else { throw MusicError.invalidPhrase }
            case .bend:
                guard (1...2).contains(event.amount), event.relativeFret >= 2 else { throw MusicError.invalidPhrase }
            case .hammer:
                guard event.amount == 0, let previous, canHammer(from: previous, to: event) else { throw MusicError.invalidPhrase }
            default:
                guard event.amount == 0 else { throw MusicError.invalidPhrase }
            }
            end = event.end
            previous = event
        }
    }

    public static func validate(_ project: Project) throws {
        let map = project.map
        guard (1...21_601).contains(map.duration), (35...250).contains(map.bpm), (2...7).contains(map.meter),
              map.beatOffset.isFinite, (0...map.duration).contains(map.beatOffset), (0...11).contains(map.key.root),
              (0...1).contains(map.keyConfidence), (0...1).contains(map.tempoConfidence),
              !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, project.name.count <= 200,
              project.sourceHash.count == 64, project.sourceHash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              (0...12).contains(project.capo), (-12...12).contains(project.transpose), (0...1).contains(project.musicVolume),
              (0...1).contains(project.leadVolume), (0.5...1.25).contains(project.speed),
              (0...17).contains(project.preferences.position), map.waveform.count <= 2_400,
              map.waveform.allSatisfy({ (0...1).contains($0) }),
              validTone(project.tone) else { throw MusicError.invalidProject }
        try validate(project.passage, duration: map.duration)
        if let harmony = map.writtenHarmony {
            guard harmony.start >= 0, harmony.end > harmony.start, harmony.end <= map.duration,
                  (0...11).contains(harmony.key.root) else { throw MusicError.invalidProject }
        }
        guard map.chords.allSatisfy({ (0...11).contains($0.root) && (0...map.duration).contains($0.start) && ($0.start...map.duration).contains($0.end) && $0.end > $0.start && (0...1).contains($0.confidence) }),
              map.sections.allSatisfy({ $0.start >= 0 && $0.end > $0.start && $0.end <= map.duration }),
              project.lyrics.count <= 5_000,
              project.lyrics.allSatisfy({ (0...map.duration).contains($0.time) && $0.text.count <= 600 }),
              project.alternatives.count <= 12,
              project.selected.map({ id in project.alternatives.contains { $0.id == id } }) ?? true else { throw MusicError.invalidProject }
        if let study = project.recordingStudy {
            guard abs(study.map.duration - map.duration) < 0.05,
                  study.map.writtenHarmony == nil, study.lines.count <= 4096,
                  (study.referenceSheet?.utf8.count ?? 0) <= 256_000,
                  Set(study.lines.map(\.id)).count == study.lines.count else { throw MusicError.invalidProject }
            var source = Project(name: project.name, sourceHash: project.sourceHash, map: study.map)
            source.lyrics = study.lyrics ?? []
            try validate(source)
            try validate(study.passage, duration: map.duration)
            for line in study.lines { try validate(line.events, in: study.passage, level: .advanced) }
        }
        if let presets = project.tonePresets {
            guard presets.count <= 20, presets.allSatisfy({ (1...48).contains($0.name.count) && validTone($0.tone) }) else { throw MusicError.invalidProject }
        }
        for phrase in project.alternatives {
            try validate(phrase.events, in: Passage("", 0, map.duration), level: phrase.level)
        }
        if let arrangement = project.arrangement {
            let active = project.showingFeatured ? arrangement.featured : arrangement.sections.first { $0.id == project.activeSection }
            guard arrangement.sections.count <= 16, arrangement.model.count <= 80,
                  Set(arrangement.sections.map(\.id)).count == arrangement.sections.count,
                  let active,
                  active.alternatives == project.alternatives, active.selected == project.selected else { throw MusicError.invalidArrangement }
            var end = 0.0
            for section in arrangement.sections {
                guard abs(section.passage.start - end) < 0.001,
                      section.alternatives.count <= 12,
                      section.selected.map({ id in section.alternatives.contains { $0.id == id } }) ?? true else { throw MusicError.invalidArrangement }
                try validate(section.passage, duration: map.duration)
                for phrase in section.alternatives {
                    try validate(phrase.events, in: section.passage, level: phrase.level)
                }
                end = section.passage.end
            }
            if let featured = arrangement.featured {
                guard !arrangement.sections.contains(where: { $0.id == featured.id }),
                      featured.passage.start == 0, abs(featured.passage.end - map.duration) < 0.001,
                      featured.alternatives.count <= 12,
                      featured.selected.map({ id in featured.alternatives.contains { $0.id == id } }) ?? true else {
                    throw MusicError.invalidArrangement
                }
                for phrase in featured.alternatives { try validate(phrase.events, in: featured.passage, level: phrase.level) }
            }
            guard arrangement.sections.isEmpty ? arrangement.featured != nil : abs(end - map.duration) < 0.001 else {
                throw MusicError.invalidArrangement
            }
        } else if project.activeSection != nil { throw MusicError.invalidArrangement }
        if let phrase = project.phrase, project.transpose != 0 || project.capo != 0 {
            try validate(fingering(phrase.events, semitones: project.transpose, position: project.preferences.position, level: phrase.level, capo: project.capo), in: Passage("", 0, map.duration), level: phrase.level)
        }
    }

    private static func validTone(_ tone: Tone) -> Bool {
        [tone.drive, tone.room, tone.delay, tone.sustain].allSatisfy { (0...1).contains($0) }
    }

    private static func canHammer(from previous: Event, to note: Event) -> Bool {
        previous.string == note.string && (1...4).contains(abs(previous.fret - note.fret)) && note.time - previous.end < 0.13
    }

    public static func validate(_ passage: Passage, duration: Double) throws {
        guard passage.start.isFinite, passage.end.isFinite, passage.start >= 0,
              passage.end <= duration, passage.end - passage.start >= 1 else { throw MusicError.invalidRange }
    }

    public static func allowedTechniques(_ level: Level) -> [Technique] {
        switch level {
        case .beginner: [.picked]
        case .basic: [.picked, .vibrato]
        case .intermediate: [.picked, .vibrato, .hammer, .slide, .bend, .harmonic]
        case .advanced: Technique.allCases.map { $0 }
        }
    }
    public static func maxFret(_ level: Level) -> Int { [8, 13, 18, 22][level.index] }

    public static func fingering(_ events: [Event], semitones: Int, position: Int, level: Level, capo: Int = 0) throws -> [Event] {
        guard (0...12).contains(capo), (-12...12).contains(semitones), (0...17).contains(position) else { throw MusicError.unreachable }
        var previous: Event?
        return try events.map { original in
            let pitch = original.pitch + semitones
            let possibilities = tuning.enumerated().compactMap { string, open -> Event? in
                let fret: Int
                if original.technique == .harmonic {
                    guard let node = Event.harmonicIntervals.first(where: { open + capo + $0.value == pitch }) else { return nil }
                    fret = node.key + capo
                } else {
                    fret = pitch - open
                }
                let limit = min(22, capo + maxFret(level))
                guard (capo...limit).contains(fret),
                      original.technique != .bend || fret >= capo + 2,
                      original.technique != .slide || (capo...limit).contains(fret + original.amount) else { return nil }
                var event = original
                event.string = string
                event.fret = fret
                event.capo = capo == 0 ? nil : capo
                return event
            }
            func cost(_ event: Event) -> Double {
                let shift = previous.map {
                    Double(abs($0.fret - event.fret)) * 0.60 + Double(abs($0.string - event.string)) * 1.2
                } ?? 0
                let positionCost = Double(abs(event.relativeFret - position))
                return positionCost + shift + (event.fret == 0 && position > 3 ? 1.5 : 0)
            }
            guard var best = possibilities.min(by: { cost($0) < cost($1) }) else { throw MusicError.unreachable }
            if best.technique == .hammer {
                if let previous, let sameString = possibilities.first(where: { canHammer(from: previous, to: $0) }) {
                    best = sameString
                } else { best.technique = .picked }
            }
            previous = best
            return best
        }
    }

    public static func chord(at time: Double, in map: AudioMap) -> Chord? {
        let active = map.chords.last { $0.start <= time && time < $0.end }
        return active.flatMap { $0.confidence >= 0.12 ? $0 : nil }
    }

    public static func validateHarmony(_ events: [Event], map: AudioMap) throws {
        for event in events {
            let chord = chord(at: event.time, in: map)
            let allowed = Set(map.key(at: event.time).scale + (chord?.tones ?? []))
            let target = event.pitch + (event.technique == .bend || event.technique == .slide ? event.amount : 0)
            guard allowed.contains(pitchClass(event.pitch)), allowed.contains(pitchClass(target)) else { throw MusicError.invalidPhrase }
        }
        if let last = events.last {
            let chord = chord(at: last.time, in: map)
            let target = last.pitch + (last.technique == .bend || last.technique == .slide ? last.amount : 0)
            guard (chord?.tones ?? map.key(at: last.time).scale).contains(pitchClass(target)) else { throw MusicError.invalidPhrase }
        }
    }

    public static func generate(map: AudioMap, passage: Passage, preferences: Preferences, variation: Int) throws -> [Phrase] {
        try SoloComposer.compose(map: map, passage: passage, preferences: preferences, variation: variation)
    }
}
