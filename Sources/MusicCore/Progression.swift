import Foundation

public enum Progression {
    public enum InputError: LocalizedError {
        case chord(String), tooMany
        public var errorDescription: String? {
            switch self {
            case .chord(let chord): return "Acorde não reconhecido: \(chord). Exemplo: Am F C G."
            case .tooMany: return "Use entre 1 e 32 acordes."
            }
        }
    }

    public static func apply(_ symbols: String, passage: Passage, to map: inout AudioMap) throws {
        try Music.validate(passage, duration: map.duration)
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|,–"))
        let tokens = symbols.components(separatedBy: separators).filter { !$0.isEmpty }
        guard (1...32).contains(tokens.count) else { throw InputError.tooMany }
        let chords = try tokens.map(parse)
        let bar = 60 / map.bpm * Double(map.meter)
        let slot = min(bar, (passage.end - passage.start) / Double(chords.count))
        var result: [Chord] = []
        for chord in map.chords {
            if chord.start < passage.start {
                var left = chord
                left.end = min(chord.end, passage.start)
                result.append(left)
            }
            if chord.end > passage.end {
                var right = chord
                // The original can span both edges of the edited passage.
                if chord.start < passage.start { right.id = UUID() }
                right.start = max(chord.start, passage.end)
                result.append(right)
            }
        }
        var index = 0
        var time = passage.start
        let downbeat = map.beatOffset + ceil((time - map.beatOffset) / bar - 0.00001) * bar
        let pickup = max(0, downbeat - time)
        let alignment = slot == bar && pickup > 0.015 ? (pickup < bar * 0.35 ? pickup : pickup - bar) : 0
        while time < passage.end - 0.001 {
            let end = min(passage.end, passage.start + alignment + Double(index + 1) * slot)
            let symbol = chords[index % chords.count]
            var chord = Chord(start: time, end: end, root: symbol.0, minor: false, confidence: 1)
            chord.quality = symbol.1
            result.append(chord)
            index += 1
            time = end
        }
        map.chords = result.sorted { $0.start < $1.start }
        map.writtenHarmony = WrittenHarmony(start: passage.start, end: passage.end, key: inferKey(chords, fallback: map.key))
    }

    private static func inferKey(_ chords: [(Int, ChordQuality)], fallback: Key) -> Key {
        if chords.count < 2 { return fallback }
        let possibilities = (0..<12).flatMap { root in [Key(root: root), Key(root: root, minor: true)] }
        func score(_ key: Key) -> Double {
            let scale = Set(key.scale)
            return chords.enumerated().reduce(0) { score, item in
                let (root, quality) = item.element
                let tones = quality.intervals.map { pitchClass(root + $0) }
                let fit = tones.reduce(0.0) { $0 + (scale.contains($1) ? 1 : -1.75) }
                let tonicQuality = quality == .minor || quality == .minor7
                let home: Double = root == key.root && tonicQuality == key.minor ? (item.offset == 0 ? 2.8 : 0.6) : 0
                return score + fit + home
            }
        }
        return possibilities.max { score($0) < score($1) } ?? fallback
    }

    private static func parse(_ value: String) throws -> (Int, ChordQuality) {
        let raw = value.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        let head = raw.prefix(1).uppercased()
        let roots = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var root = roots[head] else { throw InputError.chord(value) }
        var suffix = raw.dropFirst()
        if suffix.first == "#" { root += 1; suffix = suffix.dropFirst() }
        if suffix.first == "b" { root -= 1; suffix = suffix.dropFirst() }
        let variants: [String: ChordQuality] = ["": .major, "maj": .major, "M": .major, "m": .minor, "min": .minor,
                                                "7": .dominant, "m7": .minor7, "min7": .minor7, "maj7": .major7,
                                                "M7": .major7, "dim": .diminished, "°": .diminished, "sus4": .sus4]
        guard let quality = variants[String(suffix)] else { throw InputError.chord(value) }
        return (pitchClass(root), quality)
    }
}
