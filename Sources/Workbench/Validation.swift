import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import MusicCore

enum Validation {
    private enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? {
            switch self { case .check(let message): "Validação · \(message)" }
        }
    }

    @MainActor static func run(_ args: [String]) throws {
        guard args.count >= 2 else { throw Failure.check("Uso: --validate /arquivo.mp3 /pasta-de-teste [--no-video] [--play]") }
        let input = URL(fileURLWithPath: args[0])
        let output = URL(fileURLWithPath: args[1], isDirectory: true)
        let library = output.appendingPathComponent("library", isDirectory: true)
        let store = try Store(folder: library)
        let initial = Date()
        var project = try Importer.importAudio(input, name: "Validação de áudio", store: store) { _ in }
        let importSeconds = Date().timeIntervalSince(initial)
        let before = project.map
        let minimum = min(project.map.duration * 0.12, 2.0)
        project.passage = Passage("Trecho de validação", minimum, min(project.map.duration, minimum + 8.0))
        project.map.beatOffset = min(project.map.duration, before.beatOffset + 0.012)
        project.map.bpm = (before.bpm + 0.25).rounded(.toNearestOrEven)
        if !project.map.chords.isEmpty {
            project.map.chords[0].confidence = 1
        }
        project.preferences.level = .intermediate
        project.preferences.mood = .energetic
        project.preferences.instrument = args.contains("--acoustic") ? .acoustic : args.contains("--driven") ? .driven : .clean
        project.tone = Tone.suggested(project.preferences.instrument)
        if args.contains("--blues") { project.preferences.genre = .blues }
        project.alternatives = try Music.generate(map: project.map, passage: project.passage, preferences: project.preferences, variation: 4)
        project.selected = project.alternatives.first?.id
        project.alternatives[0].approved = true
        project.chordSheet = true
        try store.save(project)
        try require(try Store(folder: library).list().first == project, "A reabertura SQLite alterou os dados.")
        try store.setRemoved(project, true)
        try require(try Store(folder: library).list().allSatisfy { $0.id != project.id }, "O projeto removido continuou na lista principal.")
        try require(try Store(folder: library).list(removed: true).first == project, "Os dados do projeto removido não foram preservados.")
        try store.setRemoved(project, false)
        try require(try store.list().first == project, "O projeto não foi restaurado.")
        let events = Session.presentedEvents(project)
        try require(project.alternatives.count == 3 && !events.isEmpty, "Quantidade de propostas inválida.")
        let original = store.audio(for: project.id)
        let lead = try LeadRender.create(events: events, project: project, to: output.appendingPathComponent("lead-reference.wav"))
        let levels = MixLevels(project: project)
        var choices = ExportOptions()
        choices.includeChords = true
        choices.height = 540
        let kinds: [ExportKind] = [.pdf, .solo, .mix, .project] + (args.contains("--no-video") ? [] : [.video])
        let exportStart = Date()
        for kind in kinds {
            let file = output.appendingPathComponent("study-\(kind).\(kind.ext)")
            try Exporter.export(kind, project: project, events: events, recording: original, levels: levels,
                                options: choices, library: library, to: file) { _ in }
            if kind != .project {
                let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                try require((bytes ?? 0) > 100, "Arquivo exportado vazio: \(kind).")
            }
            if kind == .pdf {
                try require((CGPDFDocument(file as CFURL)?.numberOfPages ?? 0) > 0, "PDF ilegível.")
            }
        }
        let backup = output.appendingPathComponent("study-project.guitarproject")
        let restored = try Store(folder: output.appendingPathComponent("restored")).importPortable(backup) { _ in }
        var comparable = restored
        comparable.id = project.id
        try require(comparable == project, "A cópia portátil alterou notas, escolhas ou análise.")
        let soloURL = output.appendingPathComponent("study-solo.wav")
        let mixedURL = output.appendingPathComponent("study-mix.wav")
        let sync = try verifySamples(project: project, events: events, original: original, soloURL: soloURL, mixedURL: mixedURL)
        var band = project
        band.transpose = 2
        let shifted = Session.presentedEvents(band)
        try require(zip(shifted, events).allSatisfy { $0.pitch == $1.pitch + 2 && $0.time == $1.time } && shifted.count == events.count,
                    "A transposição alterou o relógio ou a afinação.")
        try require(MixLevels(project: band).music == 0, "A gravação original continuou audível em modo banda.")
        band.transposeRecording = true
        try Exporter.export(.mix, project: band, events: shifted, recording: original, levels: MixLevels(project: band),
                            options: choices, library: library, to: output.appendingPathComponent("study-transposed.wav")) { _ in }
        let transposed = try AVAudioFile(forReading: output.appendingPathComponent("study-transposed.wav"))
        try require(transposed.length > 0, "Mixagem transposta sem amostras.")
        print(String(format: "import=%.3fs duration=%.3fs tempo=%.2f hypotheses=%d alternatives=%d notes=%d exports=%.3fs",
                     importSeconds, project.map.duration, before.bpm, before.chords.count,
                     project.alternatives.count, events.count, Date().timeIntervalSince(exportStart)))
        print(String(format: "note_onset_max=%.3fms max_mix_error=%.7f pitch_checks=%d max_pitch_error=%.2fct exact_project_roundtrip=true restore=true",
                     sync.delay * 1_000, sync.error, sync.measured, sync.cents))
        if args.contains("--play") { try testTransport(project: project, events: events, original: original, lead: lead) }
        var resource = rusage()
        if getrusage(RUSAGE_SELF, &resource) == 0 {
            print(String(format: "peak_rss=%.2fMiB", Double(resource.ru_maxrss) / 1_048_576))
        }
    }

    private static func require(_ test: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try test() else { throw Failure.check(message) }
    }

    private static func samples(_ file: AVAudioFile, at frame: Int64, count: AVAudioFrameCount) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        file.framePosition = frame
        try file.read(into: buffer, frameCount: count)
        guard let channel = buffer.floatChannelData?[0] else { throw Failure.check("Formato de amostras inesperado.") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func verifySamples(project: Project, events: [Event], original: URL, soloURL: URL,
                                      mixedURL: URL) throws -> (delay: Double, error: Double, measured: Int, cents: Double) {
        let backing = try AVAudioFile(forReading: original)
        let solo = try AVAudioFile(forReading: soloURL)
        let mix = try AVAudioFile(forReading: mixedURL)
        let dry = project
        let levels = MixLevels(project: dry)
        let offset = Int64((project.passage.start * AudioFiles.rate).rounded())
        var maxError: Float = 0
        var maximumDelay = 0.0
        var maxPitchError = 0.0
        var measured = 0
        let dryURL = soloURL.deletingLastPathComponent().appendingPathComponent("timing-reference.wav")
        var clean = project
        clean.tone.room = 0; clean.tone.delay = 0
        let isolated = try LeadRender.create(events: events, project: clean, to: dryURL)
        let dryFile = try AVAudioFile(forReading: dryURL)
        for event in events {
            let absolute = Int64((event.time * AudioFiles.rate).rounded())
            let relative = absolute - offset
            let dryFrame = absolute - isolated.offset
            let musicalSamples = try samples(backing, at: absolute, count: 1_024)
            let soloSamples = try samples(solo, at: relative, count: 1_024)
            let mixSamples = try samples(mix, at: relative, count: 1_024)
            try require((soloSamples.map(abs).max() ?? 0) > 0.012, "Uma nota da tab ficou inaudível no WAV do solo.")
            for index in 0..<min(musicalSamples.count, soloSamples.count, mixSamples.count) {
                let expected = min(0.99, max(-0.99, musicalSamples[index] * Float(levels.music * 0.85) + soloSamples[index]))
                maxError = max(maxError, abs(expected - mixSamples[index]))
            }
            let ramp = try samples(dryFile, at: dryFrame, count: 540)
            let heardAt = try requireIndex(ramp.firstIndex { abs($0) >= 0.012 })
            maximumDelay = max(maximumDelay, Double(heardAt) / AudioFiles.rate)
            if [.picked, .hammer].contains(event.technique), event.duration >= 0.11, project.preferences.instrument == .clean {
                let startingFrame = dryFrame + Int64(0.032 * AudioFiles.rate)
                let sample = try samples(dryFile, at: startingFrame, count: 2_600)
                if let frequency = fundamental(sample) {
                    let midi = 69 + 12 * log2(frequency / 440)
                    maxPitchError = max(maxPitchError, abs(midi - Double(event.pitch)) * 100)
                    measured += 1
                }
            }
        }
        try require(maxError < 0.00015, "A exportação deslocou ou alterou os stems (\(maxError)).")
        try require(maximumDelay < 0.012, "Ataque inicial fora da janela de 12 ms.")
        try require(project.preferences.instrument != .clean || (measured > 0 && maxPitchError < 65), "A afinação amostrada divergiu da tablatura (\(maxPitchError) centésimos de semitom).")
        return (maximumDelay, Double(maxError), measured, maxPitchError)
    }

    private static func fundamental(_ signal: [Float]) -> Double? {
        guard signal.count >= 1_300 else { return nil }
        let maximumLag = 530
        let n = min(signal.count - maximumLag, 1_900)
        var normalized = Array(repeating: 0.0, count: maximumLag + 1)
        var running = 0.0
        for lag in 1...maximumLag {
            var squared: Float = 0
            for i in 0..<n {
                let delta = signal[i] - signal[i + lag]
                squared += delta * delta
            }
            running += Double(squared)
            normalized[lag] = running > 0 ? Double(squared) * Double(lag) / running : 1
        }
        guard let lag = (45..<maximumLag).first(where: {
            normalized[$0] <= 0.22 && normalized[$0] < normalized[$0 - 1] && normalized[$0] <= normalized[$0 + 1]
        }) else { return nil }
        let center = normalized[lag], left = normalized[lag - 1], right = normalized[lag + 1]
        let slope = 2 * (left - 2 * center + right)
        let refined = Double(lag) + (abs(slope) < 0.000001 ? 0 : (left - right) / slope)
        return AudioFiles.rate / refined
    }

    private static func requireIndex(_ index: Int?) throws -> Int {
        guard let index else { throw Failure.check("O ataque de uma nota não apareceu.") }
        return index
    }

    @MainActor private static func testTransport(project: Project, events: [Event], original: URL, lead: LeadRender) throws {
        guard let first = events.first, let last = events.last else { throw WorkError.selectPhrase }
        let transport = Transport()
        try transport.load(recording: original); try transport.load(lead: lead)
        var checked = Set<UUID>()
        for rate in [1.0, 0.65] {
            transport.configure(levels: MixLevels(project: project), rate: rate, semitones: 0)
            try transport.play(from: max(project.passage.start, first.time - 0.3), until: last.end)
            let timeout = Date().addingTimeInterval((last.end - first.time + 1.6) / rate)
            var previous = transport.position
            while transport.playing && Date() < timeout {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.010))
                _ = transport.update()
                try require(transport.position >= previous - 0.001, "Relógio da reprodução voltou durante o play.")
                previous = transport.position
                if let note = project.phrase?.active(at: transport.position) { checked.insert(note.id) }
            }
            try require(!transport.playing, "A saída de áudio não encerrou no ponto B.")
        }
        try require(checked.count == events.count, "Relógio não destacou todas as notas.")
        transport.seek(first.time)
        try require(abs(transport.position - first.time) < 0.00001, "Busca perdeu posição.")
        print("device_playback_rates=1.00,0.65 clock_notes=\(checked.count) seek=true end_boundary=true")
    }
}
