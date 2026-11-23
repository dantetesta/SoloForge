import AppKit
import AVFoundation
import CoreText
import Foundation
import MusicCore
import UniformTypeIdentifiers

enum ExportKind: String, CaseIterable {
    case pdf = "Tablatura PDF", solo = "Solo isolado WAV", mix = "Mixagem WAV", video = "Vídeo de estudo MP4", project = "Projeto portátil"
    var ext: String {
        switch self {
        case .pdf: "pdf"; case .solo, .mix: "wav"; case .video: "mp4"; case .project: "guitarproject"
        }
    }
    var contentType: UTType {
        switch self {
        case .pdf: .pdf; case .solo, .mix: .wav; case .video: .mpeg4Movie
        case .project: UTType(exportedAs: "org.soloforge.community.guitarproject", conformingTo: .package)
        }
    }
}
struct ExportOptions {
    var height = 720
    var music = true
    var entireSong = false
    var includeChords = false
}

enum Exporter {
    static func export(_ kind: ExportKind, project: Project, events: [Event], recording: URL,
                       levels: MixLevels, options: ExportOptions, library: URL, to destination: URL,
                       progress: (Double) -> Void) throws {
        if kind == .project {
            try Task.checkCancellation()
            try Store(folder: library).export(project, to: destination)
            progress(1); return
        }
        guard !events.isEmpty else { throw WorkError.selectPhrase }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("guitar-export-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(kind.ext)")
        defer { try? fm.removeItem(at: stage) }
        func update(_ value: Double) { progress(min(1, max(0, value))) }
        if kind == .pdf {
            try ScoreGraphics.pdf(project, events: events, chords: options.includeChords && project.chordSheet, to: stage, progress: update)
        } else {
            let lead = try LeadRender.create(events: events, project: project, to: temporary.appendingPathComponent("lead.wav"))
            update(0.08)
            var mix = levels
            if kind == .solo || (kind == .video && !options.music) { mix.music = 0; mix.lead = project.leadVolume }
            let range = options.entireSong ? 0...project.map.duration : project.passage.start...project.passage.end
            let audioURL = kind == .video ? temporary.appendingPathComponent("audio.wav") : stage
            try AudioExport.render(project: project, recording: recording, lead: lead, range: range,
                                   levels: mix, to: audioURL) { update(0.08 + $0 * (kind == .video ? 0.20 : 0.92)) }
            if kind == .video {
                try VideoExport.create(project: project, events: events, range: range, height: options.height,
                                       audio: audioURL, to: stage) { update(0.28 + $0 * 0.72) }
            }
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: stage) }
        else { try fm.moveItem(at: stage, to: destination) }
        update(1)
    }
}

enum ScoreGraphics {
    static let amber = CGColor(red: 1, green: 0.42, blue: 0.14, alpha: 1)
    static let paper = CGColor(gray: 0.12, alpha: 1)
    static let ivory = CGColor(red: 0.97, green: 0.94, blue: 0.88, alpha: 1)
    static let metal = CGColor(red: 0.70, green: 0.68, blue: 0.63, alpha: 1)
    static let rings = [3, 5, 7, 9, 12, 15, 17, 19, 21]
    static let strings = ["e", "B", "G", "D", "A", "E"]

    static func text(_ text: String, at: CGPoint, size: CGFloat, in g: CGContext, color: CGColor, bold: Bool = false, mono: Bool = false) {
        let name = mono ? (bold ? "Menlo-Bold" : "Menlo-Regular") : (bold ? "Helvetica-Bold" : "Helvetica")
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        g.saveGState()
        g.textMatrix = .identity
        g.textPosition = at
        CTLineDraw(CTLineCreateWithAttributedString(attr), g)
        g.restoreGState()
    }

    static func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat, color: CGColor, in g: CGContext) {
        g.setStrokeColor(color); g.setLineWidth(width)
        g.move(to: a); g.addLine(to: b); g.strokePath()
    }

    static func tablature(_ events: [Event], range: ClosedRange<Double>, grid: AudioMap, at r: CGRect, time: Double?,
                          dark: Bool, chords: Bool = false, transpose: Int = 0, in g: CGContext) {
        let foreground = dark ? ivory : paper
        let guide = dark ? CGColor(red: 0.53, green: 0.49, blue: 0.44, alpha: 1) : CGColor(gray: 0.63, alpha: 1)
        let accent = dark ? amber : CGColor(red: 0.63, green: 0.20, blue: 0.06, alpha: 1)
        let startX = r.minX + 31, endX = r.maxX - 24
        let top = r.maxY - 42, spacing = min(17, (r.height - 59) / 5)
        let rangeSpan = max(0.02, range.upperBound - range.lowerBound)
        func x(_ at: Double) -> CGFloat { startX + CGFloat((at - range.lowerBound) / rangeSpan) * (endX - startX) }
        let beat = 60 / grid.bpm
        let first = Int(ceil((range.lowerBound - grid.beatOffset) / beat))
        let last = Int(floor((range.upperBound - grid.beatOffset) / beat))
        if first <= last && last - first < 180 {
            for i in first...last {
                let t = grid.beatOffset + Double(i) * beat
                let bar = i.isMultiple(of: grid.meter)
                if bar {
                    line(CGPoint(x: x(t), y: top + 6), CGPoint(x: x(t), y: top - spacing * 5 - 6),
                         width: 1.05, color: guide, in: g)
                    text("\(max(1, Int(floor(Double(i) / Double(grid.meter))) + 1))",
                         at: CGPoint(x: x(t) + 3, y: top + 12), size: 8, in: g, color: guide, mono: true)
                }
            }
        }
        for (i, note) in strings.enumerated() {
            let y = top - CGFloat(i) * spacing
            text(note, at: CGPoint(x: r.minX + 3, y: y - 4), size: 12, in: g, color: foreground, bold: true, mono: true)
            g.saveGState()
            if dark { g.setLineDash(phase: 0, lengths: [6, 2.2]) }
            line(CGPoint(x: startX, y: y), CGPoint(x: endX, y: y), width: 0.60, color: guide, in: g)
            g.restoreGState()
        }
        if let time, range.contains(time) {
            line(CGPoint(x: x(time), y: top + 3), CGPoint(x: x(time), y: top - spacing * 5 - 4), width: 1.6, color: accent, in: g)
        }
        let visible = events.filter { $0.time >= range.lowerBound - 0.00001 && $0.time < range.upperBound }
        var previous = range.lowerBound
        for event in visible {
            if event.time - previous > beat * 0.44 {
                let pause = x((event.time + previous) / 2)
                let y = r.minY + 5
                line(CGPoint(x: pause - 3, y: y + 3.4), CGPoint(x: pause + 2.7, y: y + 3.4), width: 1.0, color: guide, in: g)
                line(CGPoint(x: pause + 2.7, y: y + 3.4), CGPoint(x: pause - 1.2, y: y - 3.6), width: 1.0, color: guide, in: g)
            }
            let y = top - CGFloat(event.string) * spacing
            let noteX = x(event.time)
            let marked = time.map { event.time <= $0 && $0 < event.end } ?? false
            let label = event.label
            let fs: CGFloat = 13
            let box = CGRect(x: noteX - 2, y: y - 7, width: CGFloat(label.count) * 8 + 5, height: 15)
            g.setFillColor(marked ? accent : dark ? CGColor(gray: 0.09, alpha: 1) : CGColor(gray: 1, alpha: 1))
            g.addPath(CGPath(roundedRect: box, cornerWidth: 2.4, cornerHeight: 2.4, transform: nil))
            g.fillPath()
            text(label, at: CGPoint(x: noteX, y: y - 4.5), size: fs, in: g, color: marked ? paper : foreground, bold: true, mono: true)
            let yRhythm = r.minY + 5
            line(CGPoint(x: noteX, y: yRhythm), CGPoint(x: max(noteX + 2, x(min(range.upperBound, event.end))), y: yRhythm),
                 width: 1.65, color: marked ? accent : guide, in: g)
            previous = event.end
        }
        if chords {
            var lastChordX = r.minX - 80
            var previousSymbol: String?
            for chord in grid.chords where chord.start < range.upperBound && chord.end > range.lowerBound && chord.confidence >= 0.12 {
                let name = pitchNames[pitchClass(chord.root + transpose)] + chord.quality.suffix
                let left = x(max(range.lowerBound, chord.start))
                if left - lastChordX < 37 || previousSymbol == name { continue }
                text(name, at: CGPoint(x: left + 5, y: r.maxY - 15), size: 13, in: g, color: foreground, bold: true, mono: true)
                lastChordX = left
                previousSymbol = name
            }
        }
    }

    static func fretboard(event: Event?, time: Double, position: Int, capo: Int = 0, at r: CGRect, in g: CGContext) {
        let displacement = event.map { $0.pitchOffset(at: (time - $0.time) / $0.duration) } ?? 0
        let effective = event.map { Double($0.fret) + ($0.technique == .slide ? displacement : 0) }
        let center = effective.map { Int($0.rounded()) } ?? position
        let first = min(15, max(0, center - 3))
        let left = r.minX + 33
        let spacing = (r.height - 38) / 5
        let top = r.maxY - 22
        let fretWidth = (r.maxX - left - 8) / 8
        let wood = CGRect(x: left, y: r.minY + 8, width: 8 * fretWidth, height: r.height - 18)
        let colors = [CGColor(red: 0.25, green: 0.14, blue: 0.10, alpha: 1), CGColor(red: 0.12, green: 0.07, blue: 0.05, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            g.saveGState(); g.clip(to: wood)
            g.drawLinearGradient(gradient, start: CGPoint(x: left, y: wood.maxY), end: CGPoint(x: left, y: wood.minY), options: [])
            g.restoreGState()
        }
        for lane in 0...8 {
            let x = left + CGFloat(lane) * fretWidth
            line(CGPoint(x: x, y: wood.minY), CGPoint(x: x, y: wood.maxY), width: lane == 0 && first == 0 ? 5 : 1.4, color: metal, in: g)
            guard lane < 8, rings.contains(first + lane) else { continue }
            let marks = first + lane == 12 ? [0.33, 0.67] : [0.50]
            for mark in marks {
                let cx = x + fretWidth / 2, cy = wood.minY + wood.height * mark
                g.setFillColor(CGColor(gray: 0.82, alpha: 0.43))
                g.fillEllipse(in: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6))
            }
        }
        for i in 0..<8 {
            text("\(first + i)", at: CGPoint(x: left + fretWidth * (CGFloat(i) + 0.45), y: r.maxY - 8), size: 9, in: g, color: ivory, mono: true)
        }
        if capo > 0, (first..<(first + 8)).contains(capo) {
            let x = left + (Double(capo - first) + 0.49) * fretWidth
            line(CGPoint(x: x, y: wood.minY), CGPoint(x: x, y: wood.maxY), width: 4, color: amber, in: g)
        }
        for (i, name) in strings.enumerated() {
            let y = top - CGFloat(i) * spacing
            text(name, at: CGPoint(x: r.minX + 9, y: y - 3), size: 12, in: g, color: ivory, mono: true)
            let a = CGPoint(x: left, y: y), b = CGPoint(x: wood.maxX, y: y)
            if let event, i == event.string, let effective {
                let x = left + (effective - Double(first) + 0.49) * fretWidth
                let push = event.technique == .bend ? spacing * displacement * 0.40 * (i < 3 ? -1 : 1) : 0
                let center = CGPoint(x: x, y: y + push)
                line(a, center, width: 1.5, color: amber, in: g)
                line(center, b, width: 1.5, color: amber, in: g)
                g.setFillColor(amber)
                if event.technique == .harmonic {
                    g.move(to: CGPoint(x: x, y: center.y + 11))
                    g.addLine(to: CGPoint(x: x + 11, y: center.y))
                    g.addLine(to: CGPoint(x: x, y: center.y - 11))
                    g.addLine(to: CGPoint(x: x - 11, y: center.y))
                    g.closePath(); g.fillPath()
                } else { g.fillEllipse(in: CGRect(x: x - 8, y: center.y - 8, width: 16, height: 16)) }
                text("\(Int(effective.rounded()))", at: CGPoint(x: x - 3.3, y: center.y - 3), size: 9, in: g, color: paper, bold: true, mono: true)
            } else {
                line(a, b, width: 0.55 + Double(i) * 0.22, color: metal, in: g)
            }
        }
    }

    static func pdf(_ project: Project, events: [Event], chords: Bool, to url: URL, progress: (Double) -> Void) throws {
        var bounds = CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let g = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw WorkError.files }
        let barLength = Double(project.map.meter) * 60 / project.map.bpm
        let first = min(project.passage.start, events.first?.time ?? project.passage.start)
        let last = max(events.last?.end ?? project.passage.end, min(project.passage.end, first + barLength * 3))
        let period = barLength * 2
        let rows = max(1, Int(ceil((last - first) / period)))
        let pages = (rows + 2) / 3
        for page in 0..<pages {
            try Task.checkCancellation()
            g.beginPDFPage(nil)
            text(String(project.name.prefix(72)), at: CGPoint(x: 38, y: 550), size: 23, in: g, color: paper, bold: true)
            text("\(project.presentedKey.label) · \(project.capoLabel)   ·   \(Int(project.map.bpm.rounded())) BPM   ·   \(project.map.meter)/4   ·   \(project.phrase?.name ?? "")",
                 at: CGPoint(x: 39, y: 525), size: 12, in: g, color: paper)
            for row in 0..<3 where page * 3 + row < rows {
                let from = first + Double(page * 3 + row) * period
                tablature(events, range: from...min(last, from + period), grid: project.map,
                          at: CGRect(x: 38, y: 355 - CGFloat(row) * 155, width: 766, height: 143), time: nil, dark: false,
                          chords: chords, transpose: project.shapeTranspose, in: g)
            }
            text("h ligado   / slide   ~ vibrato   b+ bend   <n> harmônico natural   ·   Traços inferiores indicam duração", at: CGPoint(x: 39, y: 25),
                 size: 9, in: g, color: paper)
            text("\(page + 1) / \(pages)", at: CGPoint(x: 763, y: 25), size: 9, in: g, color: paper)
            g.endPDFPage()
            progress(Double(page + 1) / Double(pages))
        }
        g.closePDF()
    }
}

enum VideoExport {
    static let fps: Int32 = 30
    static func create(project: Project, events: [Event], range: ClosedRange<Double>, height: Int, audio: URL, to destination: URL,
                       progress: (Double) -> Void) throws {
        do {
            try createNative(project: project, events: events, range: range, height: height, audio: audio, to: destination, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let ffmpeg = AudioFiles.ffmpeg else { throw error }
            try? FileManager.default.removeItem(at: destination)
            try createFallback(ffmpeg, project: project, events: events, range: range, height: height,
                               audio: audio, to: destination, progress: progress)
        }
    }

    private static func createNative(project: Project, events: [Event], range: ClosedRange<Double>, height: Int, audio: URL, to destination: URL,
                                     progress: (Double) -> Void) throws {
        guard [540, 720, 1080].contains(height) else { throw WorkError.audio("Resolução incompatível.") }
        let width = height * 16 / 9
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        let soundtrack = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioFiles.rate,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
        ])
        let asset = AVURLAsset(url: audio)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw WorkError.files }
        let reader = try AVAssetReader(asset: asset)
        let pcm = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        guard reader.canAdd(pcm), writer.canAdd(video), writer.canAdd(soundtrack) else { throw failure(writer) }
        reader.add(pcm); writer.add(video); writer.add(soundtrack)
        guard reader.startReading(), writer.startWriting() else { throw failure(writer) }
        writer.startSession(atSourceTime: .zero)
        do {
            let frames = max(1, Int(ceil((range.upperBound - range.lowerBound) * Double(fps))))
            var audioSample = pcm.copyNextSampleBuffer()
            var frame = 0
            var lastProgress = ProcessInfo.processInfo.systemUptime
            while frame < frames || audioSample != nil {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw failure(writer) }
                var advanced = false
                if frame < frames && video.isReadyForMoreMediaData {
                    try autoreleasepool {
                        guard let pool = adaptor.pixelBufferPool else { throw failure(writer) }
                        var pixel: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess,
                              let pixel else { throw failure(writer) }
                        let time = range.lowerBound + Double(frame) / Double(fps)
                        try draw(pixel, project: project, events: events, time: time, range: range)
                        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else { throw failure(writer) }
                    }
                    frame += 1; advanced = true
                    if frame == frames { video.markAsFinished(); progress(1) }
                    else if frame.isMultiple(of: 12) { progress(Double(frame) / Double(frames)) }
                }
                if let sample = audioSample, soundtrack.isReadyForMoreMediaData,
                   frame == frames || CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) <= Double(frame) / Double(fps) + 0.40 {
                    guard soundtrack.append(sample) else { throw failure(writer) }
                    audioSample = pcm.copyNextSampleBuffer()
                    if audioSample == nil { soundtrack.markAsFinished() }
                    advanced = true
                }
                if advanced { lastProgress = ProcessInfo.processInfo.systemUptime }
                else {
                    guard ProcessInfo.processInfo.systemUptime - lastProgress < 15 else { throw failure(writer) }
                    Thread.sleep(forTimeInterval: 0.004)
                }
            }
            guard reader.status == .completed else { throw reader.error ?? failure(writer) }
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            while finished.wait(timeout: .now() + 0.05) == .timedOut { try Task.checkCancellation() }
            guard writer.status == .completed else { throw failure(writer) }
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
    }

    private static func createFallback(_ ffmpeg: String, project: Project, events: [Event], range: ClosedRange<Double>,
                                       height: Int, audio: URL, to destination: URL, progress: (Double) -> Void) throws {
        guard [540, 720, 1080].contains(height) else { throw WorkError.audio("Resolução incompatível.") }
        let width = height * 16 / 9
        let stream = Pipe()
        let job = try MediaProcess.start(ffmpeg, ["-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "\(width)x\(height)",
            "-framerate", String(fps), "-i", "pipe:0", "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-preset", "fast", "-threads", "3", "-crf", "19", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", destination.path], input: stream)
        let pipe = stream.fileHandleForWriting
        defer {
            try? pipe.close()
            if job.isRunning { job.terminate(); job.waitUntilExit() }
        }
        let row = width * 4
        var pixels = Data(count: row * height)
        let frames = max(1, Int(ceil((range.upperBound - range.lowerBound) * Double(fps))))
        for frame in 0..<frames {
            try Task.checkCancellation()
            guard job.isRunning else { throw WorkError.audio("O codificador local encerrou antes de receber todos os quadros.") }
            try autoreleasepool {
                try pixels.withUnsafeMutableBytes { bytes in
                    guard let g = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                        throw WorkError.audio("Falha ao desenhar quadro de vídeo.")
                    }
                    paint(g, width: width, height: height, project: project, events: events,
                          time: range.lowerBound + Double(frame) / Double(fps), range: range)
                }
                try pipe.write(contentsOf: pixels)
            }
            if frame.isMultiple(of: 12) { progress(Double(frame) / Double(frames)) }
        }
        try pipe.close()
        try MediaProcess.finish(job, message: "O codificador local não conseguiu concluir a exportação MP4.")
        progress(1)
    }

    private static func failure(_ writer: AVAssetWriter) -> Error {
        writer.error ?? WorkError.audio("O codificador de vídeo não conseguiu concluir a exportação.")
    }

    private static func draw(_ pixel: CVPixelBuffer, project: Project, events: [Event], time: Double, range: ClosedRange<Double>) throws {
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let w = CVPixelBufferGetWidth(pixel), h = CVPixelBufferGetHeight(pixel)
        guard let g = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw WorkError.audio("Falha ao desenhar quadro de vídeo.")
        }
        paint(g, width: w, height: h, project: project, events: events, time: time, range: range)
    }

    private static func paint(_ g: CGContext, width w: Int, height h: Int, project: Project, events: [Event],
                              time: Double, range: ClosedRange<Double>) {
        let scale = CGFloat(h) / 720
        g.scaleBy(x: scale, y: scale)
        let fullWidth = CGFloat(w) / scale
        g.setFillColor(CGColor(red: 0.075, green: 0.075, blue: 0.083, alpha: 1))
        g.fill(CGRect(x: 0, y: 0, width: fullWidth, height: 720))
        let event = events.first { $0.time <= time && time < $0.end }
        ScoreGraphics.text(String(project.name.prefix(70)), at: CGPoint(x: 65, y: 615), size: 44, in: g, color: ScoreGraphics.ivory, bold: true)
        ScoreGraphics.text("\(project.presentedKey.label) · \(project.capoLabel)   ·   \(Int(project.map.bpm.rounded())) BPM   ·   \(project.map.meter)/4", at: CGPoint(x: 67, y: 568), size: 20, in: g, color: ScoreGraphics.amber, mono: true)
        ScoreGraphics.fretboard(event: event, time: time, position: project.preferences.position, capo: project.capo,
                                at: CGRect(x: 64, y: 335, width: fullWidth - 128, height: 175), in: g)
        let span = min(range.upperBound - range.lowerBound, max(3.0, 60 / project.map.bpm * Double(project.map.meter) * 2))
        let lower = min(max(range.lowerBound, time - span * 0.32), range.upperBound - span)
        ScoreGraphics.tablature(events, range: lower...(lower + span), grid: project.map,
                                 at: CGRect(x: 65, y: 116, width: fullWidth - 130, height: 168), time: time, dark: true,
                                 chords: project.chordSheet, transpose: project.shapeTranspose, in: g)
        let label = event.map { "Corda \($0.string + 1) · Casa \($0.relativeFret) · \($0.technique.rawValue)" } ?? "Pausa"
        ScoreGraphics.text(label, at: CGPoint(x: 67, y: 69), size: 18, in: g, color: ScoreGraphics.ivory, mono: true)
        ScoreGraphics.text(String(format: "%05.2f s", time), at: CGPoint(x: fullWidth - 174, y: 69), size: 18, in: g, color: ScoreGraphics.amber, mono: true)
    }
}

enum MediaProcess {
    static func start(_ executable: String, _ arguments: [String], input: Pipe? = nil) throws -> Process {
        let job = Process()
        job.executableURL = URL(fileURLWithPath: executable)
        job.arguments = ["-nostdin", "-v", "error", "-y"] + arguments
        if let input { job.standardInput = input }
        else { job.standardInput = FileHandle.nullDevice }
        job.standardOutput = FileHandle.nullDevice
        job.standardError = FileHandle.nullDevice
        try job.run()
        return job
    }
    static func finish(_ job: Process, message: String) throws {
        while job.isRunning {
            if Task.isCancelled {
                job.terminate(); job.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.035)
        }
        guard job.terminationStatus == 0 else { throw WorkError.audio(message) }
    }
}
