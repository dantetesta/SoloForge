import Foundation

enum SoloComposer {
    private struct Attack {
        let beat: Double
        let gate: Double
        let contour: Int
        let accent: Double
    }
    private struct Cue {
        let time: Double
        let duration: Double
        let target: Int
        let accent: Double
        let final: Bool
        let chord: Chord?
        let tones: Set<Int>
    }
    private struct Fingering {
        let pitch: Int
        let string: Int
        let fret: Int
    }
    private struct Path {
        let notes: [Fingering]
        let cost: Double
    }

    static func compose(map: AudioMap, passage: Passage, preferences: Preferences, variation: Int) throws -> [Phrase] {
        try Music.validate(passage, duration: map.duration)
        let request = preferences.genre ?? .varied
        let styles: [Genre] = request == .varied ? [.melodic, .blues, .rock] : Array(repeating: request, count: 3)
        let roles = ["Tema", "Resposta", "Clímax"]
        return try styles.enumerated().map { index, style in
            let cues = arrange(map: map, passage: passage, prefs: preferences, style: style, part: index, seed: pitchClass(variation))
            let path = try planFingering(cues, prefs: preferences, style: style)
            let events = articulate(cues, path: path, prefs: preferences, style: style, seed: pitchClass(variation + index))
            try Music.validate(events, in: passage, level: preferences.level)
            try Music.validateHarmony(events, map: map)
            let name = request == .varied ? style.rawValue : "\(style.rawValue) · \(roles[index])"
            return Phrase(name: name, explanation: explanation(style, part: index), events: events, level: preferences.level)
        }
    }

    static func fromPlan(_ idea: SoloIdea, map: AudioMap, passage: Passage, preferences: Preferences, variation: Int) throws -> Phrase {
        try Music.validate(passage, duration: map.duration)
        let style = idea.style.genre
        let cues = arrange(map: map, passage: passage, prefs: preferences, style: style, part: variation, seed: 0, idea: idea)
        let fingering = try planFingering(cues, prefs: preferences, style: style)
        let events = articulate(cues, path: fingering, prefs: preferences, style: style, seed: variation)
        try Music.validate(events, in: passage, level: preferences.level)
        try Music.validateHarmony(events, map: map)
        return Phrase(name: idea.name.trimmingCharacters(in: .whitespacesAndNewlines),
                      explanation: idea.intent.trimmingCharacters(in: .whitespacesAndNewlines), events: events, level: preferences.level)
    }

    private static func arrange(map: AudioMap, passage: Passage, prefs: Preferences, style: Genre, part: Int, seed: Int,
                                idea: SoloIdea? = nil) -> [Cue] {
        let beat = 60 / map.bpm
        let meter = Double(map.meter)
        var start = map.beatOffset + ceil((passage.start - map.beatOffset) / beat - 0.000001) * beat
        if let idea {
            start += Double(idea.pickup) * beat * 0.25
        } else if prefs.placement == .answer {
            let midpoint = passage.start + (passage.end - passage.start) * 0.55
            if let breath = map.vocalHints?.first(where: { $0.end >= start && $0.end <= midpoint && $0.confidence >= 0.54 }) {
                start += ceil((breath.end - start) / beat + 0.2) * beat
            } else { start += beat * 0.5 }
        }
        if idea == nil, prefs.placement == .ending, passage.end - start > meter * beat * 4 {
            start += floor((passage.end - start) / (meter * beat) - 3) * meter * beat
        }
        if passage.end - start < max(0.65, beat) { start = passage.start }
        let span = min(meter * 8, (passage.end - start) / beat)
        let bars = max(1, Int(ceil(span / meter)))
        let simple = prefs.level == .beginner
        let feel: Double = prefs.mood == .energetic ? 0.78 : prefs.mood == .subtle ? 0.84 : 0.94
        let swing = style == .blues || style == .soul ? 0.14 : 0
        let finish = start + span * beat
        var outline: [(Double, Double, Int, Double)] = []
        for bar in 0..<bars {
            let figure = idea.map { plan in
                plan.figure.map { hit in
                    Attack(beat: Double(hit.step) / 4, gate: Double(hit.hold) / 4,
                           contour: hit.interval, accent: min(0.91, max(0.28, Double(hit.velocity - 25) / 82)))
                }
            } ?? rhythm(style, variation: (bar + part + seed) % 4)
            for (index, hit) in figure.enumerated() {
                if (simple && hit.accent < 0.32) || (prefs.mood == .subtle && hit.accent < 0.24) { continue }
                if idea != nil, simple, figure.count > 5 && index.isMultiple(of: 2) == false { continue }
                let late = hit.beat.truncatingRemainder(dividingBy: 1) == 0.5 ? swing : 0
                let pulse = Double(bar) * meter + hit.beat * meter / 4 + late
                let humanize = hit.accent < 0.52 ? Double((outline.count * 17 + seed * 2) % 11 - 4) / 1_000 : 0
                let time = max(passage.start, start + pulse * beat + humanize)
                if time + 0.10 > finish || (outline.last.map { time - $0.0 < 0.071 } ?? false) { continue }
                let register = bar == 0 ? 0 : bar == bars - 1 ? 1 : part == 2 ? 5 : 2
                outline.append((time, hit.gate * beat * feel, hit.contour + register + seed % 3 - 1, hit.accent))
            }
        }
        if span < 3 || outline.count < 2 {
            let room = finish - start
            outline = [(start + room * Double(part) * 0.10, room * 0.22, idea?.figure.first?.interval ?? 0, 0.52),
                       (start + room * (0.43 + Double(part) * 0.12), room * 0.40, idea?.figure.last?.interval ?? 4 - part, 0.82)]
        }
        let primaryKey = map.key(at: start)
        let register = style == .rock ? 60...71 : 55...66
        let anchor = register.first { pitchClass($0) == primaryKey.root } ?? 63
        return outline.enumerated().map { index, hit in
            let final = index == outline.count - 1
            let next = final ? finish : outline[index + 1].0
            let gap = max(0.007, min(0.081, (next - hit.0) * 0.18))
            let duration = max(0.06, min(next - hit.0 - gap, hit.1 * (final ? 1.7 : 1)))
            let chord = Music.chord(at: hit.0, in: map)
            let key = map.key(at: hit.0)
            let scale = Set(key.scale)
            let blues = Set([0, 3, 5, 7, 10].map { pitchClass(key.root + $0) }).intersection(scale)
            let stock = Set(chord?.tones ?? [key.root, key.scale[2], key.scale[4]])
            let vocabulary = style == .blues && hit.3 < 0.45 ? blues : scale
            let tones = final || hit.3 >= 0.56 ? stock : vocabulary.union(stock)
            let mood = prefs.mood == .energetic ? 2 : prefs.mood == .subtle ? -2 : 0
            let target = anchor + (final ? 0 : hit.2 + mood)
            return Cue(time: hit.0, duration: duration, target: target, accent: hit.3, final: final, chord: chord, tones: tones)
        }
    }

    private static func planFingering(_ cues: [Cue], prefs: Preferences, style: Genre) throws -> [Fingering] {
        let maxFret = Music.maxFret(prefs.level)
        let candidates = tuning.enumerated().flatMap { string, open in
            (0...maxFret).compactMap { fret -> Fingering? in
                guard (48...85).contains(open + fret) else { return nil }
                return Fingering(pitch: open + fret, string: string, fret: fret)
            }
        }
        var paths = [Path(notes: [], cost: 0)]
        for (index, cue) in cues.enumerated() {
            let allowed = candidates.filter { cue.tones.contains(pitchClass($0.pitch)) }
            var next: [Path] = []
            for path in paths {
                for note in allowed {
                    var cost = Double(abs(note.pitch - cue.target)) * 1.60
                    let distance = abs(note.fret - prefs.position)
                    cost += Double(distance) * (prefs.level == .beginner ? 0.72 : 0.35)
                    if let previous = path.notes.last {
                        let leap = abs(note.pitch - previous.pitch)
                        let stretch = abs(note.fret - previous.fret)
                        let strings = abs(note.string - previous.string)
                        cost += 0.18 * Double(leap) + 0.44 * Double(stretch) + 0.67 * Double(strings)
                        cost += Double(max(0, leap - (prefs.level == .beginner ? 5 : 8))) * 3.2
                        if leap == 0 {
                            let again = path.notes.count >= 2 && path.notes[path.notes.count - 2].pitch == note.pitch
                            cost += again ? 9.0 : (style == .blues && index.isMultiple(of: 4) ? 1.25 : 3.9)
                        }
                        if index >= 5, index.isMultiple(of: 3), pitchClass(path.notes[index % 3].pitch) == pitchClass(note.pitch) {
                            cost -= 1.7
                        }
                    }
                    if cue.final, let chord = cue.chord, pitchClass(note.pitch) == chord.root { cost -= 2.6 }
                    next.append(Path(notes: path.notes + [note], cost: path.cost + cost))
                }
            }
            paths = Array(next.sorted { $0.cost < $1.cost }.prefix(16))
        }
        guard let best = paths.first, !best.notes.isEmpty else { throw MusicError.unreachable }
        return best.notes
    }

    private static func articulate(_ cues: [Cue], path: [Fingering], prefs: Preferences, style: Genre, seed: Int) -> [Event] {
        var result: [Event] = []
        for index in cues.indices {
            let beat = cues[index], note = path[index]
            let level = prefs.level.index
            let base: Double = prefs.mood == .subtle ? 0.48 : prefs.mood == .energetic ? 0.66 : 0.55
            let velocity = min(0.99, base + beat.accent * 0.29 + Double((index * 19 + seed) % 9 - 4) * 0.010)
            var technique: Technique = .picked
            var amount = 0
            if level > 0, beat.duration > 0.24, beat.final || (index + seed).isMultiple(of: 7) { technique = .vibrato }
            if level >= 2 && index > 0 && !beat.final {
                let previous = result[index - 1]
                if (style == .blues || style == .rock), (index + seed).isMultiple(of: 4),
                   beat.duration >= 0.23, note.fret >= 3, note.string <= 3,
                   let semitones = [2, 1].first(where: { beat.tones.contains(pitchClass(note.pitch + $0)) }) {
                    technique = .bend; amount = semitones
                } else if (style == .melodic || style == .soul), index % 6 == 3, beat.duration >= 0.24,
                          let semitones = [2, -2, 1, -1].first(where: { (0...Music.maxFret(prefs.level)).contains(note.fret + $0) && beat.tones.contains(pitchClass(note.pitch + $0)) }) {
                    technique = .slide; amount = semitones
                } else if !beat.final, beat.accent < 0.50, index % 3 == 2, note.string == previous.string,
                          (1...4).contains(abs(note.fret - previous.fret)), beat.time - previous.end < 0.11 {
                    technique = .hammer
                }
            }
            result.append(Event(time: beat.time, duration: beat.duration, string: note.string, fret: note.fret,
                                velocity: velocity, technique: technique, amount: amount))
        }
        return result
    }

    private static func rhythm(_ style: Genre, variation: Int) -> [Attack] {
        let phrase: [(Double, Double, Int, Double)]
        switch (style, variation) {
        case (.blues, 0): phrase = [(0,0.46,0,0.72),(0.5,0.30,3,0.20),(1,0.88,5,0.46),(2.5,0.34,3,0.32),(3,0.64,0,0.70)]
        case (.blues, 1): phrase = [(0.5,0.24,0,0.36),(1,0.49,3,0.64),(1.5,0.23,5,0.22),(2,0.75,7,0.75),(3.5,0.40,3,0.47)]
        case (.blues, 2): phrase = [(0,1.02,5,0.82),(1.5,0.32,7,0.28),(2,0.61,10,0.65),(2.5,0.28,7,0.28),(3,0.83,5,0.66)]
        case (.blues, _): phrase = [(0,0.45,5,0.7),(0.5,0.31,3,0.24),(1.5,0.35,0,0.32),(2,1.50,-2,0.86)]
        case (.rock, 0): phrase = [(0,0.61,0,0.76),(0.75,0.24,2,0.24),(1,0.54,5,0.63),(2,0.30,7,0.56),(2.5,0.31,9,0.26),(3,0.88,7,0.74)]
        case (.rock, 1): phrase = [(0,0.33,5,0.64),(0.5,0.29,7,0.27),(1,0.44,9,0.67),(1.5,0.35,10,0.31),(2,1.26,12,0.84),(3.5,0.35,10,0.29)]
        case (.rock, 2): phrase = [(0,0.75,12,0.75),(1,0.24,10,0.52),(1.5,0.31,9,0.28),(2,0.21,7,0.63),(2.5,0.22,5,0.23),(3,0.72,4,0.68)]
        case (.rock, _): phrase = [(0,0.42,7,0.67),(0.5,0.32,5,0.32),(1,0.54,4,0.52),(2,0.34,2,0.56),(2.5,0.27,4,0.25),(3,1.08,0,0.86)]
        case (.soul, 0): phrase = [(0.5,0.44,2,0.43),(1,0.73,4,0.63),(2.5,0.29,7,0.24),(3,0.9,9,0.77)]
        case (.soul, 1): phrase = [(0,0.90,7,0.72),(1.5,0.30,9,0.26),(2,0.41,11,0.62),(2.5,0.27,9,0.23),(3.5,0.30,7,0.41)]
        case (.soul, 2): phrase = [(0,0.32,9,0.62),(0.5,0.32,7,0.28),(1,0.73,4,0.67),(2.5,0.42,2,0.33),(3,0.82,4,0.71)]
        case (.soul, _): phrase = [(0.5,0.42,7,0.41),(1,0.48,5,0.63),(1.5,0.42,4,0.30),(2,1.62,2,0.86)]
        case (_, 0): phrase = [(0,0.78,0,0.63),(1,0.46,2,0.44),(1.5,0.37,4,0.23),(2,0.96,7,0.68),(3.5,0.30,5,0.31)]
        case (_, 1): phrase = [(0,0.50,4,0.58),(0.75,0.40,5,0.26),(1.5,0.85,7,0.48),(2.5,0.36,9,0.34),(3,0.85,7,0.70)]
        case (_, 2): phrase = [(0.25,0.59,5,0.53),(1,0.44,7,0.57),(1.5,0.37,9,0.29),(2,1.37,12,0.77),(3.5,0.30,9,0.33)]
        case (_, _): phrase = [(0,0.54,7,0.60),(0.75,0.29,5,0.29),(1.25,0.33,4,0.30),(2,1.56,0,0.84)]
        }
        return phrase.map { Attack(beat: $0.0, gate: $0.1, contour: $0.2, accent: $0.3) }
    }

    private static func explanation(_ style: Genre, part: Int) -> String {
        switch style {
        case .blues: "Chamada e resposta com balanço e vocabulário pentatônico."
        case .rock: "Ataque firme, registro ascendente e resolução marcada."
        case .soul: "Síncopes e notas sustentadas sobre as mudanças."
        case .melodic, .varied: part == 2 ? "Clímax no registro agudo com volta à nota do acorde." : "Tema cantável que se desenvolve ao longo dos compassos."
        }
    }
}
