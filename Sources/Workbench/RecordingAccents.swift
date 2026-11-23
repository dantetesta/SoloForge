import AVFoundation
import MusicCore

/// Brief stereo energy attacks in a representative four-bar excerpt of each section.
/// Times are expressed on the same grid as the proposed score, including the residual offset.
enum RecordingAccents {
    static func extract(_ file: AVAudioFile, section: Passage, map: AudioMap, grid: SectionGrid) throws -> [[Int]] {
        let rate = file.processingFormat.sampleRate
        let start = max(section.start, (section.start + section.end) / 2 - 2 * Double(map.meter) * 60 / map.bpm)
        let seconds = min(section.end - start, 4 * Double(map.meter) * 60 / map.bpm)
        let length = min(file.length - Int64(start * rate), Int64(seconds * rate))
        let hop = max(1, Int(rate * 0.005))
        guard length >= 3 * hop, let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length)) else { return [] }
        file.framePosition = Int64(start * rate)
        try file.read(into: block)
        guard let channels = block.floatChannelData else { return [] }
        var flux = [Double]()
        var previous = 0.0
        for i in stride(from: 0, to: Int(block.frameLength) - hop, by: hop) {
            var power = 0.0
            for c in 0..<Int(block.format.channelCount) {
                for j in stride(from: i, to: i + hop, by: 4) { let v = Double(channels[c][j]); power += v * v }
            }
            let level = sqrt(power / Double(hop))
            flux.append(max(0, level - previous))
            previous = level
        }
        guard flux.count >= 3, let peak = flux.dropFirst().max(), peak > 0.001 else { return [] }
        let maxima = (1..<(flux.count - 1)).filter { flux[$0] > peak * 0.15 && flux[$0] >= flux[$0 - 1] && flux[$0] > flux[$0 + 1] }
        var selected: [Int] = []
        for i in maxima.sorted(by: { flux[$0] > flux[$1] }) where selected.allSatisfy({ abs($0 - i) >= 13 }) {
            selected.append(i)
            if selected.count == 16 { break }
        }
        return selected.sorted().map { i in
            let t = start + Double(i * hop) / rate
            let step = grid.step(at: t)
            let residual = (t - grid.origin) / grid.stepDuration - Double(step)
            return [step, min(50, max(-50, Int((residual * 100).rounded()))), Int((flux[i] / peak * 100).rounded())]
        }
    }
}
