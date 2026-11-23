import MusicCore
import SwiftUI

struct Waveform: View {
    @ObservedObject var clock: Playhead
    let project: Project
    var onSeek: (Double) -> Void
    var body: some View {
        VStack(spacing: 1) {
            GeometryReader { geometry in
                Canvas { g, size in
                    let duration = project.map.duration
                    func x(_ time: Double) -> CGFloat { size.width * time / duration }
                    let selection = CGRect(x: x(project.passage.start), y: 0, width: x(project.passage.end - project.passage.start), height: size.height)
                    g.fill(Path(selection), with: .color(Palette.orange.opacity(0.16)))
                    for hint in project.map.vocalHints ?? [] {
                        let rect = CGRect(x: x(hint.start), y: size.height - 3, width: max(1, x(hint.end - hint.start)), height: 3)
                        g.fill(Path(rect), with: .color(Palette.ivory.opacity(0.30 + hint.confidence * 0.50)))
                    }
                    let amps = project.map.waveform
                    let step = max(1, amps.count / max(1, Int(size.width / 2)))
                    var selected = Path(), outside = Path()
                    for i in stride(from: 0, to: amps.count, by: step) {
                        let time = Double(i) * duration / Double(amps.count)
                        let power = amps[i..<min(i + step, amps.count)].max() ?? 0
                        let halfHeight = 2 + CGFloat(pow(power, 0.66)) * (size.height * 0.43)
                        let start = CGPoint(x: x(time), y: size.height / 2 - halfHeight)
                        let end = CGPoint(x: x(time), y: size.height / 2 + halfHeight)
                        if (project.passage.start...project.passage.end).contains(time) { selected.move(to: start); selected.addLine(to: end) }
                        else { outside.move(to: start); outside.addLine(to: end) }
                    }
                    g.stroke(outside, with: .color(Palette.muted.opacity(0.45)), lineWidth: 1)
                    g.stroke(selected, with: .color(Palette.orange), lineWidth: 1.1)
                    let barLength = 60 / project.map.bpm * Double(project.map.meter)
                    let interval = max(1, Int(ceil(duration / barLength / 48)))
                    let first = Int(ceil(-project.map.beatOffset / barLength))
                    let last = Int(floor((duration - project.map.beatOffset) / barLength))
                    var bars = Path()
                    if first <= last {
                        for bar in stride(from: first, through: last, by: interval) {
                            let cx = x(project.map.beatOffset + Double(bar) * barLength)
                            bars.move(to: CGPoint(x: cx, y: 0)); bars.addLine(to: CGPoint(x: cx, y: size.height * 0.22))
                        }
                    }
                    g.stroke(bars, with: .color(Palette.ivory.opacity(0.37)), lineWidth: 0.8)
                    let cursor = x(clock.time)
                    g.fill(Path(CGRect(x: cursor, y: 0, width: 1.65, height: size.height)), with: .color(Palette.ivory))
                }
                .background(Palette.inset).clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { point in
                    onSeek(Double(min(1, max(0, point.location.x / max(1, geometry.size.width)))) * project.map.duration)
                })
            }.frame(height: 66).accessibilityHidden(true)
            Slider(value: Binding(get: { clock.time }, set: onSeek), in: 0...project.map.duration) {
                Text("Posição na gravação")
            }.labelsHidden().accessibilityValue(timeLabel(clock.time))
            HStack {
                Text(timeLabel(clock.time)); Spacer(); Text(timeLabel(project.map.duration))
            }.font(.system(.caption2, design: .monospaced)).foregroundStyle(Palette.muted)
            if let hints = project.map.vocalHints, !hints.isEmpty {
                Text("Marcas claras na base indicam trechos com voz provável.")
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
        }
    }
}

struct ScorePanel: View {
    @ObservedObject var clock: Playhead
    let project: Project
    let events: [Event]
    var onSeek: (Double) -> Void
    let report: (String) -> Void
    var edit: (() -> Void)?
    @State private var fixedPage: Int?
    @State private var whole = false
    @State private var playHarmonics = false

    var body: some View {
        let active = events.first { $0.time <= clock.time && clock.time < $0.end }
        let pages = scorePages
        let automatic = pages.firstIndex { $0.contains(clock.time) } ?? (clock.time > (pages.last?.upperBound ?? 0) ? pages.count - 1 : 0)
        let page = min(max(0, fixedPage ?? automatic), pages.count - 1)
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Tablatura").font(.system(size: 19, weight: .bold)).accessibilityAddTraits(.isHeader)
                if let phrase = project.phrase {
                    Text("\(phrase.name) · \(events.count) notas").font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("Harmônicos", isOn: $playHarmonics).toggleStyle(.button)
                    .help("Experimentar os harmônicos naturais nas casas 5, 7 e 12 a partir do capotraste")
                if let edit { Button("Editar notas", action: edit).disabled(events.isEmpty || project.transpose != 0 || project.capo != 0) }
            }
            if project.capo > 0 || events.contains(where: { $0.technique == .harmonic }) {
                Text([project.capo > 0 ? project.capoLabel : nil, events.contains(where: { $0.technique == .harmonic }) ? "◇ Harmônico natural · toque de leve sobre o traste indicado entre < >" : nil].compactMap { $0 }.joined(separator: "   ·   "))
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            PracticeBoard(clock: clock, events: events, seek: onSeek, project: project, harmonicMode: playHarmonics, report: report)
            Text(playHarmonics ? "Clique em um losango para ouvir o harmônico natural." : "Clique para tocar. Segure e arraste para cima ou para baixo para fazer um bend.")
                .font(.caption).foregroundStyle(Palette.muted)
            if events.isEmpty {
                Text("A tablatura aparece quando você escolhe um solo.")
                    .foregroundStyle(Palette.muted).padding(.vertical, 22)
            } else {
                HStack {
                    if let active, let index = events.firstIndex(where: { $0.id == active.id }) {
                        let target = pitchNames[pitchClass(active.pitch + active.amount)]
                        Text("Nota \(index + 1) · \(active.string + 1)ª corda · casa \(active.relativeFret) · \(active.technique.rawValue)" +
                             (active.technique == .bend ? " ↑ \(target) (+\(active.amount) st)" : ""))
                            .foregroundStyle(Palette.orange)
                    }
                    Spacer()
                    Button(whole ? "Acompanhar compasso" : "Tablatura inteira") { whole.toggle(); fixedPage = nil }
                        .disabled(pages.count < 2)
                }.font(.caption)
                if whole {
                    ForEach(pages.indices, id: \.self) { i in tablaturePage(pages[i]) }
                } else {
                    tablaturePage(pages[page])
                    if pages.count > 1 {
                        HStack(spacing: 8) {
                            Button { fixedPage = page - 1 } label: { Image(systemName: "chevron.left") }
                                .accessibilityLabel("Compassos anteriores").disabled(page == 0)
                            Text("\(page + 1) de \(pages.count)").foregroundStyle(Palette.muted).monospacedDigit()
                            Button { fixedPage = page + 1 } label: { Image(systemName: "chevron.right") }
                                .accessibilityLabel("Próximos compassos").disabled(page + 1 == pages.count)
                            if fixedPage != nil { Button("Seguir áudio") { fixedPage = nil } }
                        }.font(.caption)
                    }
                }
                DisclosureGroup("Notas do solo") {
                    ForEach(Array(events.enumerated()), id: \.element.id) { i, note in
                        Button {
                            onSeek(note.time + 0.001)
                        } label: {
                            Text("\(i + 1). \(note.time, specifier: "%.2f") s · \(note.string + 1)ª corda · casa \(note.relativeFret) · \(note.technique.rawValue) · \(note.duration, specifier: "%.2f") s")
                                .font(.caption).foregroundStyle(Palette.ivory)
                        }.buttonStyle(.plain)
                    }
                }.font(.caption)
            }
        }.padding(15).card().onChange(of: project.phrase?.id) { _, _ in fixedPage = nil }
    }

    private var scorePages: [ClosedRange<Double>] {
        let bar = 60 / project.map.bpm * Double(project.map.meter)
        let beatOffset = project.map.beatOffset
        let time = events.first?.time ?? project.passage.start
        let first = max(0, beatOffset + floor((time - beatOffset) / bar) * bar)
        let last = min(project.map.duration, max(first + bar, (events.last?.end ?? project.passage.end) + bar * 0.2))
        let page = bar * 2.0
        let count = max(1, Int(ceil((last - first) / page)))
        return (0..<count).map { index in
            let start = first + Double(index) * page
            return start...min(last, start + page)
        }
    }

    private func tablaturePage(_ range: ClosedRange<Double>) -> some View {
        Canvas { ctx, size in
            ctx.withCGContext { g in
                g.translateBy(x: 0, y: size.height); g.scaleBy(x: 1, y: -1)
                ScoreGraphics.tablature(events, range: range, grid: project.map, at: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 5),
                                         time: clock.time, dark: true, chords: true, transpose: project.shapeTranspose, in: g)
            }
        }.frame(height: 158).clipped().background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

struct TransportFace: View {
    @ObservedObject var session: Session
    @ObservedObject var clock: Playhead
    let range: ClosedRange<Double>
    let duration: Double
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: "waveform").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timeLabel(clock.time)).font(.system(size: 31, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("/ " + timeLabel(duration)).font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
            }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, clock.time)) }, set: session.seek), in: range) {
                Text("Posição na gravação")
            }.labelsHidden().accessibilityValue(timeLabel(clock.time))
            HStack(spacing: 8) {
                Button(action: session.play) {
                    Label(session.playback ? "Pausar" : "Play", systemImage: session.playback ? "pause.fill" : "play.fill").frame(minWidth: 58)
                }.buttonStyle(ForgeButton()).keyboardShortcut(.space, modifiers: [])
                    .accessibilityIdentifier("transport-play").disabled(session.rendering)
                Button(action: session.stop) { Label("Stop", systemImage: "stop.fill") }
                    .controlSize(.large).tint(.secondary).accessibilityIdentifier("transport-stop").help("Voltar ao início da reprodução")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TransportSidebar: View {
    @ObservedObject var session: Session
    @ObservedObject var clock: Playhead
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TransportFace(session: session, clock: clock, range: 0...project.map.duration, duration: project.map.duration, title: "Player")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if project.arrangement != nil {
                        Button(action: session.playSequence) {
                            Label(session.sequenceMode && session.playback ? "Pausar sequência" : (project.showingFeatured ? "Ouvir na música" : "Ouvir sequência"),
                                  systemImage: "music.note.list")
                        }.disabled(session.rendering)
                    }
                    Toggle(isOn: bind(\.loop)) { Label("Repetir A–B", systemImage: "repeat") }
                        .toggleStyle(.button).disabled(session.sequenceMode)
                    Button { session.seek(project.passage.start) } label: {
                        Label("Início do trecho", systemImage: "backward.end.fill")
                    }
                    Picker("Velocidade", selection: bind(\.speed)) {
                        ForEach([0.5, 0.65, 0.8, 1.0, 1.25], id: \.self) {
                            Text(String(format: "%.2fx", $0)).tag($0)
                        }
                    }
                    Picker("Timbre", selection: Binding(get: { project.ampPreset }, set: { if let value = $0 { session.changePreset(value) } })) {
                        if project.ampPreset == nil { Text("Atual").tag(nil as AmpPreset?) }
                        ForEach(AmpPreset.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    Divider()
                    volume("Gravação", \.musicVolume, $session.muteRecording) {
                        session.muteRecording = false; session.muteLead.toggle()
                    }
                    volume("Solo", \.leadVolume, $session.muteLead) {
                        session.muteLead = false; session.muteRecording.toggle()
                    }
                }.padding(.vertical, 3).padding(.horizontal, 2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(15).frame(maxHeight: .infinity, alignment: .topLeading).background(Palette.inset)
        .accessibilityElement(children: .contain)
    }

    private func volume(_ label: String, _ key: WritableKeyPath<Project, Double>, _ mute: Binding<Bool>, solo: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.callout.weight(.semibold))
                Spacer()
                Button { mute.wrappedValue.toggle() } label: {
                    Image(systemName: mute.wrappedValue ? "speaker.slash.fill" : "speaker.wave.1")
                }.accessibilityLabel(mute.wrappedValue ? "Ativar " + label : "Silenciar " + label)
                Button("S", action: solo).accessibilityLabel("Ouvir só " + label).help("Ouvir só " + label)
            }
            Slider(value: bind(key), in: 0...1) { Text("Volume " + label) }.labelsHidden()
        }
    }
    private func bind<T>(_ path: WritableKeyPath<Project, T>) -> Binding<T> {
        Binding(get: { project[keyPath: path] }, set: { value in session.modify { $0[keyPath: path] = value } })
    }
}

struct PresentationControls: View {
    let project: Project
    @ObservedObject var session: Session
    @State private var presetName = ""
    var body: some View {
        GroupBox("Timbre e transposição") {
            VStack(alignment: .leading, spacing: 8) {
                tone("Drive", \.drive)
                tone("Ambiência", \.room)
                tone("Delay", \.delay)
                tone(project.preferences.instrument == .acoustic ? "Sustain" : "Sustainer", \.sustain)
                Button("Restaurar timbre sugerido") {
                    session.modify({ $0.tone = Tone.suggested($0.preferences.instrument) }, rebuildAudio: true, record: true)
                }
                presets
                Divider()
                HStack {
                    Button { session.transpose(project.transpose - 1, includeRecording: project.transposeRecording) } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Descer um semitom").disabled(project.transpose <= -12)
                    Text("\(project.transpose > 0 ? "+" : "")\(project.transpose) semitons").font(.caption.monospacedDigit())
                    Button { session.transpose(project.transpose + 1, includeRecording: project.transposeRecording) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Subir um semitom").disabled(project.transpose >= 12)
                    Button("Restaurar") { session.transpose(0, includeRecording: false) }.disabled(project.transpose == 0)
                }
                if project.transpose != 0 {
                    Toggle("Transpor também a gravação", isOn: Binding(get: { project.transposeRecording },
                           set: { session.transpose(project.transpose, includeRecording: $0) })).font(.caption)
                    Text(project.transposeRecording ? "Solo e gravação no mesmo tom." : "Modo banda · apenas o solo transposto.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Stepper("Região do braço: casa \(project.preferences.position)", value: Binding(get: { project.preferences.position }, set: session.moveFingering), in: 0...17)
                    .font(.caption)
            }.padding(.top, 8)
        }
    }
    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Nome do preset", text: $presetName).font(.caption)
                Button("Salvar") {
                    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.modify({ state in
                        var items = state.tonePresets ?? []
                        if let existing = items.firstIndex(where: { $0.name == name }) {
                            items[existing].instrument = state.preferences.instrument
                            items[existing].tone = state.tone
                        } else {
                            items.append(TonePreset(name: name, instrument: state.preferences.instrument, tone: state.tone))
                        }
                        state.tonePresets = items
                    }, record: true)
                    presetName = ""
                }.disabled(!(1...48).contains(presetName.trimmingCharacters(in: .whitespacesAndNewlines).count))
            }
            if let items = project.tonePresets, !items.isEmpty {
                Menu("Presets do projeto") {
                    ForEach(items) { preset in
                        Button(preset.name) {
                            session.modify({ $0.tone = preset.tone; $0.preferences.instrument = preset.instrument }, rebuildAudio: true, record: true)
                            presetName = preset.name
                        }
                    }
                    Divider()
                    ForEach(items) { preset in
                        Button("Remover \(preset.name)", role: .destructive) {
                            session.modify({ $0.tonePresets?.removeAll { $0.id == preset.id } }, record: true)
                        }
                    }
                }
            }
        }
    }
    private func tone(_ label: String, _ path: WritableKeyPath<Tone, Double>) -> some View {
        Slider(value: Binding(get: { project.tone[keyPath: path] },
                              set: { value in session.modify({ $0.tone[keyPath: path] = value }, rebuildAudio: true) }), in: 0...1) {
            Text(label).font(.caption).frame(width: 66, alignment: .leading)
        }
    }
}
