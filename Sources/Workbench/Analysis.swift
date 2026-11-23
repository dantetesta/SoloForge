import Accelerate
import AudioToolbox
import AVFoundation
import Foundation
import MusicCore

enum AudioFiles {
    static let rate = 44_100.0
    static var ffmpeg: String? { ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile) }
    static var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)! }
    static func writable(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
        ])
    }
    static func decode(_ source: URL, to destination: URL, progress: (Double) -> Void) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let expected = Double(input.length) / input.processingFormat.sampleRate
        guard (1...21_600).contains(expected) else { throw WorkError.audio("A faixa precisa ter entre 1 segundo e 6 horas.") }
        do {
            return try decodeNative(input, expected: expected, to: destination, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let ffmpeg else {
                throw WorkError.audio("O Core Audio não decodificou este arquivo. Instale FFmpeg ou use WAV PCM. \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: destination)
            return try decodeFallback(ffmpeg, source: source, to: destination, expected: expected, progress: progress)
        }
    }

    private static func decodeNative(_ input: AVAudioFile, expected: Double, to destination: URL, progress: (Double) -> Void) throws -> Double {
        let target = format
        guard let converter = AVAudioConverter(from: input.processingFormat, to: target),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384),
              let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else {
            throw WorkError.audio("Não foi possível preparar a conversão do áudio.")
        }
        if input.processingFormat.channelCount == 1 { converter.channelMap = [0, 0] }
        let output = try writable(destination)
        var total = 0.0
        var readFailure: Error?
        let inputLength = input.length
        while true {
            try Task.checkCancellation()
            var failure: NSError?
            buffer.frameLength = 0
            let status = converter.convert(to: buffer, error: &failure) { requested, state in
                let available = inputLength - input.framePosition
                if available <= 0 || requested == 0 {
                    state.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: sourceBuffer, frameCount: AVAudioFrameCount(min(Int64(requested), Int64(sourceBuffer.frameCapacity), available)))
                    state.pointee = sourceBuffer.frameLength > 0 ? .haveData : .endOfStream
                    return sourceBuffer.frameLength > 0 ? sourceBuffer : nil
                } catch {
                    readFailure = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readFailure { throw readFailure }
            if status == .error { throw failure ?? WorkError.audio("Falha na conversão do áudio.") as NSError }
            if buffer.frameLength > 0 {
                try output.write(from: buffer)
                total += Double(buffer.frameLength)
                progress(min(1, total / (expected * rate)))
            }
            if status == .endOfStream { break }
            if buffer.frameLength == 0 { throw WorkError.audio("A conversão encerrou antes de entregar as amostras.") }
        }
        let duration = total / rate
        guard duration >= 1 else { throw WorkError.audio("O áudio decodificado é curto demais.") }
        return duration
    }

    private static func decodeFallback(_ ffmpeg: String, source: URL, to destination: URL, expected: Double,
                                       progress: (Double) -> Void) throws -> Double {
        let job = Process()
        job.executableURL = URL(fileURLWithPath: ffmpeg)
        job.arguments = ["-nostdin", "-v", "error", "-y", "-i", source.path, "-map", "0:a:0", "-vn", "-sn", "-dn",
                         "-t", "21600", "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le", destination.path]
        job.standardInput = FileHandle.nullDevice
        job.standardOutput = FileHandle.nullDevice
        job.standardError = FileHandle.nullDevice
        try job.run()
        while job.isRunning {
            if Task.isCancelled {
                job.terminate()
                job.waitUntilExit()
                throw CancellationError()
            }
            let written = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            progress(min(0.99, Double(written) / (expected * rate * 4)))
            Thread.sleep(forTimeInterval: 0.035)
        }
        guard job.terminationStatus == 0 else { throw WorkError.audio("O áudio também não pôde ser lido pelo FFmpeg local.") }
        let decoded = try AVAudioFile(forReading: destination)
        let duration = Double(decoded.length) / rate
        guard duration >= 1 else { throw WorkError.audio("O áudio decodificado é curto demais.") }
        progress(1)
        return duration
    }
}

enum Analyzer {
    private struct Observation {
        var time: Double
        var chroma: [Double]
        var energy: Double
        var flux: Double
    }

    static func analyze(_ url: URL, progress: (Double) -> Void) throws -> AudioMap {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / AudioFiles.rate
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)!
        let n = 2_048
        let targetRate = AudioFiles.rate / 4
        let hop = 512
        let logLength = vDSP_Length(11)
        guard let fft = vDSP_create_fftsetup(logLength, FFTRadix(kFFTRadix2)) else { throw WorkError.audio("Falha ao iniciar a análise espectral.") }
        defer { vDSP_destroy_fftsetup(fft) }

        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n - 1))) }
        let bins = (7..<min(n / 2, 460)).compactMap { index -> (Int, Int, Double)? in
            let hz = Double(index) * targetRate / Double(n)
            let midi = 69 + 12 * log2(hz / 440)
            let rounded = midi.rounded()
            guard abs(midi - rounded) < 0.40 else { return nil }
            let weight = (1 - abs(midi - rounded) * 1.65) / pow(max(1, hz / 190), 0.34)
            return (index, pitchClass(Int(rounded)), weight)
        }
        var ring = Array(repeating: Float(0), count: n)
        var real = ring, imaginary = ring
        var levels = Array(repeating: Double(0), count: n / 2)
        var previous = levels
        var waveform = Array(repeating: Float(0), count: 1_200)
        var observations: [Observation] = []
        var onsets: [Float] = []
        var harmonic = Array(repeating: 0.0, count: 12)
        var totalFrames = 0
        var index = 0
        var count = 0
        var decimation: Float = 0
        var energy = 0.0
        var bucketFlux = 0.0
        var bucketCount = 0
        let observationHops = max(6, Int(ceil(duration / 6_000 * targetRate / Double(hop))))
        let endLimit = Int(file.length)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { throw WorkError.audio("Formato PCM não suportado.") }
            for frame in 0..<frames {
                let left = channels[0][frame], right = channels[1][frame]
                let bucket = min(waveform.count - 1, totalFrames * waveform.count / endLimit)
                waveform[bucket] = max(waveform[bucket], min(1, max(abs(left), abs(right))))
                decimation += (left + right) * 0.125
                totalFrames += 1
                guard totalFrames.isMultiple(of: 4) else { continue }
                ring[index] = decimation
                decimation = 0
                index = (index + 1) & (n - 1)
                count += 1
                guard count >= n, count.isMultiple(of: hop) else { continue }
                var sum = 0.0
                for sample in 0..<n {
                    let value = ring[(index + sample) & (n - 1)]
                    real[sample] = value * window[sample]
                    imaginary[sample] = 0
                    sum += Double(value * value)
                }
                real.withUnsafeMutableBufferPointer { re in
                    imaginary.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_fft_zip(fft, &split, 1, logLength, FFTDirection(FFT_FORWARD))
                    }
                }
                var flux = 0.0
                for k in 3..<levels.count {
                    let amplitude = hypot(Double(real[k]), Double(imaginary[k]))
                    let scaled = log1p(amplitude)
                    levels[k] = amplitude
                    flux += max(0, scaled - previous[k])
                    previous[k] = scaled
                }
                if onsets.count < 25_000 { onsets.append(Float(flux)) }
                energy += sqrt(sum / Double(n))
                bucketFlux += flux
                bucketCount += 1
                if sum > 0.0001 {
                    for (k, tone, weight) in bins where levels[k] >= levels[k - 1] && levels[k] >= levels[k + 1] {
                        harmonic[tone] += pow(levels[k], 0.72) * weight
                    }
                }
                if bucketCount == observationHops || (totalFrames + 4 * hop >= endLimit && bucketCount > 0) {
                    observations.append(Observation(time: max(0, (Double(count) - Double(n) / 2) / targetRate),
                                                    chroma: normalized(harmonic), energy: energy / Double(bucketCount),
                                                    flux: bucketFlux / Double(bucketCount)))
                    harmonic = Array(repeating: 0, count: 12)
                    bucketCount = 0; energy = 0; bucketFlux = 0
                }
            }
            progress(Double(totalFrames) / Double(endLimit))
        }
        let pulse = tempo(onsets, step: Double(hop) / targetRate)
        let global = observations.reduce(into: Array(repeating: 0.0, count: 12)) { acc, frame in
            for i in 0..<12 { acc[i] += frame.chroma[i] * frame.energy }
        }
        let key = keyHypothesis(normalized(global))
        let bar = 240 / pulse.bpm
        var chords: [Chord] = []
        let chordWindow = max(bar, duration / 700)
        var start = 0.0
        var nextObservation = 0
        while start < duration - 0.001 {
            let end = min(duration, start + chordWindow)
            var local = Array(repeating: 0.0, count: 12)
            while nextObservation < observations.count && observations[nextObservation].time < end {
                let frame = observations[nextObservation]
                for i in 0..<12 { local[i] += frame.chroma[i] * frame.energy }
                nextObservation += 1
            }
            let ranked = roots(normalized(local))
            let best = ranked[0]
            let confidence = min(0.75, max(0, (best.2 - ranked[1].2) * 3.6))
            if let last = chords.last, last.root == best.0, last.quality == (best.1 ? .minor : .major) {
                chords[chords.count - 1].end = end
                chords[chords.count - 1].confidence = (last.confidence + confidence) / 2
            } else {
                chords.append(Chord(start: start, end: end, root: best.0, minor: best.1, confidence: confidence))
            }
            start = end
        }
        var result = AudioMap(duration: duration, waveform: waveform, bpm: pulse.bpm, beatOffset: min(duration, pulse.offset),
                        meter: 4, key: key.0, keyConfidence: key.1, tempoConfidence: pulse.confidence,
                        chords: chords, sections: sections(observations, duration: duration, bar: bar))
        result.globalChroma = normalized(global)
        return result
    }

    private static func normalized(_ source: [Double]) -> [Double] {
        let sum = source.reduce(0, +)
        return sum > 0.00001 ? source.map { $0 / sum } : source
    }

    private static func roots(_ chroma: [Double]) -> [(Int, Bool, Double)] {
        (0..<12).flatMap { root in
            [false, true].map { minor in
                (root, minor, chroma[root] * 1.20 + chroma[(root + (minor ? 3 : 4)) % 12] + chroma[(root + 7) % 12] * 0.92)
            }
        }.sorted { $0.2 > $1.2 }
    }

    private static func keyHypothesis(_ chroma: [Double]) -> (Key, Double) {
        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        let ranked = (0..<12).flatMap { root in
            [false, true].map { isMinor in
                let template = isMinor ? minor : major
                let score = (0..<12).reduce(0.0) { $0 + chroma[(root + $1) % 12] * template[$1] }
                return (Key(root: root, minor: isMinor), score)
            }
        }.sorted { $0.1 > $1.1 }
        return (ranked[0].0, min(0.82, (ranked[0].1 - ranked[1].1) * 2.3))
    }

    private static func tempo(_ source: [Float], step: Double) -> (bpm: Double, offset: Double, confidence: Double) {
        guard source.count > 64 else { return (100, 0, 0) }
        let average = source.reduce(0, +) / Float(source.count)
        let levels = source.map { max(0, $0 - average * 0.72) }
        let energy = levels.reduce(0.00001) { $0 + $1 * $1 }
        guard energy > 0.01 else { return (100, 0, 0) }
        let lower = Int(60 / 184 / step), upper = Int(60 / 57 / step)
        let ranks = (lower...upper).map { lag -> (Int, Double) in
            var dot: Float = 0
            for i in lag..<levels.count { dot += levels[i] * levels[i - lag] }
            let bpm = 60 / (Double(lag) * step)
            return (lag, Double(dot / energy) * (1 - abs(log2(bpm / 108)) * 0.16))
        }
        let best = ranks.max { $0.1 < $1.1 }!
        let alternative = ranks.filter { abs($0.0 - best.0) > 1 }.map { $0.1 }.max() ?? 0
        var phase = Array(repeating: Float(0), count: best.0 * 4)
        for (i, value) in levels.enumerated() { phase[i % phase.count] += value }
        let peak = phase.indices.max { phase[$0] < phase[$1] } ?? 0
        let confidence = min(0.80, max(0, best.1 * 0.45 + (best.1 - alternative) * 2.3))
        return (60 / (Double(best.0) * step), max(0, Double(peak) * step + 0.046), confidence)
    }

    private static func sections(_ frames: [Observation], duration: Double, bar: Double) -> [Passage] {
        guard duration > 14 else { return [Passage("Faixa inteira", 0, duration)] }
        let spacing = max(7, duration / 11)
        var boundaries = [0.0]
        for i in 1..<frames.count {
            let before = frames[i - 1], after = frames[i]
            let harmonic = zip(before.chroma, after.chroma).reduce(0.0) { $0 + abs($1.0 - $1.1) }
            let dynamics = abs(log((after.energy + 0.01) / (before.energy + 0.01)))
            if after.time - boundaries.last! > spacing && duration - after.time > bar && (harmonic + dynamics > 0.76 || after.time - boundaries.last! > spacing * 1.8) {
                boundaries.append(after.time)
            }
        }
        boundaries.append(duration)
        return boundaries.indices.dropLast().map { i in
            let label = i == 0 ? "Abertura provável" : i == boundaries.count - 2 ? "Final provável" : "Seção \(i + 1)"
            return Passage(label, boundaries[i], boundaries[i + 1])
        }
    }
}
