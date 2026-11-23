import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct StudyTransport: View {
    @ObservedObject var session: Session
    @ObservedObject var clock: Playhead
    let duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TransportFace(session: session, clock: clock, range: session.studyRange ?? 0...duration,
                          duration: duration, title: session.studySourceTitle)
            Divider()
            Toggle("Repetir trecho", isOn: $session.studyLoop).toggleStyle(.button)
            Picker("Velocidade", selection: $session.studySpeed) {
                ForEach([0.5, 0.65, 0.8, 1, 1.25], id: \.self) { Text($0.formatted() + "×").tag($0) }
            }
            if session.studyRange != nil {
                Button("Ouvir faixa inteira") { session.selectStudyRange(nil); session.play() }
            }
            Spacer()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecordingStudyView: View {
    let project: Project
    @ObservedObject var session: Session
    @State private var selection: UUID?
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var showCifra = false
    @State private var includeUncertain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Estúdio de estudo").font(.title2.bold())
                Spacer()
                Picker("Material da gravação", selection: $showCifra) {
                    Text("Tablatura").tag(false)
                    Text("Cifra").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 185)
            }
            if let study = project.recordingStudy {
                if showCifra { chordSheet(study) }
                else { melody(study) }
            } else if session.busy == nil {
                Text("Procure solos na gravação inteira ou analise um trecho.")
                scanControls
            } else {
                Text("Analisando o áudio original no Mac…").foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                start = project.recordingStudy?.passage.start ?? 0
                end = project.recordingStudy?.passage.end ?? min(600, project.map.duration)
            }
            .onChange(of: showCifra) { _, cifra in
                if cifra { session.selectStudyRange(nil) }
                else if let line = selectedLine { focus(line) }
            }
    }

    private var selectedLine: Phrase? {
        let lines = (project.recordingStudy?.lines ?? []).filter { includeUncertain || $0.uncertainStudyLine != true }
        return lines.first { $0.id == selection } ?? lines.first
    }

    private func focus(_ line: Phrase) {
        selection = line.id
        if let first = line.events.first, let last = line.events.last { session.selectStudyRange(first.time...last.end) }
    }

    private var scanControls: some View {
        HStack {
            Button("Procurar solos na música") { start = 0; end = project.map.duration; session.analyzeRecording(from: 0, to: end) }
            Text("De")
            TimeInput(value: start, maximum: max(0, end - 1)) { start = $0 }
            Text("até")
            TimeInput(value: end, maximum: project.map.duration) { end = max(start + 1, $0) }
            Text("s").foregroundStyle(Palette.muted)
            Button("Analisar trecho") { session.analyzeRecording(from: start, to: end) }
            Button("Usar pista de guitarra…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio]
                panel.message = "Escolha a guitarra isolada com o mesmo início e duração da gravação."
                if panel.runModal() == .OK, let url = panel.url { session.analyzeRecording(from: start, to: end, guitarTrack: url) }
            }
        }.disabled(session.busy != nil)
    }

    private func melody(_ study: RecordingStudy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if (study.analysisVersion ?? 1) < RecordingStudy.currentAnalysisVersion && study.usedGuitarTrack {
                    Text("Para atualizar os tempos desta transcrição, selecione novamente a pista de guitarra.").font(.callout)
                }
                Text(study.usedGuitarTrack ? "Transcrição da pista de guitarra · digitação sugerida" :
                     ((study.analysisVersion ?? 1) >= RecordingStudy.currentAnalysisVersion ? "Guitarra separada da gravação · digitação sugerida" : "Transcrição anterior da mixagem"))
                    .font(.callout).foregroundStyle(Palette.muted)
                scanControls
                let uncertainCount = study.lines.filter { $0.uncertainStudyLine == true }.count
                if uncertainCount > 0 {
                    Toggle("Incluir frases incertas (\(uncertainCount))", isOn: $includeUncertain)
                        .onChange(of: includeUncertain) { _, _ in
                            if let line = selectedLine { focus(line) } else { session.selectStudyRange(nil) }
                        }
                }
                if session.hasStudyAudio {
                    Button("Ouvir guitarra isolada") {
                        if let line = selectedLine, let first = line.events.first, let last = line.events.last {
                            session.auditionStudyGuitar(first.time...last.end)
                        } else { session.auditionStudyGuitar(study.passage.start...study.passage.end) }
                    }
                }
                if let line = selectedLine {
                    HStack {
                        Picker("Passagem", selection: Binding(get: { line.id }, set: { id in
                            if let item = study.lines.first(where: { $0.id == id }) { focus(item) }
                        })) {
                            ForEach(study.lines.filter { includeUncertain || $0.uncertainStudyLine != true }) { item in
                                Text("\(item.name) · \(timeLabel(item.events.first?.time ?? 0))–\(timeLabel(item.events.last?.end ?? 0))").tag(item.id)
                            }
                        }.fixedSize()
                        let active = session.studySoloID == line.id
                        let preparing = active && session.rendering
                        Button {
                            session.auditionStudyLine(line.id)
                        } label: {
                            Label(preparing ? "Preparando solo…" : (active && session.playback ? "Pausar tablatura" : "Ouvir tablatura"),
                                  systemImage: active && session.playback ? "pause.fill" : "guitars")
                        }.disabled(preparing)
                            .help("Tocar somente as notas transcritas desta passagem")
                        Button("Ouvir na gravação") { focus(line); session.play() }
                    }
                    ScorePanel(clock: session.clock, project: presentation(study, line: line),
                               events: line.events, onSeek: session.seek, report: { session.notice = $0 }, edit: nil)
                        .onAppear { focus(line) }
                        .onChange(of: line.id) { _, _ in focus(line) }
                } else {
                    Text("Nenhum solo de guitarra identificado com segurança neste intervalo. Uma pista de guitarra isolada permite transcrever também as frases mais discretas.")
                        .padding(.vertical)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func presentation(_ study: RecordingStudy, line: Phrase? = nil) -> Project {
        var source = Project(name: project.name, sourceHash: project.sourceHash, map: study.map)
        source.passage = study.passage
        source.alternatives = line.map { [$0] } ?? []
        source.lyrics = study.lyrics ?? []
        return source
    }

    private func chordSheet(_ study: RecordingStudy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Acordes estimados da gravação").font(.headline)
                Spacer()
                if study.lyrics?.isEmpty != false {
                    Button("Transcrever letra com Whisper", action: session.studyLyrics)
                }
                Button("Importar cifra de referência…") { importSheet() }
            }.disabled(session.busy != nil)
            if let sheet = study.referenceSheet {
                DisclosureGroup("Cifra de referência importada") {
                    ScrollView([.horizontal, .vertical]) { Text(sheet).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                        .frame(maxHeight: 230)
                }
            }
            if study.lyrics?.isEmpty == false {
                WordChordSheet(clock: session.clock, project: presentation(study), seek: session.seek)
            } else {
                let chords = study.map.chords.filter { $0.confidence >= 0.12 }
                if chords.isEmpty { Text("Nenhum acorde identificado com confiança suficiente.") }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 97))], alignment: .leading) {
                        ForEach(chords) { chord in
                            Button { session.seek(chord.start) } label: {
                                VStack { Text(chord.label).font(.headline); Text(timeLabel(chord.start)).font(.caption.monospacedDigit()) }
                                    .frame(maxWidth: .infinity).padding(5)
                            }.help("Ir ao acorde na gravação")
                        }
                    }
                }
            }
        }
    }

    private func importSheet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, (1...256_000).contains(size),
                  let sheet = String(data: try Data(contentsOf: url), encoding: .utf8),
                  !sheet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkError.audio("Escolha uma cifra de texto UTF-8 de até 256 KB.")
            }
            session.modify { $0.recordingStudy?.referenceSheet = sheet }
        } catch { session.notice = error.localizedDescription }
    }
}
