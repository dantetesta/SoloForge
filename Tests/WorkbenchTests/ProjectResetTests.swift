import AVFoundation
import Foundation
import MusicCore
import Testing
@testable import Workbench

@MainActor @Test func resetOnlyClearsTheOpenSongAndUndoRestoresIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(folder: root)
    let map = AudioMap(duration: 4, bpm: 104)
    var project = Project(name: "Estudo", sourceHash: String(repeating: "a", count: 64), map: map)
    var phrase = Phrase(name: "Anterior", explanation: "Tema", events: [
        Event(time: 1, duration: 1, string: 0, fret: 5, velocity: 0.7)
    ], level: .basic)
    phrase.approved = true
    let section = SoloSection(passage: Passage("Parte", 0, 4), alternatives: [phrase], selected: phrase.id)
    project.arrangement = SoloArrangement(sections: [section], level: .basic, model: "Teste", usage: "Geração anterior")
    project.arrangement?.featured = SoloSection(passage: Passage("Solos", 0, 4), alternatives: [phrase], selected: phrase.id)
    project.activateSection(section)
    project.chordSheet = true
    project.lyrics = [Lyric(time: 0, text: "Edição do músico")]
    try store.save(project)
    var other = project
    other.id = UUID()
    try store.save(other)
    let recording = store.audio(for: project.id)
    try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: recording, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 4))
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
    }
    let source = try Data(contentsOf: recording)
    let session = Session(store: store)
    session.open(project)
    #expect(!session.resetGeneratedMusic(projectID: other.id, includingLyrics: true))
    for lyrics in [false, true] {
        #expect(session.resetGeneratedMusic(projectID: project.id, includingLyrics: lyrics))
        let cleared = try #require(session.current)
        #expect(!cleared.hasGeneratedSolos && cleared.selected == nil && cleared.activeSection == nil)
        #expect(cleared.hasLyricsOrChords == !lyrics)
        #expect(cleared.map == map && session.clock.time == 0 && session.usage == nil)
        let saved = try Store(folder: root).list()
        #expect(saved.contains(cleared) && saved.contains(other))
        #expect(try Data(contentsOf: recording) == source)
        session.undo()
        #expect(session.current == project && session.usage == "Geração anterior")
        #expect(try store.list().contains(project))
    }
    session.home()
}

@Test func permanentRemovalTargetsOnlyTheRemovedIDAndSurvivesReopen() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(folder: root.appendingPathComponent("library"))
    let otherWindow = try Store(folder: store.folder)
    let map = AudioMap(duration: 5)
    let first = Project(name: "Mesma música", sourceHash: String(repeating: "a", count: 64), map: map)
    var copy = first
    copy.id = UUID()
    let external = root.appendingPathComponent("original.wav")
    let sample = Data([4, 2])
    try sample.write(to: external)
    for project in [first, copy] {
        try store.save(project)
        let audio = store.audio(for: project.id)
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sample.write(to: audio)
        try store.setRemoved(project, true)
    }
    try store.cache(map, hash: first.sourceHash)
    try otherWindow.setRemoved(first, false)
    #expect(throws: WorkError.self) { try store.deleteRemovedProject(first.id) }
    try store.setRemoved(first, true)
    try store.deleteRemovedProject(first.id)
    try store.deleteRemovedProject(first.id)
    #expect(try Store(folder: store.folder).list(removed: true) == [copy])
    #expect(!FileManager.default.fileExists(atPath: store.audio(for: first.id).deletingLastPathComponent().path))
    #expect(try Data(contentsOf: store.audio(for: copy.id)) == sample)
    #expect(try store.cached(first.sourceHash) == map)
    #expect(throws: WorkError.self) { try otherWindow.save(first) }
    try store.deleteRemovedProject(copy.id)
    #expect(try otherWindow.list().isEmpty && otherWindow.list(removed: true).isEmpty)
    #expect(try store.cached(first.sourceHash) == nil)
    #expect(try Data(contentsOf: external) == sample)
}
