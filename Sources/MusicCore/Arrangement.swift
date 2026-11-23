import Foundation

public enum AmpPreset: String, Choice, Sendable {
    case clean, edge, lead, space, acoustic

    public var title: String {
        switch self {
        case .clean: "Limpo"
        case .edge: "Crunch"
        case .lead: "Lead"
        case .space: "Ambiente"
        case .acoustic: "Violão"
        }
    }
    public var instrument: Instrument {
        switch self {
        case .edge, .lead: .driven
        case .clean, .space: .clean
        case .acoustic: .acoustic
        }
    }
    public var tone: Tone {
        switch self {
        case .clean: Tone(drive: 0.10, room: 0.22, delay: 0.08, sustain: 0.55)
        case .edge: Tone(drive: 0.31, room: 0.23, delay: 0.11, sustain: 0.67)
        case .lead: Tone(drive: 0.57, room: 0.20, delay: 0.23, sustain: 0.78)
        case .space: Tone(drive: 0.16, room: 0.55, delay: 0.48, sustain: 0.72)
        case .acoustic: Tone(drive: 0, room: 0.24, delay: 0.06, sustain: 0.52)
        }
    }
}

public struct SoloIdea: Codable, Equatable {
    public enum Style: String, Codable, CaseIterable {
        case melodic, blues, rock, soul
        var genre: Genre {
            switch self { case .melodic: .melodic; case .blues: .blues; case .rock: .rock; case .soul: .soul }
        }
    }
    public struct Hit: Codable, Equatable, Hashable {
        public var step: Int
        public var hold: Int
        public var interval: Int
        public var velocity: Int
        public init(step: Int, hold: Int, interval: Int, velocity: Int) {
            self.step = step; self.hold = hold; self.interval = interval; self.velocity = velocity
        }
    }
    public var name: String
    public var intent: String
    public var style: Style
    public var score: [[Int]]?
    public var pickup: Int
    public var figure: [Hit]
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        intent = try values.decode(String.self, forKey: .intent)
        style = try values.decode(Style.self, forKey: .style)
        score = try values.decodeIfPresent([[Int]].self, forKey: .score)
        if score != nil {
            pickup = 0
            figure = []
        } else {
            pickup = try values.decode(Int.self, forKey: .pickup)
            figure = try values.decode([Hit].self, forKey: .figure)
        }
    }

    var melodySignature: [[Int]] {
        score?.map { Array($0.prefix(3)) } ?? figure.map { [$0.step, $0.interval] }
    }

    public init(name: String, intent: String, style: Style, pickup: Int, figure: [Hit]) {
        self.name = name; self.intent = intent; self.style = style; self.pickup = pickup; self.figure = figure
    }
}
public struct SectionIdea: Codable, Equatable {
    public var index: Int
    public var name: String
    public var options: [SoloIdea]
    public init(index: Int, name: String, options: [SoloIdea]) {
        self.index = index; self.name = name; self.options = options
    }
}
public struct ArrangementPlan: Codable, Equatable {
    public var amp: AmpPreset
    public var sections: [SectionIdea]
    public init(amp: AmpPreset, sections: [SectionIdea]) {
        self.amp = amp; self.sections = sections
    }
}
public struct SoloSection: Codable, Identifiable, Equatable {
    public var passage: Passage
    public var alternatives: [Phrase]
    public var selected: UUID?
    public init(passage: Passage, alternatives: [Phrase], selected: UUID?) {
        self.passage = passage
        self.alternatives = alternatives
        self.selected = selected
    }
    public var id: UUID { passage.id }
    public var phrase: Phrase? { alternatives.first { $0.id == selected } ?? alternatives.first }
}
public struct SoloArrangement: Codable, Equatable {
    public var sections: [SoloSection]
    public var featured: SoloSection?
    public var level: Level
    public var model: String
    public var usage: String?
    public init(sections: [SoloSection], level: Level, model: String, usage: String? = nil) {
        self.sections = sections; self.level = level; self.model = model; self.usage = usage
    }
}

extension Phrase {
    private struct Position: Hashable {
        let string: Int
        let fret: Int
    }

    public var positionCount: Int {
        Set(events.map { Position(string: $0.string, fret: $0.fret) }).count
    }

    public var hasSoloPositions: Bool { positionCount >= SongStructure.minimumSoloPositions }
}

public enum SongStructure {
    public static let minimumSoloPositions = 11

    public static func passages(_ map: AudioMap) -> [Passage] {
        guard map.duration >= 3.6 else { return [Passage("Faixa inteira", 0, map.duration)] }
        let duration = map.duration
        let beat = 60 / map.bpm
        let bar = beat * Double(map.meter)
        let ideal = max(4.9, min(17, bar * 6))
        let natural = map.sections.compactMap { section -> Double? in
            let time = section.start
            guard time > 3.4, time < duration - 3.4 else { return nil }
            let snapped = map.beatOffset + ((time - map.beatOffset) / beat).rounded() * beat
            return (3.4...(duration - 3.4)).contains(snapped) ? snapped : time
        }.sorted()
        var edges = [0.0]
        for cut in natural where cut - edges.last! >= 3.4 { edges.append(cut) }
        edges.append(duration)
        var dense = [edges[0]]
        for ending in edges.dropFirst() {
            let start = dense.last!
            let count = min(16, max(1, Int(((ending - start) / max(ideal * 1.25, duration / 13)).rounded(.up))))
            for subdivision in 1..<count {
                let estimate = start + (ending - start) * Double(subdivision) / Double(count)
                let beatTime = map.beatOffset + ((estimate - map.beatOffset) / beat).rounded() * beat
                dense.append(min(ending - 1.1, max(dense.last! + 1.1, beatTime)))
            }
            dense.append(ending)
        }
        while dense.count > 17 {
            if let merge = (1..<(dense.count - 1)).min(by: { dense[$0 + 1] - dense[$0 - 1] < dense[$1 + 1] - dense[$1 - 1] }) {
                dense.remove(at: merge)
            }
        }
        return (0..<(dense.count - 1)).map { index in
            let label = dense.count == 2 ? "Faixa inteira" : index == 0 ? "Abertura" : index == dense.count - 2 ? "Final" : "Parte \(index + 1)"
            return Passage(label, dense[index], dense[index + 1])
        }
    }

    // Compare sustained arrivals over the chords actually sounding. Short passing notes
    // and tensions that resolve by step keep their place in the written phrase.
    static func harmonicFit(_ phrase: Phrase, map: AudioMap) -> Double {
        var fit = 0.0, weight = 0.0
        let beat = 60 / map.bpm
        for (i, note) in phrase.events.enumerated() {
            let target = pitchClass(note.pitch + note.amount)
            let final = i == phrase.events.count - 1
            guard final || note.duration >= beat * 0.7 else { continue }
            for chord in map.chords where chord.confidence >= 0.12 && chord.start < note.end && chord.end > note.time {
                let overlap = min(note.end, chord.end) - max(note.time, chord.start)
                let w = overlap * chord.confidence * (final ? 2 : 1)
                var consonance = chord.tones.contains(target) ? 1.0 : 0.0
                if consonance == 0 && !final {
                    let next = phrase.events[i + 1]
                    if (1...2).contains(abs(next.pitch - (note.pitch + note.amount))), next.time - note.end < beat / 2,
                       chord.tones.contains(pitchClass(next.pitch)) { consonance = 0.75 }
                }
                fit += w * consonance
                weight += w
            }
        }
        return weight > 0 ? fit / weight : 0.5
    }

    public static func realize(_ plan: ArrangementPlan, map: AudioMap, passages: [Passage],
                               preferences: Preferences, featured: Bool = false) throws -> [SoloSection] {
        let ordered = plan.sections.sorted { $0.index < $1.index }
        guard ordered.map(\.index) == Array(passages.indices) else { throw MusicError.invalidArrangement }
        return try ordered.map { section in
            try Task.checkCancellation()
            guard (1...50).contains(section.name.trimmingCharacters(in: .whitespacesAndNewlines).count),
                  (featured ? (1...3).contains(section.options.count) : section.options.count == 3),
                  Set(section.options.map(\.melodySignature)).count == section.options.count else {
                throw MusicError.invalidArrangement
            }
            var passage = passages[section.index]
            passage.name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let choices = try section.options.enumerated().compactMap { number, choice -> Phrase? in
                guard (1...45).contains(choice.name.trimmingCharacters(in: .whitespacesAndNewlines).count),
                      (1...220).contains(choice.intent.trimmingCharacters(in: .whitespacesAndNewlines).count) else {
                    throw MusicError.invalidArrangement
                }
                if let score = choice.score {
                    let events = try SectionGrid(map: map, passage: passage).events(score, preferences: preferences)
                    let phrase = Phrase(name: choice.name, explanation: choice.intent, events: events, level: preferences.level)
                    if featured {
                        guard phrase.hasSoloPositions else { return nil }
                        let bar = 60 / map.bpm * Double(map.meter)
                        guard let first = events.first, let last = events.last,
                              last.end - first.time >= min(bar * 4, map.duration * 0.55),
                              !zip(events, events.dropFirst()).contains(where: { $1.time - $0.end > bar * 3 }) else {
                            return nil
                        }
                    }
                    try Music.validate(events, in: passage, level: preferences.level)
                    return phrase
                }
                guard !featured, (0...6).contains(choice.pickup), (2...9).contains(choice.figure.count),
                      choice.figure.map(\.step) == Array(Set(choice.figure.map(\.step))).sorted(),
                      choice.figure.allSatisfy({ (0...15).contains($0.step) && (1...12).contains($0.hold) &&
                          (-9...12).contains($0.interval) && (35...100).contains($0.velocity) }) else {
                    throw MusicError.invalidArrangement
                }
                return try SoloComposer.fromPlan(choice, map: map, passage: passage, preferences: preferences, variation: number)
            }
            guard !choices.isEmpty else { throw MusicError.noCompleteSolo }
            let ranked = featured ? choices.map { ($0, harmonicFit($0, map: map)) }.sorted { $0.1 > $1.1 }.map { $0.0 } : choices
            return SoloSection(passage: passage, alternatives: ranked, selected: ranked.first?.id)
        }
    }
}

extension Project {
    public var hasGeneratedSolos: Bool { arrangement != nil || !alternatives.isEmpty }
    public var hasLyricsOrChords: Bool { chordSheet || !lyrics.isEmpty }

    public mutating func clearGeneratedMusic(includingLyrics: Bool) {
        arrangement = nil
        activeSection = nil
        alternatives = []
        selected = nil
        passage = Passage("Meu trecho", 0, min(map.duration, 16))
        loop = false
        capoFret = nil
        transpose = 0
        transposeRecording = false
        if includingLyrics {
            lyrics = []
            chordSheet = false
        }
    }

    public var showingFeatured: Bool { activeSection != nil && activeSection == arrangement?.featured?.id }

    public var preferredLead: SoloSection? {
        guard var lead = arrangement?.featured else { return nil }
        func usable(_ phrase: Phrase) -> Bool {
            phrase.hasSoloPositions && (try? playableEvents(phrase, shift: transpose, capo: capo)) != nil
        }
        if lead.phrase.map(usable) != true {
            guard let complete = lead.alternatives.first(where: usable) else { return nil }
            lead.selected = complete.id
        }
        return lead
    }

    private mutating func focusSolo() {
        guard let first = phrase?.events.first, let last = phrase?.events.last else { return }
        let bar = 60 / map.bpm * Double(map.meter)
        passage.start = max(0, min(first.time - bar, map.duration - 1))
        passage.end = min(map.duration, max(passage.start + 1, last.end + bar))
    }

    public mutating func activateSection(_ section: SoloSection) {
        activeSection = section.id
        passage = section.passage
        alternatives = section.alternatives
        selected = section.selected
        if showingFeatured { focusSolo() }
    }

    public mutating func saveSectionEdits() {
        if showingFeatured {
            if selected != arrangement?.featured?.selected { focusSolo() }
            arrangement?.featured?.alternatives = alternatives
            arrangement?.featured?.selected = selected
            return
        }
        guard let activeSection, let index = arrangement?.sections.firstIndex(where: { $0.id == activeSection }) else { return }
        arrangement?.sections[index].alternatives = alternatives
        arrangement?.sections[index].selected = selected
    }
}
