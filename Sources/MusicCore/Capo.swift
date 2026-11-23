import Foundation

public struct CapoOption: Identifiable, Encodable {
    public var id: Int { fret }
    public let fret: Int
    public let shapeKey: String
    public let shapes: [String]
    public let openNotes: Int
    public let lowestMidi: Int?
    public let highestMidi: Int?
}

extension Project {
    public func playableEvents(_ phrase: Phrase, shift: Int, capo fret: Int) throws -> [Event] {
        if fret == 0 && shift == 0 { return phrase.events }
        return try Music.fingering(phrase.events, semitones: shift, position: preferences.position,
                                   level: phrase.level, capo: fret)
    }

    public var compositionKey: Key { map.key(at: phrase?.events.first?.time ?? passage.start) }

    public func capoOptions(transpose delta: Int) -> [CapoOption] {
        guard (-12...12).contains(delta) else { return [] }
        let quality = compositionKey
        // Show shapes for the current passage in their order of appearance.
        let chords = map.chords.filter { $0.start < passage.end && $0.end > passage.start }
        return (0...12).compactMap { fret in
            let notes: [Event]
            if let phrase {
                guard let fingering = try? playableEvents(phrase, shift: delta, capo: fret) else { return nil }
                notes = fingering
            } else { notes = [] }
            var shapes: [String] = []
            for chord in chords {
                let label = pitchNames[pitchClass(chord.root + delta - fret)] + chord.quality.suffix
                if !shapes.contains(label) { shapes.append(label) }
                if shapes.count == 8 { break }
            }
            return CapoOption(fret: fret, shapeKey: Key(root: quality.root + delta - fret, minor: quality.minor).label,
                              shapes: shapes, openNotes: notes.filter { $0.relativeFret == 0 }.count,
                              lowestMidi: notes.map(\.pitch).min(), highestMidi: notes.map(\.pitch).max())
        }
    }
}
