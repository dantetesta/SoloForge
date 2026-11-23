import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: Session
    @State private var title = ""
    @State private var selected: URL?
    var body: some View {
        Dialog(title: "Nova tablatura", subtitle: "Escolha uma gravação para analisar neste Mac.") {
            TextField("Nome da música", text: $title).textFieldStyle(.roundedBorder)
            HStack {
                Text(selected?.lastPathComponent ?? "MP3, WAV ou M4A").lineLimit(1).foregroundStyle(Palette.muted)
                Spacer()
                Button("Escolher áudio…", action: choose)
                    .accessibilityIdentifier("choose-recording")
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Importar e analisar") {
                    if let selected { session.importAudio(selected, name: title.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                }.keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200)
            }
        }.frame(width: 490)
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Store.sourceExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selected = url
        if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
    }
}

struct MapEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var map: AudioMap
    @ObservedObject var session: Session
    @State private var newChordTime = 0.0
    var body: some View {
        Dialog(title: "Corrigir análise", subtitle: "Defina a grade de batidas e revise a harmonia por trecho.") {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Andamento (BPM)").font(.caption)
                    TextField("BPM", value: $map.bpm, format: .number.precision(.fractionLength(0...2))).frame(width: 110)
                        .onChange(of: map.bpm) { _, _ in map.tempoConfidence = 1 }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Primeiro tempo forte (s)").font(.caption)
                    TextField("Alinhamento", value: $map.beatOffset, format: .number.precision(.fractionLength(0...3))).frame(width: 145)
                }
                Picker("Compasso", selection: $map.meter) {
                    ForEach(2...7, id: \.self) { Text("\($0)/4").tag($0) }
                }
            }
            HStack {
                Picker("Tom global", selection: $map.key.root) {
                    ForEach(0..<12) { Text(pitchNames[$0]).tag($0) }
                }.fixedSize()
                Toggle("Menor", isOn: $map.key.minor)
                Spacer()
            }.onChange(of: map.key) { _, _ in map.keyConfidence = 1 }
            Divider()
            HStack {
                Text("Acordes por intervalo").font(.headline)
                Spacer()
                Text("Início (s)").font(.caption)
                TextField("Início do novo acorde", value: $newChordTime, format: .number).frame(width: 59)
                Button("Adicionar acorde") { addChord() }
                    .disabled(!(0..<map.duration).contains(newChordTime))
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($map.chords) { $chord in
                        chordRow($chord)
                    }
                    if map.chords.isEmpty { Text("A faixa ainda não tem acordes marcados.").foregroundStyle(Palette.muted) }
                }
            }.frame(height: 231)
            HStack {
                Text("Os acordes e o tom global podem ser corrigidos separadamente.").font(.caption).foregroundStyle(Palette.muted)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aplicar") {
                    if let project = session.current {
                        var preview = project
                        preview.map = normalizedMap()
                        do {
                            try Music.validate(preview)
                            session.modify({ $0.map = preview.map }, record: true); dismiss()
                        } catch { session.notice = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.frame(width: 657)
    }
    private func chordRow(_ chord: Binding<Chord>) -> some View {
        HStack(spacing: 9) {
            TextField("Início", value: chord.start, format: .number.precision(.fractionLength(0...2))).frame(width: 65)
            Text("até").font(.caption)
            TextField("Fim", value: chord.end, format: .number.precision(.fractionLength(0...2))).frame(width: 65)
            Picker("Raiz", selection: chord.root) {
                ForEach(0..<12) { Text(pitchNames[$0]).tag($0) }
            }.labelsHidden().fixedSize()
            Picker("Qualidade", selection: chord.quality) {
                ForEach(ChordQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 112)
            Text(chord.wrappedValue.confidence == 1 ? "Manual" : "Confiança \(certainty(chord.wrappedValue.confidence))").font(.caption).foregroundStyle(Palette.muted)
            Spacer()
            Button(role: .destructive) {
                let id = chord.wrappedValue.id
                map.chords.removeAll { $0.id == id }
            } label: { Image(systemName: "trash") }.accessibilityLabel("Remover acorde")
        }
        .onChange(of: chord.wrappedValue.root) { _, _ in chord.confidence.wrappedValue = 1 }
        .onChange(of: chord.wrappedValue.quality) { _, _ in chord.confidence.wrappedValue = 1 }
        .onChange(of: chord.wrappedValue.start) { _, _ in chord.confidence.wrappedValue = 1 }
        .onChange(of: chord.wrappedValue.end) { _, _ in chord.confidence.wrappedValue = 1 }
    }
    private func addChord() {
        let start = newChordTime
        let nearest = map.chords.filter { $0.start > start }.map(\.start).min()
        let end = min(nearest ?? map.duration, map.duration, start + 60 / min(250, max(35, map.bpm)) * Double(map.meter))
        if end > start {
            map.chords.append(Chord(start: start, end: end, root: map.key.root, minor: map.key.minor, confidence: 1))
            newChordTime = end
        }
    }
    private func normalizedMap() -> AudioMap {
        var result = map
        result.chords.sort { $0.start < $1.start }
        return result
    }
}

struct NoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let phrase: Phrase
    @ObservedObject var session: Session
    @State private var events: [Event]
    @State private var errorText: String?
    init(project: Project, phrase: Phrase, session: Session) {
        self.project = project; self.phrase = phrase; self.session = session
        _events = State(initialValue: phrase.events)
    }
    var body: some View {
        Dialog(title: "Editar notas", subtitle: "Os tempos são absolutos na gravação. Os espaços entre notas funcionam como pausas.") {
            HStack {
                Text("Início (s)").frame(width: 81)
                Text("Duração (s)").frame(width: 82)
                Text("Corda").frame(width: 62)
                Text("Casa").frame(width: 66)
                Text("Intensidade").frame(width: 64)
                Text("Técnica").frame(width: 104)
                Text("Semitons").frame(width: 60)
                Spacer()
            }.font(.caption).foregroundStyle(Palette.muted)
            ScrollView {
                VStack(spacing: 7) {
                    ForEach($events) { $note in
                        row($note)
                    }
                }
            }.frame(height: 254)
            HStack {
                Button("Adicionar nota") { add() }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aplicar") { apply() }.keyboardShortcut(.defaultAction)
            }
        }.frame(width: 745)
    }
    private func row(_ note: Binding<Event>) -> some View {
        HStack {
            TextField("Início", value: note.time, format: .number.precision(.fractionLength(0...3))).frame(width: 80)
            TextField("Duração", value: note.duration, format: .number.precision(.fractionLength(0...3))).frame(width: 80)
            Picker("Corda", selection: note.string) {
                ForEach(0..<6) { Text("\($0 + 1)").tag($0) }
            }.labelsHidden().frame(width: 60)
            TextField("Casa", value: note.fret, format: .number).frame(width: 64)
            TextField("Intensidade", value: note.velocity, format: .number.precision(.fractionLength(0...2))).frame(width: 63)
            Picker("Técnica", selection: note.technique) {
                ForEach(Music.allowedTechniques(phrase.level), id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 103)
            TextField("Semitons", value: note.amount, format: .number).frame(width: 60)
                .disabled(note.wrappedValue.technique != .slide && note.wrappedValue.technique != .bend)
            Button(role: .destructive) {
                let id = note.wrappedValue.id
                events.removeAll { $0.id == id }
            } label: { Image(systemName: "trash") }.accessibilityLabel("Remover nota")
        }.onChange(of: note.wrappedValue.technique) { _, value in
            if value == .harmonic, Event.harmonicIntervals[note.wrappedValue.fret] == nil {
                note.fret.wrappedValue = 12
            }
            note.amount.wrappedValue = (value == .slide || value == .bend) ? 1 : 0
        }
    }
    private func add() {
        let start = max(project.passage.start, (events.map(\.end).max() ?? project.passage.start) + 0.10)
        let rest = project.map.duration - start
        if rest >= 0.06 {
            events.append(Event(time: start, duration: min(0.25, rest), string: 1, fret: 5, velocity: 0.75))
        } else { errorText = "As notas já alcançam o fim da gravação." }
    }
    private func apply() {
        let sorted = events.sorted { $0.time < $1.time }
        do {
            try Music.validate(sorted, in: Passage("", 0, project.map.duration), level: phrase.level)
            session.modify({ value in
                guard let index = value.alternatives.firstIndex(where: { $0.id == phrase.id }) else { return }
                value.alternatives[index].events = sorted
            }, rebuildAudio: true, record: true)
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

struct LyricEditor: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @ObservedObject var session: Session
    @State private var lines: [Lyric] = []
    @State private var message: String?
    var body: some View {
        Dialog(title: "Letra e alinhamento", subtitle: "Adicione somente versos que você tem direito de usar. Cada verso começa no tempo informado.") {
            ScrollView {
                VStack {
                    ForEach($lines) { $line in
                        HStack {
                            TextField("Segundos", value: $line.time, format: .number.precision(.fractionLength(0...3))).frame(width: 86)
                            TextField("Verso", text: $line.text)
                            Button(role: .destructive) {
                                let id = line.id; lines.removeAll { $0.id == id }
                            } label: { Image(systemName: "trash") }.accessibilityLabel("Remover verso")
                        }
                    }
                }
            }.frame(height: 235)
            HStack {
                Button("Adicionar verso") { lines.append(Lyric(time: session.clock.time, text: "")) }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar letra") {
                    guard lines.allSatisfy({ (0...project.map.duration).contains($0.time) && $0.text.count <= 600 }) else {
                        message = "Revise o tempo ou tamanho dos versos."; return
                    }
                    let adjusted = lines.filter { !$0.text.isEmpty }.map { line -> Lyric in
                        var value = line
                        guard let original = project.lyrics.first(where: { $0.id == line.id }), let timed = original.words else { return value }
                        let typed = line.text.split(whereSeparator: \.isWhitespace)
                        if typed.count == timed.count {
                            let shift = line.time - original.time
                            value.words = zip(typed, timed).map { word, old in
                                TimedWord(start: min(project.map.duration, max(0, old.start + shift)),
                                          end: min(project.map.duration, max(0, old.end + shift)), text: String(word))
                            }
                        } else { value.words = nil }
                        return value
                    }
                    session.modify({ $0.lyrics = adjusted.sorted { $0.time < $1.time } }, record: true)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }.frame(width: 575).onAppear { lines = project.lyrics }
    }
}

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: ExportKind
    let project: Project
    @ObservedObject var session: Session
    @State private var options = ExportOptions()
    var body: some View {
        Dialog(title: kind.rawValue, subtitle: "Escolha os dados da exportação.") {
            if kind == .pdf {
                Toggle("Incluir cifra", isOn: $options.includeChords).disabled(!project.chordSheet)
                Text("PDF A4 em paisagem com compassos, pausas, notas e legenda de técnicas.").font(.caption).foregroundStyle(Palette.muted)
            } else {
                Toggle("Usar a gravação inteira", isOn: $options.entireSong)
                if kind == .video {
                    Picker("Resolução", selection: $options.height) {
                        ForEach([540, 720, 1080], id: \.self) { Text("\($0)p · 30 fps").tag($0) }
                    }.fixedSize()
                    Toggle("Incluir a gravação na mixagem", isOn: $options.music)
                }
                if kind == .mix || (kind == .video && options.music) {
                    Text("Use a mixagem somente onde você tem autorização para compartilhar a gravação.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Escolher destino…") {
                    let snapshot = options
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { session.export(kind, options: snapshot) }
                }.keyboardShortcut(.defaultAction)
            }
        }.frame(width: 520)
    }
}

struct DirectionSettings: View {
    @State private var draft = ""
    private enum Access: String {
        case checking = "Verificando acesso ao Chaves…"
        case configured = "Chave configurada"
        case missing = "Nenhuma chave configurada"
        case unavailable = "Acesso ao Chaves não confirmado"
    }
    @State private var access = Access.checking
    @State private var working = false
    @State private var message = ""
    @State private var whisperName = ""
    var body: some View {
        Dialog(title: "OpenAI", subtitle: "A chave habilita a geração de solos completos e fica no Chaves do macOS.") {
            SecureField("Chave de API OpenAI", text: $draft)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("openai-api-key").disabled(working)
            HStack {
                Text(access.rawValue).foregroundStyle(access == .configured ? .green : Palette.muted)
                Spacer()
                Button("Verificar acesso") { refresh() }
                Button("Remover chave", role: .destructive) {
                    perform { try KeyVault.openAI.remove(); return .missing }
                }.disabled(access != .configured)
                Button("Salvar no Chaves") {
                    let input = draft
                    perform { try KeyVault.openAI.save(input); return .configured }
                }.disabled(draft.isEmpty)
            }.disabled(working)
            Text("\(Director.modelName) recebe o mapa musical. O uso é cobrado pela API e tem limite de \(Director.outputLimit) tokens de saída por geração.")
                .font(.caption).foregroundStyle(Palette.muted)
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Text("Whisper local").font(.headline)
                    Text(whisperName).font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Selecionar modelo…", action: chooseWhisper)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Palette.orange) }
        }.frame(width: 532).onAppear { refresh(); refreshWhisper() }
    }
    private func chooseWhisper() {
        let panel = NSOpenPanel()
        panel.title = "Escolher modelo Whisper multilíngue"
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: WhisperLocal.modelPreference)
        refreshWhisper()
    }
    private func refreshWhisper() {
        whisperName = WhisperLocal.modelURL?.lastPathComponent ?? "Selecione um modelo Whisper .bin neste Mac."
    }
    private func refresh() {
        perform(clearDraft: false) { try KeyVault.openAI.read() == nil ? .missing : .configured }
    }

    private func perform(clearDraft: Bool = true, _ work: @escaping @Sendable () throws -> Access) {
        guard !working else { return }
        working = true
        message = ""
        Task {
            defer { working = false }
            do {
                access = try await Task.detached(priority: .userInitiated) { try work() }.value
                if clearDraft { draft = "" }
            } catch {
                if let failure = error as? DirectionError, case .invalidKey = failure {
                    message = failure.localizedDescription
                } else {
                    access = .unavailable
                    message = error.localizedDescription
                }
            }
        }
    }
}

struct Dialog<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title).font(.system(size: 23, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(Palette.muted)
            content
        }.padding(23).background(Palette.surface).foregroundStyle(Palette.ivory).tint(Palette.orange)
    }
}
