import Foundation

/// A section may start partway through a bar. Its first playable sixteenth is step zero.
public struct SectionGrid {
    public let origin: Double
    public let stepDuration: Double
    public let count: Int
    public let firstBarStep: Int

    public init(map: AudioMap, passage: Passage) {
        stepDuration = 15 / map.bpm
        let tick = Int(ceil((passage.start - map.beatOffset) / stepDuration - 1e-8))
        origin = max(passage.start, map.beatOffset + Double(tick) * stepDuration)
        count = max(0, Int(floor((passage.end - origin) / stepDuration + 1e-8)))
        let barLength = map.meter * 4
        firstBarStep = ((-tick % barLength) + barLength) % barLength
    }

    public func step(at time: Double) -> Int {
        min(count, max(0, Int(((time - origin) / stepDuration).rounded())))
    }

    func events(_ score: [[Int]], preferences: Preferences) throws -> [Event] {
        guard (1...128).contains(score.count) else { throw MusicError.invalidArrangement }
        let level = preferences.level
        let highestFret = Music.maxFret(level)
        var events: [Event] = []
        var end = 0
        for row in score {
            // Compact form keeps three full-length choices per section within the API output budget.
            guard (5...6).contains(row.count), row.count == 5 || (-40...40).contains(row[5]) else { throw MusicError.invalidArrangement }
            let step = row[0], hold = row[1], pitch = row[2], velocity = row[3]
            guard step >= end, step < count, hold >= 1, hold <= count - step,
                  (40...(64 + highestFret)).contains(pitch), (35...100).contains(velocity),
                  let gesture = Gesture(rawValue: row[4]) else { throw MusicError.invalidArrangement }
            end = step + hold
            let technique = gesture.technique
            if technique == .harmonic, Music.allowedTechniques(level).contains(.harmonic),
               let node = tuning.enumerated().compactMap({ string, open -> (Int, Int)? in
                   Event.harmonicIntervals.first(where: { open + $0.value == pitch && $0.key <= highestFret }).map { (string, $0.key) }
               }).first {
                events.append(Event(time: origin + Double(step) * stepDuration, duration: Double(hold) * stepDuration,
                                    string: node.0, fret: node.1, velocity: Double(velocity) / 100, technique: .harmonic))
                continue
            }
            let canPerform = technique != .harmonic && Music.allowedTechniques(level).contains(technique) && tuning.contains { open in
                let fret = pitch - open
                return (0...highestFret).contains(fret) && (technique != .bend || fret >= 2)
                    && (0...highestFret).contains(fret + gesture.amount)
            }
            let performedPitch = canPerform ? pitch : min(64 + highestFret, max(40, pitch + gesture.amount))
            // Supply an initial pitch spelling. Music.fingering selects the actual string for the phrase.
            guard let string = tuning.firstIndex(where: { (0...highestFret).contains(performedPitch - $0) })
            else { throw MusicError.unreachable }
            events.append(Event(time: origin + Double(step) * stepDuration, duration: Double(hold) * stepDuration,
                                string: string, fret: performedPitch - tuning[string], velocity: Double(velocity) / 100,
                                technique: canPerform ? technique : .picked, amount: canPerform ? gesture.amount : 0))
        }
        // Shift the whole attack and release together; an early pick damps the previous string.
        if score.contains(where: { $0.count == 6 }) {
            for i in events.indices {
                let delta = score[i].count == 6 ? Double(score[i][5]) * stepDuration / 100 : 0
                let lastStart = origin + Double(count) * stepDuration - events[i].duration
                events[i].time = min(lastStart, max(origin, events[i].time + delta))
                if i > 0 {
                    events[i].time = max(events[i].time, events[i - 1].time + 0.060001)
                    events[i - 1].duration = min(events[i - 1].duration, events[i].time - events[i - 1].time)
                }
                events[i].duration = min(events[i].duration, origin + Double(count) * stepDuration - events[i].time)
            }
        }
        return try Music.fingering(events, semitones: 0, position: preferences.position, level: level)
    }

    private enum Gesture: Int {
        case pick, vibrato, hammer, slideUp, slideDown, bendHalf, bendWhole, harmonic

        var technique: Technique {
            switch self {
            case .harmonic: .harmonic
            case .pick: .picked
            case .vibrato: .vibrato
            case .hammer: .hammer
            case .slideUp, .slideDown: .slide
            case .bendHalf, .bendWhole: .bend
            }
        }

        var amount: Int {
            switch self {
            case .slideUp, .bendHalf: 1
            case .slideDown: -1
            case .bendWhole: 2
            default: 0
            }
        }
    }
}
