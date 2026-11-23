import CoreGraphics
import MusicCore
import SwiftUI

struct PracticeBoard: View {
    @ObservedObject var clock: Playhead
    let events: [Event]
    let seek: (Double) -> Void
    let project: Project
    let harmonicMode: Bool
    let report: (String) -> Void
    @StateObject private var instrument = BoardInstrument()
    @State private var pressed: Anchor?
    @State private var bend = 0.0
    @State private var displacement = 0.0

    var body: some View {
        GeometryReader { area in
            Canvas { ctx, size in
                let layout = Layout(size: size)
                ctx.withCGContext { g in
                    g.translateBy(x: 0, y: size.height)
                    g.scaleBy(x: 1, y: -1)
                    draw(layout, in: g)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in
                    let layout = Layout(size: area.size)
                    if pressed == nil {
                        let start = CGPoint(x: drag.startLocation.x, y: area.size.height - drag.startLocation.y)
                        guard var anchor = layout.anchor(at: start) else { return }
                        let string = anchor.string
                        let nodes = [5, 7, 12].map { $0 + project.capo }.filter { $0 <= 22 }
                        if let fret = nodes.first(where: { node in abs(layout.wire(Double(node)) - start.x) <= 9 &&
                            (harmonicMode || events.contains { $0.string == string && $0.fret == node && $0.technique == .harmonic }) }) {
                            anchor = Anchor(string: string, fret: fret)
                        }
                        guard anchor.fret >= project.capo,
                              !harmonicMode || nodes.contains(anchor.fret) else { return }
                        let notes = events.filter { $0.string == anchor.string && $0.fret == anchor.fret }
                        let note = notes.first { $0.time > clock.time + 0.02 } ?? notes.first
                        pressed = anchor
                        if let note { seek(note.time + 0.001) }
                        do {
                            try instrument.press(string: anchor.string, fret: anchor.fret,
                                                 velocity: note?.velocity ?? 0.80, project: project,
                                                 harmonic: harmonicMode || note?.technique == .harmonic)
                        } catch { report(error.localizedDescription) }
                    }
                    let delta = drag.translation.height
                    let amount = Self.bendAmount(delta)
                    displacement = (delta < 0 ? 1 : -1) * amount * layout.stringSpace * 0.44
                    if amount != bend { bend = amount; instrument.bend(amount) }
                }
                .onEnded { _ in release() })
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in release() }
            .onDisappear { release(); instrument.close() }
        }.frame(height: 163)
            .accessibilityLabel("Braço da guitarra de 22 casas")
            .accessibilityValue(events.isEmpty ? "Aguardando o solo" : "\(events.count) notas numeradas por ordem de execução")
    }

    static func bendAmount(_ verticalDistance: Double) -> Double {
        min(2, max(0, abs(verticalDistance) - 2) / 22)
    }

    private func release() {
        instrument.release()
        pressed = nil
        bend = 0
        displacement = 0
    }

    struct Anchor: Hashable {
        let string: Int
        let fret: Int
    }
    struct Layout {
        let size: CGSize
        var start: CGFloat { 32 }
        var nut: CGFloat { start + 25 }
        var end: CGFloat { size.width - 10 }
        var stringSpace: CGFloat { (size.height - 57) / 5 }
        var wood: CGRect { CGRect(x: start, y: 24, width: end - start, height: size.height - 30) }

        func wire(_ fret: Double) -> CGFloat {
            nut + (end - nut) * (1 - pow(2, -fret / 12)) / (1 - pow(2, -22.0 / 12))
        }

        func x(_ fret: Double) -> CGFloat {
            if fret <= 0 { return (start + nut) / 2 }
            if fret < 1 { return x(0) + fret * (x(1) - x(0)) }
            return (wire(fret - 1) + wire(fret)) / 2
        }

        func anchor(at point: CGPoint) -> Anchor? {
            guard point.x >= start, point.x <= end, point.y <= y(0) + stringSpace / 2,
                  point.y >= y(5) - stringSpace / 2 else { return nil }
            let string = min(5, max(0, Int(((y(0) - point.y) / stringSpace).rounded())))
            let fret = point.x <= nut ? 0 : (1...22).first { point.x <= wire(Double($0)) } ?? 22
            return Anchor(string: string, fret: fret)
        }

        func y(_ string: Int) -> CGFloat { size.height - 20 - CGFloat(string) * stringSpace }
    }

    private func draw(_ layout: Layout, in g: CGContext) {
        let wood = layout.wood
        let colors = [CGColor(red: 0.14, green: 0.078, blue: 0.054, alpha: 1),
                      CGColor(red: 0.32, green: 0.18, blue: 0.115, alpha: 1),
                      CGColor(red: 0.19, green: 0.105, blue: 0.072, alpha: 1),
                      CGColor(red: 0.11, green: 0.067, blue: 0.05, alpha: 1)]
        g.saveGState()
        g.addPath(CGPath(roundedRect: wood, cornerWidth: 5, cornerHeight: 5, transform: nil))
        g.clip()
        if let grain = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                  locations: [0, 0.26, 0.72, 1]) {
            g.drawLinearGradient(grain, start: CGPoint(x: 0, y: wood.maxY), end: CGPoint(x: 0, y: wood.minY), options: [])
        }
        for i in 1...29 {
            let y = wood.minY + CGFloat(i) * wood.height / 30
            let wave = 2 + CGFloat(i % 6)
            g.move(to: CGPoint(x: wood.minX, y: y))
            g.addCurve(to: CGPoint(x: wood.maxX, y: y + sin(Double(i)) * 3),
                       control1: CGPoint(x: wood.midX * 0.7, y: y + wave),
                       control2: CGPoint(x: wood.midX * 1.4, y: y - wave))
            g.setLineWidth(i.isMultiple(of: 5) ? 1.1 : 0.6)
            g.setStrokeColor(CGColor(gray: i.isMultiple(of: 3) ? 1 : 0, alpha: i.isMultiple(of: 3) ? 0.035 : 0.16))
            g.strokePath()
        }
        for fret in 0...22 {
            let x = layout.wire(Double(fret))
            let nut = fret == 0
            let width: CGFloat = nut ? 4.2 : 1.85
            g.setFillColor(CGColor(gray: 0, alpha: 0.55))
            g.fill(CGRect(x: x - width / 2 + 1, y: wood.minY, width: width + 0.8, height: wood.height))
            g.setFillColor(nut ? ScoreGraphics.ivory : CGColor(gray: 0.47, alpha: 1))
            g.fill(CGRect(x: x - width / 2, y: wood.minY, width: width, height: wood.height))
            g.setFillColor(CGColor(gray: 0.91, alpha: 0.88))
            g.fill(CGRect(x: x - width / 2, y: wood.minY, width: 0.65, height: wood.height))
        }
        g.restoreGState()
        for fret in [0, 3, 5, 7, 9, 12, 15, 17, 19, 21, 22] {
            let x = layout.x(Double(fret))
            ScoreGraphics.text("\(fret)", at: CGPoint(x: x - 4, y: 6), size: 9, in: g, color: ScoreGraphics.metal, mono: true)
            if fret == 0 || fret == 22 { continue }
            let marks = fret == 12 ? [layout.y(1) - layout.stringSpace / 2, layout.y(3) - layout.stringSpace / 2]
                : [layout.y(2) - layout.stringSpace / 2]
            for y in marks {
                g.setFillColor(CGColor(red: 0.90, green: 0.82, blue: 0.68, alpha: 0.65))
                g.fillEllipse(in: CGRect(x: x - 3.0, y: y - 3.0, width: 6, height: 6))
            }
        }
        let active = events.first { $0.time <= clock.time && clock.time < $0.end }
        for (index, string) in ScoreGraphics.strings.enumerated() {
            let y = layout.y(index)
            ScoreGraphics.text(string, at: CGPoint(x: 12, y: y - 3.8), size: 11, in: g, color: ScoreGraphics.ivory, bold: true, mono: true)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: layout.start, y: y))
            if let pressed, pressed.string == index {
                path.addLine(to: CGPoint(x: layout.x(Double(pressed.fret)), y: y + displacement))
            } else if let active, index == active.string, active.technique == .bend {
                let offset = active.pitchOffset(at: (clock.time - active.time) / active.duration)
                let direction: Double = index < 3 ? -1 : 1
                path.addLine(to: CGPoint(x: layout.x(Double(active.fret)), y: y + layout.stringSpace * offset * direction * 0.36))
            }
            path.addLine(to: CGPoint(x: layout.end, y: y))
            drawString(index, path: path, in: g)
        }
        if project.capo > 0 {
            let x = layout.x(Double(project.capo))
            g.setFillColor(CGColor(gray: 0.16, alpha: 0.92))
            g.fill(CGRect(x: layout.start, y: wood.minY, width: x - layout.start, height: wood.height))
            g.setStrokeColor(ScoreGraphics.amber)
            g.setLineWidth(5)
            g.move(to: CGPoint(x: x, y: wood.minY)); g.addLine(to: CGPoint(x: x, y: wood.maxY)); g.strokePath()
        }
        if harmonicMode {
            for node in [5, 7, 12] where project.capo + node <= 22 {
                for string in 0..<6 {
                    let x = layout.wire(Double(project.capo + node)), y = layout.y(string)
                    diamond(x, y, radius: 5, in: g)
                }
            }
        }
        let groups = Dictionary(grouping: Array(events.enumerated())) { Anchor(string: $0.element.string, fret: $0.element.fret) }
        for (anchor, cluster) in groups {
            let isActive = cluster.contains { $0.element.id == active?.id }
            let index = cluster.first(where: { $0.element.id == active?.id })?.offset ?? cluster[0].offset
            let ornament = isActive ? active?.pitchOffset(at: (clock.time - (active?.time ?? 0)) / (active?.duration ?? 1)) ?? 0 : 0
            let harmonic = events[index].technique == .harmonic
            let x = harmonic ? layout.wire(Double(anchor.fret)) : layout.x(Double(anchor.fret) + (isActive && active?.technique == .slide ? ornament : 0))
            let bend = isActive && active?.technique == .bend ? ornament * layout.stringSpace * (anchor.string < 3 ? -0.36 : 0.36) : 0
            let y = layout.y(anchor.string) + (anchor == pressed ? displacement : bend)
            let radius: Double = isActive ? 12 : 9.2
            let marker = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            g.setFillColor(isActive ? ScoreGraphics.amber : CGColor(red: 0.22, green: 0.11, blue: 0.065, alpha: 1))
            if harmonic { diamond(x, y, radius: radius + 2, in: g) } else { g.fillEllipse(in: marker) }
            g.setStrokeColor(ScoreGraphics.amber)
            g.setLineWidth(isActive ? 2.2 : 1.0)
            if !harmonic { g.strokeEllipse(in: marker) }
            let label = "\(index + 1)"
            ScoreGraphics.text(label, at: CGPoint(x: x - CGFloat(label.count) * 3, y: y - 3.6),
                               size: 9, in: g, color: isActive && !harmonic ? ScoreGraphics.paper : ScoreGraphics.ivory, bold: true, mono: true)
            if cluster.count > 1 {
                let count = "\(cluster.count)"
                g.setFillColor(ScoreGraphics.ivory)
                g.fillEllipse(in: CGRect(x: x + 3.5, y: y + 5, width: 12, height: 12))
                ScoreGraphics.text(count, at: CGPoint(x: x + 9.5 - Double(count.count) * 2.5, y: y + 8),
                                   size: 7, in: g, color: ScoreGraphics.paper, bold: true, mono: true)
            }
        }
        if let pressed {
            let x = layout.x(Double(pressed.fret)), y = layout.y(pressed.string) + displacement
            g.setStrokeColor(ScoreGraphics.amber)
            g.setLineWidth(2.5)
            g.strokeEllipse(in: CGRect(x: x - 12, y: y - 12, width: 24, height: 24))
            if bend > 0 {
                ScoreGraphics.text(String(format: "+%.1f st", bend), at: CGPoint(x: min(layout.end - 44, x + 14), y: max(12, min(layout.size.height - 13, y + 3))),
                                   size: 10, in: g, color: ScoreGraphics.ivory, bold: true, mono: true)
            }
        }
    }
    private func diamond(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, in g: CGContext) {
        g.setFillColor(CGColor(gray: 0.13, alpha: 1))
        g.setStrokeColor(ScoreGraphics.amber)
        g.setLineWidth(1.6)
        g.move(to: CGPoint(x: x, y: y + radius))
        g.addLine(to: CGPoint(x: x + radius, y: y))
        g.addLine(to: CGPoint(x: x, y: y - radius))
        g.addLine(to: CGPoint(x: x - radius, y: y))
        g.closePath(); g.drawPath(using: .fillStroke)
    }

    private func drawString(_ index: Int, path: CGPath, in g: CGContext) {
        let gauge: [CGFloat] = [0.85, 1.35, 2.0, 3.0, 4.3, 5.9]
        let width = gauge[index]
        let wound = index >= 3
        func stroke(_ thickness: CGFloat, _ color: CGColor, offset: CGFloat = 0) {
            g.saveGState()
            g.translateBy(x: 0, y: offset)
            g.setLineWidth(thickness)
            g.setStrokeColor(color)
            g.addPath(path)
            g.strokePath()
            g.restoreGState()
        }
        stroke(width + 0.9, CGColor(gray: 0, alpha: 0.60), offset: -1.1)
        stroke(width, CGColor(gray: wound ? 0.57 : 0.90, alpha: 1))
        if wound {
            g.saveGState()
            g.setLineDash(phase: 0, lengths: [0.7, 1.8])
            stroke(width * 0.84, CGColor(gray: 0.17, alpha: 0.77))
            g.restoreGState()
        }
        stroke(max(0.45, width * 0.22), CGColor(gray: 0.98, alpha: 0.85), offset: width * 0.24)
    }

}
