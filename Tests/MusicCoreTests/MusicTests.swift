import Foundation
import Testing
@testable import MusicCore

@Test func alternativesFollowLevelAndHarmony() throws {
    let map = AudioMap(duration: 31, bpm: 112, beatOffset: 0.43, key: Key(root: 0),
                       chords: [Chord(start: 0, end: 4, root: 7, minor: false, confidence: 1),
                                Chord(start: 4, end: 31, root: 9, minor: true, confidence: 1)])
    let passage = Passage("Estudo", 1, 11)
    for level in Level.allCases {
        for mood in Mood.allCases {
            for placement in Placement.allCases {
                var options = Preferences()
                options.level = level; options.mood = mood; options.placement = placement
                let proposals = try Music.generate(map: map, passage: passage, preferences: options, variation: 6)
                #expect(proposals.count == 3)
                for phrase in proposals {
                    try Music.validate(phrase.events, in: passage, level: level)
                    try Music.validateHarmony(phrase.events, map: map)
                    let event = try #require(phrase.events.first)
                    #expect(phrase.active(at: event.time)?.id == event.id)
                    #expect(phrase.active(at: event.end)?.id != event.id)
                }
                #expect(Set(proposals.map { $0.events.map(\.time) }).count == 3)
            }
        }
    }
}

@Test func transpositionPreservesClockAndBend() throws {
    let event = Event(time: 3.23, duration: 0.5, string: 2, fret: 7, velocity: 0.8, technique: .bend, amount: 2)
    let result = try #require(Music.fingering([event], semitones: 3, position: 5, level: .advanced).first)
    #expect(result.id == event.id)
    #expect(result.pitch == event.pitch + 3)
    #expect(result.time == event.time)
    #expect(result.duration == event.duration)
    #expect(result.pitchOffset(at: 0) == 0)
    #expect(result.pitchOffset(at: 0.62) == 2)
    let inverse = try #require(Music.fingering([result], semitones: -3, position: 5, level: .advanced).first)
    #expect(inverse.pitch == event.pitch)
}

@Test func validationRejectsCollisionsAndUnsupportedTechniques() throws {
    let note = Event(time: 1, duration: 0.7, string: 2, fret: 7, velocity: 0.73)
    var collision = note; collision.time = 1.5
    #expect(throws: MusicError.self) { try Music.validate([note, collision], in: Passage("", 0, 3), level: .advanced) }
    var bend = note; bend.technique = .bend; bend.amount = 3
    #expect(throws: MusicError.self) { try Music.validate([bend], in: Passage("", 0, 3), level: .advanced) }
    bend.amount = 2
    #expect(throws: MusicError.self) { try Music.validate([bend], in: Passage("", 0, 3), level: .beginner) }
    var slide = note; slide.technique = .slide; slide.fret = 0; slide.amount = -2
    #expect(throws: MusicError.self) { try Music.validate([slide], in: Passage("", 0, 3), level: .advanced) }
}

@Test func projectModelRoundTrips() throws {
    let map = AudioMap(duration: 34.83, bpm: 129.3, beatOffset: 0.28, meter: 3, key: Key(root: 4, minor: true))
    var project = Project(name: "Estudo", sourceHash: String(repeating: "a", count: 64), map: map)
    project.alternatives = try Music.generate(map: map, passage: project.passage, preferences: project.preferences, variation: 2)
    project.selected = project.alternatives[2].id
    project.alternatives[2].approved = true
    project.lyrics = [Lyric(time: 2.25, text: "Verso de teste")]
    project.chordSheet = true
    project.speed = 0.65
    let data = try JSONEncoder().encode(project)
    let restored = try JSONDecoder().decode(Project.self, from: data)
    #expect(restored == project)
    try Music.validate(restored)
}

@Test func progressionKeepsUntouchedRangesAndSetsChordQualities() throws {
    var map = AudioMap(duration: 20, bpm: 120, chords: [Chord(start: 0, end: 20, root: 0, minor: false, confidence: 1)])
    try Progression.apply("Am | Fmaj7 C G7", passage: Passage("Estudo", 4, 12), to: &map)
    #expect(map.chords.map(\.label) == ["C", "Am", "Fmaj7", "C", "G7", "C"])
    #expect(map.chords.map(\.start) == [0, 4, 6, 8, 10, 12])
    #expect(map.chords.map(\.end) == [4, 6, 8, 10, 12, 20])
    #expect(Set(map.chords.map(\.id)).count == 6)
    #expect(map.key(at: 5) == Key(root: 9, minor: true))
    #expect(map.key(at: 13) == Key(root: 0))
    #expect(throws: Progression.InputError.self) {
        try Progression.apply("Z", passage: Passage("Estudo", 4, 12), to: &map)
    }
}

@Test func genreChangesContourAndRhythmAcrossTheSameChords() throws {
    let passage = Passage("Estudo", 0, 8)
    var map = AudioMap(duration: 12, bpm: 120, key: Key(root: 9, minor: true))
    try Progression.apply("Am F C G", passage: passage, to: &map)
    var prefs = Preferences()
    prefs.level = .intermediate
    prefs.genre = .blues
    let blues = try Music.generate(map: map, passage: passage, preferences: prefs, variation: 4)
    prefs.genre = .rock
    let rock = try Music.generate(map: map, passage: passage, preferences: prefs, variation: 4)
    #expect(blues.allSatisfy { $0.name.hasPrefix("Blues") && $0.events.count > 8 })
    #expect(blues[0].events.map(\.time) != rock[0].events.map(\.time))
    #expect(blues[0].events.map(\.pitch) != rock[0].events.map(\.pitch))
    #expect(Set(rock[0].events.map(\.pitch)).count >= 4)
    for index in blues.indices {
        let last = try #require(blues[index].events.last)
        let chord = try #require(Music.chord(at: last.time, in: map))
        #expect(chord.tones.contains(pitchClass(last.pitch)))
    }
}

@Test func partPlanHasThreeDistinctPlayableChoicesAcrossTheWholeSong() throws {
    var map = AudioMap(duration: 17.6, bpm: 125, beatOffset: 0.13, key: Key(root: 9, minor: true),
                       sections: [Passage("Intro", 0, 5.4), Passage("Meio", 5.4, 10), Passage("Final", 10, 17.6)])
    try Progression.apply("Am F C G", passage: Passage("Toda", 0, 17.6), to: &map)
    let passages = SongStructure.passages(map)
    #expect(passages.count >= 3)
    #expect(passages.first?.start == 0)
    #expect(passages.last?.end == map.duration)
    let ideas = [0, 1, 2].map { index in
        SoloIdea(name: "Escolha \(index)", intent: "Estudo", style: index == 1 ? .blues : .melodic, pickup: index,
                 figure: [.init(step: index, hold: 2, interval: 0, velocity: 76),
                          .init(step: 5, hold: 3, interval: 2 + index, velocity: 68),
                          .init(step: 12, hold: 4, interval: 4 - index, velocity: 82)])
    }
    let plan = ArrangementPlan(amp: .space, sections: passages.indices.map {
        SectionIdea(index: $0, name: "Parte \($0 + 1)", options: ideas)
    })
    for level in Level.allCases {
        var prefs = Preferences()
        prefs.level = level
        let parts = try SongStructure.realize(plan, map: map, passages: passages, preferences: prefs)
        #expect(parts.count == passages.count)
        #expect(parts.allSatisfy { $0.alternatives.count == 3 })
        try Music.validate(parts.compactMap(\.phrase).flatMap(\.events), in: Passage("Sequência", 0, map.duration), level: level)
        var project = Project(name: "Música", sourceHash: String(repeating: "b", count: 64), map: map)
        project.arrangement = SoloArrangement(sections: parts, level: level, model: "Plano de teste")
        project.activateSection(parts[0])
        project.alternatives[0].approved = true
        project.saveSectionEdits()
        project.activateSection(parts[1])
        #expect(project.arrangement?.sections[0].alternatives[0].approved == true)
        try Music.validate(project)
    }
}

@Test func rejectsPlansWithMissingPartsOrRepeatedIdeas() throws {
    let map = AudioMap(duration: 3, bpm: 112)
    let parts = SongStructure.passages(map)
    let hit = SoloIdea.Hit(step: 2, hold: 2, interval: 1, velocity: 76)
    let idea = SoloIdea(name: "Duplicado", intent: "Som", style: .rock, pickup: 0, figure: [hit, hit])
    #expect(throws: MusicError.self) {
        try SongStructure.realize(.init(amp: .lead, sections: []), map: map, passages: parts, preferences: Preferences())
    }
    #expect(throws: MusicError.self) {
        try SongStructure.realize(.init(amp: .lead, sections: [.init(index: 0, name: "Uma", options: [idea, idea, idea])]),
                                  map: map, passages: parts, preferences: Preferences())
    }
}

@Test func fullSectionScoreKeepsRestsMelodyAndArticulation() throws {
    let payload = """
    {"amp":"clean","sections":[{"index":0,"name":"Resposta","options":[
      {"style":"soul","name":"A","intent":"Tema e resposta","score":[[4,2,64,68,0],[8,8,67,80,1],[32,6,64,70,0],[39,9,65,87,6]]},
      {"style":"melodic","name":"B","intent":"Suspensão","score":[[10,12,60,75,0]]},
      {"style":"rock","name":"C","intent":"Final","score":[[36,10,62,88,2]]}
    ]}]}
    """
    let plan = try JSONDecoder().decode(ArrangementPlan.self, from: Data(payload.utf8))
    let map = AudioMap(duration: 8, bpm: 120, beatOffset: 0.25, meter: 3)
    let passage = Passage("Trecho", 0.21, 6.25)
    let grid = SectionGrid(map: map, passage: passage)
    #expect(grid.origin == 0.25 && grid.count == 48)
    var prefs = Preferences()
    prefs.level = .intermediate
    let parts = try SongStructure.realize(plan, map: map, passages: [passage], preferences: prefs)
    let phrase = try #require(parts.first?.phrase)
    #expect(phrase.events.map(\.time) == [0.75, 1.25, 4.25, 5.125])
    #expect(phrase.events.map(\.duration) == [0.25, 1, 0.75, 1.125])
    #expect(phrase.events.map(\.pitch) == [64, 67, 64, 65])
    #expect(phrase.events.map(\.technique) == [.picked, .vibrato, .picked, .bend])
    #expect(phrase.events.last?.amount == 2)
    #expect(phrase.active(at: 3) == nil)
    prefs.level = .beginner
    let basic = try grid.events([[39,9,65,87,6]], preferences: prefs)
    #expect(basic.first?.pitch == 67 && basic.first?.technique == .picked)
    for invalid in [[[46,4,60,70,0]], [[1,5,64,70,0],[4,3,62,72,0]], [[0,2,64]], [[0,2,127,72,0]]] {
        #expect(throws: MusicError.self) { try grid.events(invalid, preferences: prefs) }
    }
}

@Test func completeSolosRequireElevenFingeringsAfterRealization() throws {
    let map = AudioMap(duration: 32, bpm: 120)
    let passage = Passage("Música", 0, 32)
    func idea(_ distinct: Int) -> SoloIdea {
        var option = SoloIdea(name: "Tema de \(distinct)", intent: "Tema e resposta", style: .melodic, pickup: 0, figure: [])
        option.score = (0..<(distinct * 2)).map { i in [i * 4, 3, 55 + i % distinct, 75, 0] }
        return option
    }
    func compose(_ options: [SoloIdea]) throws -> SoloSection {
        let plan = ArrangementPlan(amp: .clean, sections: [.init(index: 0, name: "Solo", options: options)])
        return try #require(SongStructure.realize(plan, map: map, passages: [passage], preferences: Preferences(), featured: true).first)
    }
    #expect(throws: MusicError.noCompleteSolo) { try compose([idea(10)]) }
    let part = try compose([idea(10), idea(11)])
    #expect(part.alternatives.count == 1)
    #expect(part.phrase?.positionCount == 11)
    #expect(try compose([idea(11)]).phrase?.events.count == 22)

    var project = Project(name: "Anterior", sourceHash: String(repeating: "a", count: 64), map: map)
    var old = try #require(part.phrase)
    old.id = UUID()
    old.events = Array(old.events.prefix(4))
    var stored = part
    stored.alternatives.insert(old, at: 0)
    stored.selected = old.id
    project.arrangement = SoloArrangement(sections: [], level: .basic, model: "Teste")
    project.arrangement?.featured = stored
    project.activateSection(stored)
    let preferred = try #require(project.preferredLead)
    #expect(preferred.selected == part.selected)
    project.activateSection(preferred)
    project.saveSectionEdits()
    try Music.validate(project)
    #expect(project.alternatives.contains(old))
}

@Test func harmonicsAndCapoKeepTouchPointDistinctFromSoundingPitch() throws {
    let map = AudioMap(duration: 10, bpm: 120, key: Key(root: 4),
                       chords: [Chord(start: 0, end: 10, root: 4, minor: false, confidence: 1)])
    let grid = SectionGrid(map: map, passage: Passage("Solo", 0, 10))
    var prefs = Preferences()
    prefs.level = .intermediate
    for (fret, midi) in [(5, 64), (7, 59), (12, 52)] {
        let note = Event(time: 0, duration: 1, string: 5, fret: fret, velocity: 0.8, technique: .harmonic)
        #expect(note.pitch == midi && note.label == "<\(fret)>")
        let shifted = try #require(Music.fingering([note], semitones: 2, position: 5, level: .intermediate, capo: 2).first)
        #expect(shifted.pitch == midi + 2 && shifted.fret >= 2)
        #expect(shifted.label == "<\(shifted.fret - 2)>")
        try Music.validate([shifted], in: Passage("Solo", 0, 10), level: .intermediate)
        let planned = try #require(grid.events([[0,4,midi,80,7]], preferences: prefs).first)
        #expect(planned.technique == .harmonic && planned.pitch == midi)
    }
    var project = Project(name: "Mi", sourceHash: String(repeating: "a", count: 64), map: map)
    let options = project.capoOptions(transpose: 0)
    #expect(options.first { $0.fret == 2 }?.shapes == ["D"])
    #expect(options.first { $0.fret == 4 }?.shapes == ["C"])
    let low = Event(time: 0, duration: 1, string: 5, fret: 0, velocity: 0.8)
    project.alternatives = [Phrase(name: "Pedal", explanation: "", events: [low], level: .intermediate)]
    #expect(project.capoOptions(transpose: 0).map(\.fret) == [0])
    let playable = try #require(project.capoOptions(transpose: 2).first { $0.fret == 2 })
    #expect(playable.lowestMidi == 42 && playable.openNotes == 1)
    project.transpose = 2; project.capoFret = 2
    #expect(project.presentedKey == Key(root: 6) && project.shapeTranspose == 0)
    let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    try Music.validate(restored)
    #expect(restored == project)
}


@Test func expressiveScoreRetainsOffbeatAndResolvesOverlappingReleases() throws {
    let map = AudioMap(duration: 8, bpm: 120)
    let grid = SectionGrid(map: map, passage: Passage("Tema", 0, 8))
    let line = try grid.events([[0, 4, 60, 80, 0, 0], [4, 4, 62, 70, 0, -24], [8, 3, 64, 80, 0, 24]], preferences: Preferences())
    #expect(abs(line[1].time - 0.47) < 0.0001)
    #expect(abs(line[0].end - line[1].time) < 0.0001)
    #expect(abs(line[2].time - 1.03) < 0.0001)
    try Music.validate(line, in: Passage("Tema", 0, 8), level: .intermediate)
}

@Test func sustainedArrivalsAreComparedAcrossChordChanges() {
    let chords = [Chord(start: 0, end: 1, root: 0, minor: false, confidence: 1),
                  Chord(start: 1, end: 5, root: 2, minor: false, confidence: 1)]
    let map = AudioMap(duration: 5, bpm: 120, chords: chords)
    func phrase(_ fret: Int) -> Phrase {
        Phrase(name: "Chegada", explanation: "", events: [Event(time: 0.9, duration: 2, string: 1, fret: fret, velocity: 0.8)], level: .basic)
    }
    #expect(SongStructure.harmonicFit(phrase(3), map: map) > SongStructure.harmonicFit(phrase(1), map: map))
}
