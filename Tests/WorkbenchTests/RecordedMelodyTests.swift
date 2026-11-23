import AVFoundation
import Foundation
import MusicCore
import Testing
@testable import Workbench

@Test func recordedGuitarKeepsPitchesAbsoluteTimesAndSilentPassages() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Instruments/Electric")
    let track = folder.appendingPathComponent("recording.wav")
    let expected = [60, 66, 63, 69]
    let n = 44_100
    do {
        let output = try AudioFiles.writable(track)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 44_100 * 5))
        buffer.frameLength = buffer.frameCapacity
        for ch in 0..<2 { buffer.floatChannelData![ch].update(repeating: 0, count: n * 5) }
        for (index, midi) in expected.enumerated() {
            let input = try AVAudioFile(forReading: assets.appendingPathComponent("\(midi)-mf-1.wav"))
            let sample = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 44_100))
            try input.read(into: sample)
            let rate = input.processingFormat.sampleRate / 44_100
            for i in 0..<22_050 {
                let value = sample.floatChannelData![0][Int(Double(i) * rate)]
                let pos = n + index * 27_000 + i
                for ch in 0..<2 { buffer.floatChannelData![ch][pos] = value }
            }
        }
        try output.write(from: buffer)
    }
    let passage = Passage("Guitarra", 0.75, 4.5)
    let lines = try RecordedMelody.transcribe(track, passage: passage) { _ in }
    let notes = lines.flatMap(\.events)
    #expect(notes.map(\.pitch) == expected)
    for (index, note) in notes.enumerated() {
        #expect(abs(note.time - (1 + Double(index * 27_000) / 44_100)) < 0.12)
    }
    #expect(try RecordedMelody.transcribe(track, passage: Passage("Silêncio", 0, 0.75)) { _ in }.isEmpty)

    let map = AudioMap(duration: 5)
    let store = try Store(folder: folder)
    var project = Project(name: "Duas origens", sourceHash: String(repeating: "a", count: 64), map: map)
    var study = RecordingStudy(map: map, passage: passage, lines: lines, usedGuitarTrack: true)
    study.referenceSheet = "Am   G"
    project.recordingStudy = study
    project.alternatives = [Phrase(name: "Composição", explanation: "", events: [Event(time: 0, duration: 1, string: 0, fret: 3, velocity: 0.8)], level: .basic)]
    project.clearGeneratedMusic(includingLyrics: true)
    try store.save(project)
    #expect(try store.list().first?.recordingStudy == study)
}

@MainActor @Test func switchingBackToRecordingCancelsPendingStudyAudition() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(folder: root)
    let map = AudioMap(duration: 5)
    var project = Project(name: "Prévia", sourceHash: String(repeating: "b", count: 64), map: map)
    let line = Phrase(name: "Estudo", explanation: "", events: [
        Event(time: 2, duration: 1, string: 1, fret: 3, velocity: 0.8)
    ], level: .advanced)
    project.recordingStudy = RecordingStudy(map: map, passage: Passage("Trecho", 0, 5), lines: [line], usedGuitarTrack: false)
    try store.save(project)
    let recording = store.audio(for: project.id)
    try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        let file = try AudioFiles.writable(recording)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 220_500))
        buffer.frameLength = buffer.frameCapacity
        for ch in 0..<2 { buffer.floatChannelData![ch].update(repeating: 0, count: 220_500) }
        try file.write(from: buffer)
    }
    let session = Session(store: store)
    session.open(project)
    session.switchStudio(study: true)
    session.auditionStudyLine(line.id)
    #expect(session.studySoloID == line.id && session.studyRange == 2...3 && session.rendering)
    session.selectStudyRange(nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(session.studySoloID == nil && session.studyRange == nil)
    #expect(!session.playback && !session.rendering && session.notice == nil)
    #expect(session.current == project)
    session.home()
}

@Test func separatingMixedGuitarPreservesIrregularAttacksAccentsAndRests() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let input = folder.appendingPathComponent("mix.wav")
    let stem = folder.appendingPathComponent("guitar.wav")
    // Two attacks of the same pitch, varying loudness, an offbeat and a long rest.
    let score: [(pitch: Int, time: Double, length: Double, gain: Float)] = [
        (63, 2.07, 0.25, 0.8), (63, 2.47, 0.18, 0.38), (69, 2.76, 0.48, 0.9),
        (66, 3.43, 0.31, 0.65), (60, 3.98, 0.63, 0.86),
        (69, 5.48, 0.29, 0.61), (66, 5.89, 0.35, 0.77)
    ]
    do {
        let output = try AudioFiles.writable(input)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 441_000))
        buffer.frameLength = buffer.frameCapacity
        let channels = buffer.floatChannelData!
        for i in 0..<Int(buffer.frameLength) {
            let t = Double(i) / AudioFiles.rate
            let beat = t.truncatingRemainder(dividingBy: 0.41)
            let hz = [82.41, 98.0, 110.0, 87.31][Int(t / 0.82) % 4]
            let bass = 0.105 * sin(2 * .pi * hz * t) + 0.04 * sin(4 * .pi * hz * t)
            let kick = 0.19 * exp(-beat * 38) * sin(2 * .pi * 53 * beat)
            for ch in 0..<2 { channels[ch][i] = Float(bass * exp(-beat * 3) + kick) }
        }
        for note in score {
            let file = try AVAudioFile(forReading: root.appendingPathComponent("Instruments/Electric/\(note.pitch)-mf-1.wav"))
            let sample = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: sample)
            let ratio = file.processingFormat.sampleRate / AudioFiles.rate
            let n = Int(note.length * AudioFiles.rate)
            for i in 0..<n {
                let v = sample.floatChannelData![0][Int(Double(i) * ratio)] * note.gain * min(1, Float(n - i) / 240)
                let index = Int(note.time * AudioFiles.rate) + i
                channels[0][index] += v
                channels[1][index] += v * 0.7
            }
        }
        try output.write(from: buffer)
    }
    let range = Passage("Solo", 0.3, 8.1) // A última nota atravessa a emenda entre duas janelas de separação.
    try GuitarSeparation.isolate(input, passage: range, to: stem) { _ in }
    #expect(try AVAudioFile(forReading: stem).length == Int64(((range.end - range.start) * AudioFiles.rate).rounded()))
    let lines = try RecordedMelody.transcribe(stem, passage: range, audioOrigin: range.start, mix: input) { _ in }
    #expect(lines.contains { $0.uncertainStudyLine != true })
    let notes = lines.flatMap(\.events).sorted { $0.time < $1.time }
    print("Guitar timing", notes.map { String(format: "%d@%.3f+%.3f/v%.2f", $0.pitch, $0.time, $0.duration, $0.velocity) })
    #expect(notes.map(\.pitch) == score.map(\.pitch))
    for (note, reference) in zip(notes, score) {
        #expect(abs(note.time - reference.time) < 0.025)
        #expect(abs(note.end - reference.time - reference.length) < 0.04)
    }
    if notes.count == score.count { #expect(notes[0].velocity > notes[1].velocity) }
}


@Test func studyVibratoRequiresRepeatedPitchOscillation() {
    let phase = 2 * Double.pi * 6.0 / 86.0
    let vibrato: [Float] = (0..<65).map { Float(0.24 * sin(Double($0) * phase)) }
    #expect(RecordedMelody.hasVibrato(vibrato))
    #expect(!RecordedMelody.hasVibrato(vibrato.sorted()))
    #expect(!RecordedMelody.hasVibrato(vibrato.map { $0 * 0.2 }))
}
