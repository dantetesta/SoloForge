import Accelerate
import AVFoundation
import CoreML
import MusicCore

/// Stereo HTDemucs 6s. The model predicts both a waveform and complex STFT;
/// the guitar is source 4. Both branches are normalized as in demucs/htdemucs.py.
enum GuitarSeparation {
    static let frames = 343_980
    private static let bins = 2048, columns = 336, fftSize = 4096, hop = 1024

    static func isolate(_ source: URL, passage: Passage, to target: URL,
                        progress: (Double) -> Void) throws {
        let modelPath = "GuitarSeparation/HTDemucs_6S_Split_F16.mlpackage"
        var modelURL = Bundle.main.resourceURL!.appendingPathComponent(modelPath)
        #if DEBUG
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            modelURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Models/" + modelPath)
        }
        #endif
        let compiled = try MLModel.compileModel(at: modelURL)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: compiled, configuration: config)
        let file = try AVAudioFile(forReading: source)
        let output = try AudioFiles.writable(target)
        let format = file.processingFormat
        guard format.sampleRate == AudioFiles.rate, format.channelCount == 2,
              let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let written = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2)) else { throw WorkError.files }
        defer { vDSP_destroy_fftsetup(setup) }
        let wave = try MLMultiArray(shape: [1, 2, NSNumber(value: frames)], dataType: .float16)
        let spec = try MLMultiArray(shape: [1, 4, 2048, 336], dataType: .float16)
        let input = try MLDictionaryFeatureProvider(dictionary: ["audio_waveform": wave, "spectral_magnitude": spec])
        let window = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize))) }
        let first = Int64((passage.start * AudioFiles.rate).rounded())
        let last = min(file.length, Int64((passage.end * AudioFiles.rate).rounded()))
        let context = 44_100, overlap = 8_820
        let stride = frames - 2 * context - overlap
        var tails = Array(repeating: [Float](repeating: 0, count: overlap), count: 2)
        var cursor = first
        while cursor < last {
            try Task.checkCancellation()
            try autoreleasepool {
                let origin = cursor - Int64(context)
                let from = max(0, origin)
                let count = min(Int64(frames) + origin, file.length) - from
                file.framePosition = from
                try file.read(into: block, frameCount: AVAudioFrameCount(count))
                let pad = Int(from - origin)
                for ch in 0..<2 {
                    let source = block.floatChannelData![ch]
                    var samples = [Float](repeating: 0, count: frames)
                    samples.withUnsafeMutableBufferPointer { dest in
                        dest.baseAddress!.advanced(by: pad).update(from: source, count: Int(block.frameLength))
                    }
                    let wt = wave.dataPointer.assumingMemoryBound(to: Float16.self) + ch * wave.strides[1].intValue
                    for i in samples.indices { wt[i] = Float16(samples[i]) }
                    spectrum(samples, channel: ch, tensor: spec, window: window, fft: setup)
                }
                let result = try model.prediction(from: input)
                guard let freq = result.featureValue(for: "freq_output")?.multiArrayValue,
                      let time = result.featureValue(for: "time_output")?.multiArrayValue,
                      freq.dataType == .float16, time.dataType == .float16,
                      freq.shape == [1,24,2048,336], time.shape == [1,12,343980] else {
                    throw WorkError.audio("A saída do modelo de separação da guitarra é incompatível.")
                }
                try Task.checkCancellation()
                let n = min(stride, Int(last - cursor))
                written.frameLength = AVAudioFrameCount(n)
                for ch in 0..<2 {
                    let reconstructed = inverse(freq, channel: 16 + 2 * ch, window: window, fft: setup)
                    let timeBase = time.dataPointer.assumingMemoryBound(to: Float16.self) + (8 + ch) * time.strides[1].intValue
                    let timeStride = time.strides[2].intValue
                    let out = written.floatChannelData![ch]
                    for i in 0..<(n + (cursor + Int64(n) < last ? overlap : 0)) {
                        let j = context + i
                        var v = reconstructed[j] + Float(timeBase[j * timeStride])
                        guard v.isFinite else { throw WorkError.audio("Falha ao separar a guitarra desta gravação.") }
                        if i >= n { tails[ch][i - n] = v; continue }
                        if cursor != first && i < overlap {
                            let alpha = Float(i) / Float(overlap)
                            v = (1 - alpha) * tails[ch][i] + alpha * v
                        }
                        out[i] = v
                    }
                }
                try output.write(from: written)
                cursor += Int64(n)
            }
            progress(Double(cursor - first) / Double(last - first))
        }
    }

    private static func spectrum(_ signal: [Float], channel: Int, tensor: MLMultiArray, window: [Float], fft: FFTSetup) {
        let ptr = tensor.dataPointer.assumingMemoryBound(to: Float16.self) + 2 * channel * tensor.strides[1].intValue
        let imag = ptr + tensor.strides[1].intValue
        let stride = tensor.strides[2].intValue
        var r = [Float](repeating: 0, count: fftSize), im = r
        for col in 0..<columns {
            let origin = col * hop - 1536
            for i in 0..<fftSize {
                let j = abs(origin + i)
                r[i] = signal[j < frames ? j : 2 * frames - 2 - j] * window[i]
                im[i] = 0
            }
            transform(&r, &im, fft: fft, direction: Int32(FFT_FORWARD))
            for bin in 0..<bins {
                let idx = bin * stride + col
                ptr[idx] = Float16(r[bin] / 64)
                imag[idx] = Float16(im[bin] / 64)
            }
        }
    }

    private static func inverse(_ tensor: MLMultiArray, channel: Int, window: [Float], fft: FFTSetup) -> [Float] {
        let strides = tensor.strides.map(\.intValue)
        let ptr = tensor.dataPointer.assumingMemoryBound(to: Float16.self) + channel * strides[1]
        let imag = ptr + strides[1]
        var output = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: fftSize), im = r
        for col in 0..<columns {
            for bin in 0..<bins {
                let idx = bin * strides[2] + col * strides[3]
                r[bin] = Float(ptr[idx]); im[bin] = Float(imag[idx])
                if bin > 0 { r[fftSize - bin] = r[bin]; im[fftSize - bin] = -im[bin] }
            }
            im[0] = 0; r[bins] = 0; im[bins] = 0
            transform(&r, &im, fft: fft, direction: Int32(FFT_INVERSE))
            let origin = col * hop - 1536
            for i in max(0, -origin)..<min(fftSize, frames - origin) {
                output[origin + i] += r[i] * window[i] / 96 // sqrt(4096) × Hann squared overlap of 1.5
            }
        }
        return output
    }

    private static func transform(_ r: inout [Float], _ im: inout [Float], fft: FFTSetup, direction: Int32) {
        r.withUnsafeMutableBufferPointer { real in
            im.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(fft, &split, 1, 12, direction)
            }
        }
    }
}
