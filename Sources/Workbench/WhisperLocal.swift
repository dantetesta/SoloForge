import Foundation
import MusicCore

enum WhisperLocal {
    static let modelPreference = "whisperModelFile"
    private struct Offsets: Decodable { let from: Int; let to: Int }
    private struct Token: Decodable {
        let text: String
        let id: Int
        let offsets: Offsets
    }
    private struct Segment: Decodable {
        let text: String
        let offsets: Offsets
        let tokens: [Token]?
    }
    private struct Transcript: Decodable { let transcription: [Segment] }

    static var modelURL: URL? {
        let selected = UserDefaults.standard.string(forKey: modelPreference)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Application Support")
        let defaults = [
            base.appendingPathComponent("SoloForgeCommunity/Models/ggml-large-v3-turbo.bin"),
            base.appendingPathComponent("SoloForgeCommunity/Models/ggml-small.bin"),
            base.appendingPathComponent("SoloForgeCommunity/Models/ggml-base.bin"),
        ]
        let candidates = selected.map { [URL(fileURLWithPath: $0)] } ?? defaults
        return candidates.first { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 40_000_000 && FileManager.default.isReadableFile(atPath: url.path)
        }
    }

    static func makeLyrics(recording: URL, duration: Double, progress: (Double) -> Void) throws -> [Lyric] {
        guard let cli = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first(where: FileManager.default.isExecutableFile),
              let ffmpeg = AudioFiles.ffmpeg else {
            throw WorkError.audio("Para gerar a letra localmente, instale whisper.cpp e FFmpeg e reabra o app.")
        }
        guard let model = modelURL else { throw WorkError.audio("Escolha um modelo Whisper multilíngue .bin em Preferências.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-timing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("voice.wav")
        let output = directory.appendingPathComponent("timed")
        let converter = try MediaProcess.start(ffmpeg, ["-i", recording.path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", input.path])
        try MediaProcess.finish(converter, message: "Falha ao preparar o áudio para o Whisper.")
        progress(0.18)

        let job = Process()
        job.executableURL = URL(fileURLWithPath: cli)
        job.arguments = ["-m", model.path, "-l", "auto", "-t", "4", "-ng", "-ojf", "-of", output.path, "-f", input.path]
        job.standardInput = FileHandle.nullDevice
        job.standardOutput = FileHandle.nullDevice
        job.standardError = FileHandle.nullDevice
        try job.run()
        try MediaProcess.finish(job, message: "O Whisper local não conseguiu transcrever esta faixa.")
        progress(0.91)
        let result = try parse(Data(contentsOf: output.appendingPathExtension("json")), duration: duration)
        guard !result.isEmpty else { throw WorkError.audio("O Whisper não encontrou versos nesta faixa.") }
        progress(1)
        return result
    }

    static func parse(_ data: Data, duration: Double) throws -> [Lyric] {
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)
        return transcript.transcription.flatMap { segment -> [Lyric] in
            let clean = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || ["[", "(", "♪", "【"].contains(where: { clean.hasPrefix($0) }) { return [] }
            let start = min(duration, max(0, Double(segment.offsets.from) / 1_000))
            let end = min(duration, max(start, Double(segment.offsets.to) / 1_000))
            let tokens = (segment.tokens ?? []).filter { $0.id < 50_257 }
            var words: [TimedWord] = []
            for token in tokens {
                let raw = token.text
                let pieces = raw.split(whereSeparator: \.isWhitespace)
                guard !pieces.isEmpty else { continue }
                let a = min(end, max(start, Double(token.offsets.from) / 1_000))
                let b = min(end, max(a, Double(token.offsets.to) / 1_000))
                for (i, piece) in pieces.enumerated() {
                    let from = a + (b - a) * Double(i) / Double(pieces.count)
                    let to = a + (b - a) * Double(i + 1) / Double(pieces.count)
                    if i == 0, raw.first?.isWhitespace != true, !words.isEmpty {
                        words[words.count - 1].text += String(piece)
                        words[words.count - 1].end = max(words[words.count - 1].end, to)
                    } else {
                        let normalized = max(words.last?.start ?? start, from)
                        words.append(TimedWord(start: normalized, end: max(normalized, to), text: String(piece)))
                    }
                }
            }
            if words.isEmpty {
                let pieces = clean.split(whereSeparator: \.isWhitespace)
                words = pieces.enumerated().map { i, word in
                    let period = (end - start) / Double(max(1, pieces.count))
                    return TimedWord(start: start + Double(i) * period, end: start + Double(i + 1) * period, text: String(word))
                }
            }
            return stride(from: 0, to: words.count, by: 9).map { index in
                let batch = Array(words[index..<min(words.count, index + 9)])
                return Lyric(time: batch.first?.start ?? start, text: batch.map(\.text).joined(separator: " "), words: batch)
            }
        }.prefix(5_000).map { $0 }
    }
}

enum LyricHarmony {
    struct Label {
        let word: TimedWord
        var chords: [String] = []
    }

    static func align(_ lyric: Lyric, project: Project) -> [Label] {
        let words = lyric.words ?? lyric.text.split(whereSeparator: \.isWhitespace).enumerated().map { index, value in
            TimedWord(start: lyric.time + Double(index) * 0.28, end: lyric.time + Double(index + 1) * 0.28, text: String(value))
        }
        var tokens = words.map { Label(word: $0) }
        guard let first = words.first, let last = words.last else { return [] }
        let relevant = project.map.chords.filter { $0.end > first.start && $0.start <= last.end && $0.confidence >= 0.12 }
        for chord in relevant {
            let required = max(chord.start, first.start)
            let slot = tokens.indices.min(by: { abs(tokens[$0].word.start - required) < abs(tokens[$1].word.start - required) }) ?? 0
            let name = pitchNames[pitchClass(chord.root + project.shapeTranspose)] + chord.quality.suffix
            if tokens[slot].chords.last != name { tokens[slot].chords.append(name) }
        }
        return tokens
    }
}
