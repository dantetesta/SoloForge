import AVFoundation
import Foundation
import MusicCore

enum ArrangementValidation {
    @MainActor static func run(_ args: [String], featured: Bool = false) throws {
        guard args.count == 2 || args.count == 3 else {
            throw WorkError.audio("Uso: --validate-arrangement GRAVAÇÃO PASTA [PLANO_JSON]")
        }
        let input = URL(fileURLWithPath: args[0])
        let output = URL(fileURLWithPath: args[1], isDirectory: true)
        let store = try Store(folder: output.appendingPathComponent("library"))
        let name = input.deletingPathExtension().lastPathComponent
        let analysisStart = Date()
        var project = try Importer.importAudio(input, name: name, store: store) { _ in }
        let passages = featured ? [Passage("Faixa", 0, project.map.duration)] : SongStructure.passages(project.map)
        struct Outline: Codable {
            struct Part: Codable { let start: Double; let end: Double; let chords: [String]; let vocal: [[Double]] }
            let duration: Double
            let bpm: Double
            let key: String
            let parts: [Part]
        }
        if args.count == 2 {
            let map = project.map
            let summary = Outline(duration: map.duration, bpm: map.bpm, key: map.key.label,
                                  parts: passages.map { passage in
                .init(start: passage.start, end: passage.end,
                      chords: map.chords.filter { $0.start < passage.end && $0.end > passage.start }.map(\.label),
                      vocal: (map.vocalHints ?? []).filter { $0.start < passage.end && $0.end > passage.start }.map {
                          [max(passage.start, $0.start), min(passage.end, $0.end), $0.confidence]
                      })
            })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(to: output.appendingPathComponent("map.json"), options: .atomic)
            print("duration=\(map.duration) sections=\(passages.count) map_ready=true")
            return
        }
        let plan = try JSONDecoder().decode(ArrangementPlan.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        project.preferences.level = .intermediate
        let startPlan = Date()
        let parts = try SongStructure.realize(plan, map: project.map, passages: passages, preferences: project.preferences, featured: featured)
        guard var first = parts.first, parts.allSatisfy({ featured ? (1...3).contains($0.alternatives.count) : $0.alternatives.count == 3 }) else { throw MusicError.invalidArrangement }
        first.alternatives[0].approved = true
        var preserved = parts
        preserved[0] = first
        project.arrangement = SoloArrangement(sections: featured ? [] : preserved, level: .intermediate, model: "Codex · plano de validação")
        if featured { project.arrangement?.featured = first }
        project.activateSection(first)
        project.ampPreset = plan.amp
        project.preferences.instrument = plan.amp.instrument
        project.tone = plan.amp.tone
        let selected = preserved.compactMap(\.phrase).flatMap(\.events)
        try Music.validate(selected, in: Passage("Sequência", 0, project.map.duration), level: .intermediate)
        let original = store.audio(for: project.id)
        let whisperStart = Date()
        if !featured {
            project.lyrics = try WhisperLocal.makeLyrics(recording: original, duration: project.map.duration) { _ in }
            let words = project.lyrics.flatMap { $0.words ?? [] }
            let labels = project.lyrics.map { LyricHarmony.align($0, project: project) }.flatMap { $0 }.flatMap(\.chords)
            guard !labels.isEmpty, !words.isEmpty, words.allSatisfy({ $0.start >= 0 && $0.end >= $0.start && $0.end <= project.map.duration }) else {
                throw WorkError.audio("A letra e as cifras não puderam ser alinhadas.")
            }
            project.chordSheet = true
        }
        let words = project.lyrics.flatMap { $0.words ?? [] }
        let labels = project.lyrics.flatMap { LyricHarmony.align($0, project: project) }.flatMap(\.chords)
        try store.save(project)
        let file = output.appendingPathComponent("Sequência.wav")
        let lead = try LeadRender.create(events: selected, project: project, to: output.appendingPathComponent("Solo.wav"))
        let arrangementTime = Date().timeIntervalSince(startPlan)
        let range = featured ? project.passage.start...project.passage.end : 0...project.map.duration
        try AudioExport.render(project: project, recording: original, lead: lead, range: range,
                               levels: MixLevels(project: project), to: file) { _ in }
        let mix = try AVAudioFile(forReading: file)
        guard abs(Double(mix.length) / AudioFiles.rate - (range.upperBound - range.lowerBound)) < 0.02 else { throw WorkError.files }
        let portable = output.appendingPathComponent(name + ".guitarproject")
        try store.export(project, to: portable)
        let imported = try Store(folder: output.appendingPathComponent("restore")).importPortable(portable) { _ in }
        var copy = imported; copy.id = project.id
        guard copy == project, copy.phrase?.approved == true else {
            throw MusicError.invalidProject
        }
        print(String(format: "duration=%.3fs parts=%d alternatives=%d selected_notes=%d verses=%d timed_words=%d chord_labels=%d",
                     project.map.duration, parts.count, parts.reduce(0) { $0 + $1.alternatives.count }, selected.count, project.lyrics.count, words.count, labels.count))
        print(String(format: "import=%.3fs prepared_and_rendered=%.3fs whisper_and_export=%.3fs exact_portable_roundtrip=true",
                     startPlan.timeIntervalSince(analysisStart), arrangementTime, Date().timeIntervalSince(whisperStart)))
    }
}
