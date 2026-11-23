import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

private enum Brand {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "SoloForge" }
    static var mark: NSImage? { Bundle.main.url(forResource: "Wordmark", withExtension: "png").flatMap(NSImage.init(contentsOf:)) }
}

enum Palette {
    static let background = Color(red: 0.083, green: 0.084, blue: 0.092)
    static let backgroundWarm = Color(red: 0.125, green: 0.117, blue: 0.116)
    static let surface = Color(red: 0.136, green: 0.137, blue: 0.148)
    static let inset = Color(red: 0.105, green: 0.106, blue: 0.116)
    static let stroke = Color(red: 0.255, green: 0.254, blue: 0.267)
    static let muted = Color(red: 0.75, green: 0.74, blue: 0.74)
    static let ivory = Color(red: 0.98, green: 0.944, blue: 0.886)
    static let orange = Color(red: 1, green: 0.46, blue: 0.19)
    static let paper = Color(red: 0.974, green: 0.938, blue: 0.884)
}

@main
enum Entry {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--verificar-chaves"] {
            do {
                let configured = try KeyVault.openAI.read(allowInteraction: false) != nil
                print(configured ? "Chave configurada e acessível." : "Nenhuma chave configurada.")
                exit(configured ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        if ["--validate", "--validate-arrangement", "--validate-solo"].contains(arguments.first ?? "") {
            do {
                let parameters = Array(arguments.dropFirst())
                if ["--validate-arrangement", "--validate-solo"].contains(arguments.first) {
                    try ArrangementValidation.run(parameters, featured: arguments.first == "--validate-solo")
                }
                else { try Validation.run(parameters) }
            }
            catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            return
        }
        WorkbenchApp.main()
    }
}

struct WorkbenchApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        Window("SoloForge", id: "workspace") {
            Workspace(session: session)
                .frame(minWidth: 975, minHeight: 650)
                .preferredColorScheme(.dark)
                .onOpenURL { session.openURL($0) }
        }
        .defaultSize(width: 1200, height: 870)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Salvar projeto") { session.save() }.keyboardShortcut("s").disabled(session.current == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Desfazer alteração musical") { session.undo() }.keyboardShortcut("z").disabled(session.studying || !session.canUndo)
            }
        }
        Settings { DirectionSettings().preferredColorScheme(.dark) }
    }
}

struct Workspace: View {
    @ObservedObject var session: Session
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceTransparency) private var solidSurfaces
    @State private var newProject = false
    @State private var mapEditor = false
    @State private var scoreEditor = false
    @State private var notation = false
    @State private var exportOptions: ExportKind?
    @State private var showingRemoved = false
    @State private var deletionTarget: Project?
    private enum EditorTab { case tablature, chords }
    @State private var editorTab = EditorTab.tablature
    @State private var nextLevel: Level = .basic
    @State private var advanced = false
    @State private var correctMapAfterSettings = false
    @State private var capoSheet = false
    @State private var resetID: UUID?
    @State private var clearLyrics = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if let busy = session.busy { progressBand(busy) }
            if let project = session.current {
                editor(project)
                    .onChange(of: project.id, initial: true) { _, _ in
                        advanced = false
                        editorTab = .tablature
                        nextLevel = project.preferences.level
                    }
                    .onChange(of: project.preferences.level) { _, level in nextLevel = level }
            } else { home }
        }
        .background(
            LinearGradient(colors: [Palette.backgroundWarm, Palette.background, Palette.background], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .foregroundStyle(Palette.ivory)
        .tint(Palette.orange)
        .alert("SoloForge", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
            Button("OK") { session.notice = nil }
        } message: { Text(session.notice ?? "") }
        .alert("Conectar OpenAI", isPresented: $session.needsOpenAI) {
            Button("Abrir preferências") { openSettings() }
            Button("Fechar", role: .cancel) {}
        } message: {
            Text("Salve a chave nos ajustes do SoloForge e clique em Gerar solos completos para começar.")
        }
        .sheet(isPresented: $newProject) { ImportSheet(session: session) }
        .sheet(isPresented: $advanced, onDismiss: {
            resetID = nil
            if correctMapAfterSettings { correctMapAfterSettings = false; mapEditor = true }
        }) {
            if let project = session.current {
                if resetID == project.id {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Recomeçar “\(project.name)”?").font(.title2.bold())
                        if project.hasGeneratedSolos {
                            Text("Isso apaga os solos, as tablaturas e as partes anteriores desta música, incluindo opções salvas e notas editadas.")
                        }
                        if project.hasLyricsOrChords {
                            Toggle("Apagar também a letra e a cifra, incluindo edições", isOn: $clearLyrics)
                        }
                        Text("A gravação e o mapa musical serão mantidos. Você pode desfazer com ⌘Z enquanto o projeto estiver aberto.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Cancelar") { resetID = nil }.keyboardShortcut(.cancelAction)
                            Button("Apagar e recomeçar", role: .destructive) {
                                if session.resetGeneratedMusic(projectID: project.id, includingLyrics: clearLyrics) {
                                    editorTab = .tablature
                                }
                                advanced = false
                            }.disabled(!project.hasGeneratedSolos && !clearLyrics || session.busy != nil)
                        }
                    }.padding(22).frame(width: 520)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Ajustes do projeto").font(.title2.bold())
                            Spacer()
                            Button("Concluir") { advanced = false }.keyboardShortcut(.defaultAction)
                        }
                        ScrollView { advancedControls(project) }
                        Divider()
                        Button("Recomeçar música…", role: .destructive) {
                            clearLyrics = true
                            resetID = project.id
                        }.disabled(session.busy != nil || (!project.hasGeneratedSolos && !project.hasLyricsOrChords))
                    }.padding(20).frame(width: 630, height: 470)
                        .onExitCommand { advanced = false }
                }
            }
        }
        .sheet(isPresented: $mapEditor) {
            if let project = session.current { MapEditor(map: project.map, session: session) }
        }
        .sheet(isPresented: $capoSheet) {
            if let project = session.current { CapoSheet(project: project, session: session) }
        }
        .sheet(isPresented: $scoreEditor) {
            if let project = session.current, let phrase = project.phrase { NoteEditor(project: project, phrase: phrase, session: session) }
        }
        .sheet(isPresented: $notation) {
            if let project = session.current { LyricEditor(project: project, session: session) }
        }
        .sheet(item: $exportOptions) { kind in
            if let project = session.current { ExportSheet(kind: kind, project: project, session: session) }
        }
    }

    private var header: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1320
            HStack(spacing: compact ? 6 : 10) {
                Group {
                    if let mark = Brand.mark {
                        Image(nsImage: mark).resizable().scaledToFit().padding(3)
                            .frame(width: compact ? 72 : 92, height: 32).accessibilityLabel(Brand.name)
                    } else {
                        Text(Brand.name).font(.headline).padding(6).foregroundStyle(Palette.background)
                    }
                }
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 5))
                if let project = session.current {
                    Button { session.home() } label: { Label("Projetos", systemImage: "square.grid.2x2") }
                        .help("Projetos").disabled(session.busy != nil)
                    Divider().frame(height: 25)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.headline).lineLimit(1).truncationMode(.tail)
                            .accessibilityAddTraits(.isHeader)
                            .help([project.name, project.arrangement?.model].compactMap { $0 }.joined(separator: " · "))
                        let sourceMap = project.recordingStudy?.map
                        let key = session.studying ? sourceMap?.key.label : project.presentedKey.label
                        let grid = session.studying ? sourceMap : project.map
                        if let key, let grid {
                            Text("\(key) · \(Int(grid.bpm.rounded())) BPM · \(grid.meter)/4")
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(Palette.muted)
                            .fixedSize()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if session.studying {
                        Label(session.studySourceTitle, systemImage: session.studySoloID == nil ? "waveform" : "guitars")
                            .labelStyle(.titleAndIcon).font(.callout).foregroundStyle(Palette.muted)
                    } else {
                        levelControls(compact: compact)
                        Button {
                            session.generateSong(nextLevel)
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(compact ? "Gerar solos" : "Gerar solos completos").font(.callout.bold())
                                Text("OpenAI · uso pago").font(.caption2)
                            }.padding(.horizontal, 2)
                        }
                        .buttonStyle(.borderedProminent).tint(Palette.orange)
                        .accessibilityLabel("Gerar solos completos no nível \(nextLevel.rawValue), uso pago da OpenAI")
                        .disabled(session.busy != nil)
                        Divider().frame(height: 25)
                        Button { capoSheet = true } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "tuningfork")
                                if !compact { Text("Capotraste") }
                                if project.capo > 0 { Text("\(project.capo)").monospacedDigit() }
                            }
                        }.help("Capotraste").accessibilityLabel("Capotraste, casa \(project.capo)")
                            .disabled(session.busy != nil)
                        Button { advanced = true } label: { Label("Ajustes", systemImage: "slider.horizontal.3") }
                            .help("Ajustes do projeto").accessibilityLabel("Ajustes do projeto")
                        Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .help("Desfazer alteração musical").accessibilityLabel("Desfazer alteração musical").disabled(!session.canUndo)
                        Menu {
                            ForEach(ExportKind.allCases, id: \.self) { kind in
                                Button(kind.rawValue) {
                                    if kind == .project { session.export(kind) } else { exportOptions = kind }
                                }.disabled(kind != .project && project.phrase == nil)
                            }
                        } label: { Label("Exportar", systemImage: "square.and.arrow.up") }
                        .fixedSize().help("Exportar").disabled(session.busy != nil)
                    }
                } else { Spacer() }
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .help("Preferências do SoloForge").accessibilityLabel("Preferências do SoloForge")
            }
            .labelStyle(ToolbarLabelStyle(compact: compact))
            .controlSize(compact ? .small : .regular).buttonStyle(.bordered).tint(.secondary)
            .padding(.horizontal, compact ? 10 : 16)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 50)
        .background { if solidSurfaces { Palette.inset } else { Rectangle().fill(.bar) } }
        .overlay(alignment: .bottom) { Divider().overlay(Palette.stroke) }
    }

    private struct ToolbarLabelStyle: LabelStyle {
        let compact: Bool
        func makeBody(configuration: Configuration) -> some View {
            if compact { configuration.icon }
            else { HStack(spacing: 4) { configuration.icon; configuration.title } }
        }
    }

    private func progressBand(_ busy: String) -> some View {
        HStack(spacing: 12) {
            Text(busy).font(.callout.weight(.semibold))
            if session.progress > 0 { ProgressView(value: session.progress) } else { ProgressView().controlSize(.small) }
            if session.progress > 0 { Text(session.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
            Spacer(minLength: 0)
            Button("Cancelar", action: session.cancel)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Palette.surface)
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Biblioteca de músicas").font(.largeTitle.bold()).tracking(-0.7)
                            .accessibilityAddTraits(.isHeader)
                        Text("Importe uma gravação para estudar o solo original ou compor o seu.").foregroundStyle(Palette.muted)
                        HStack(spacing: 12) {
                            Button(action: session.chooseAudio) {
                                Label("Importar música", systemImage: "waveform")
                            }.buttonStyle(ForgeButton())
                            Menu("Mais opções") {
                                Button("Importar com título…") { newProject = true }
                                Button("Abrir projeto portátil…") { session.importPortable() }
                            }.fixedSize()
                        }.disabled(session.busy != nil)
                    }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
                    HeroStrings().frame(width: 275, height: 152).accessibilityHidden(true)
                }.card()
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text(showingRemoved ? "Projetos removidos" : "Projetos recentes")
                            .font(.system(size: 21, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        if showingRemoved {
                            Button("Voltar aos recentes") { showingRemoved = false }
                        } else {
                            Button { showingRemoved = true } label: {
                                Label("Removidos" + (session.removed.isEmpty ? "" : " (\(session.removed.count))"), systemImage: "trash")
                            }
                        }
                    }
                    let projects = showingRemoved ? session.removed : session.recent
                    if projects.isEmpty {
                        Text(showingRemoved ? "Nenhum projeto removido." : "Seus projetos aparecem aqui depois da importação.")
                            .foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading).padding(18).card()
                    } else {
                        ForEach(projects) { project in projectRow(project) }
                    }
                }
            }.padding(30).frame(maxWidth: 1260)
        }
        .alert("Excluir “\(deletionTarget?.name ?? "")” definitivamente?", isPresented: Binding(
            get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }
        ), presenting: deletionTarget) { project in
            Button("Cancelar", role: .cancel) {}
            Button("Excluir definitivamente", role: .destructive) { session.deleteRemovedProject(project.id) }
        } message: { _ in
            Text("A cópia local da gravação, os solos e as tablaturas deste projeto serão apagados. Essa ação é permanente.")
        }
    }

    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 12) {
            if showingRemoved { projectLabel(project) }
            else {
                Button { session.open(project) } label: { projectLabel(project) }
                    .buttonStyle(.plain).disabled(session.busy != nil)
            }
            if showingRemoved {
                Button { session.setRemoved(project, false) } label: {
                    Label("Restaurar", systemImage: "arrow.uturn.backward")
                }.accessibilityLabel("Restaurar \(project.name)")
                Button(role: .destructive) { deletionTarget = project } label: {
                    Label("Excluir definitivamente…", systemImage: "trash")
                }
                .accessibilityLabel("Excluir definitivamente \(project.name)")
                .disabled(session.busy != nil)
            } else {
                Menu {
                    Button("Mover para removidos") { session.setRemoved(project, true) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden).fixedSize().help("Opções de \(project.name)")
                    .accessibilityLabel("Opções de \(project.name)")
            }
        }.padding(12).card()
    }

    private func projectLabel(_ project: Project) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "music.note.list").foregroundStyle(Palette.orange).frame(width: 39, height: 37)
                .background(Palette.inset, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.headline)
                Text("\(project.map.key.label) · \(Int(project.map.bpm.rounded())) BPM")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Spacer()
            Text(timeLabel(project.map.duration)).font(.system(.body, design: .monospaced)).foregroundStyle(Palette.muted)
            if !showingRemoved { Image(systemName: "chevron.right").font(.caption) }
        }.contentShape(Rectangle())
    }

    private func editor(_ project: Project) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Picker("Estúdio", selection: Binding(get: { session.studying }, set: { session.switchStudio(study: $0) })) {
                    Label("Criação", systemImage: "slider.horizontal.3").tag(false)
                    Label("Estudo", systemImage: "music.note.list").tag(true)
                }.pickerStyle(.segmented).labelsHidden().controlSize(.large).padding(12)
                    .accessibilityLabel("Estúdio do projeto").disabled(session.busy != nil)
                Divider()
                if session.studying {
                    StudyTransport(session: session, clock: session.clock, duration: project.map.duration)
                } else {
                    TransportSidebar(session: session, clock: session.clock, project: project)
                }
            }.frame(width: 226).background(Palette.inset)
            Divider()
            if session.studying {
                RecordingStudyView(project: project, session: session)
                    .id(project.id)
            } else {
                TabView(selection: $editorTab) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let arrangement = project.arrangement {
                                sectionControls(project, arrangement: arrangement)
                            }
                            ScorePanel(clock: session.clock, project: project, events: Session.presentedEvents(project),
                                       onSeek: session.seek,
                                       report: { session.notice = $0 }, edit: { scoreEditor = true })
                            timeline(project)
                        }.padding(10)
                    }
                    .tabItem { Label("Tablatura", systemImage: "guitars") }.tag(EditorTab.tablature)
    
                    chordTab(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                        .tabItem { Label("Cifra", systemImage: "text.alignleft") }.tag(EditorTab.chords)
                }.padding(8)
            }
        }
    }

    private func levelControls(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Level.allCases, id: \.self) { level in
                let selected = nextLevel == level
                Button { nextLevel = level } label: {
                    HStack(spacing: 4) {
                        HStack(alignment: .bottom, spacing: 2) {
                            ForEach(0..<4) { step in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(step <= level.index ? (selected ? Palette.orange : Palette.ivory) : Palette.stroke)
                                    .frame(width: 3, height: CGFloat(5 + step * 3))
                            }
                        }.accessibilityHidden(true)
                        Text(level.rawValue).font(.system(.callout, weight: selected ? .bold : .medium))
                        if selected { Image(systemName: "checkmark").font(.caption2.bold()) }
                    }.padding(.horizontal, compact ? 5 : 8).frame(minHeight: 28)
                        .foregroundStyle(selected ? Palette.orange : Palette.ivory)
                        .background(selected ? Palette.orange.opacity(0.12) : Palette.inset, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Palette.orange : Palette.stroke))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("Nível do próximo solo: \(level.rawValue)")
                    .accessibilityLabel(level.rawValue)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.fixedSize().accessibilityElement(children: .contain)
            .accessibilityLabel("Nível do próximo solo").disabled(session.busy != nil)
    }

    private func sectionControls(_ project: Project, arrangement: SoloArrangement) -> some View {
        let complete = project.showingFeatured && project.phrase?.hasSoloPositions == true
        let options = complete ? project.alternatives.filter(\.hasSoloPositions) : project.alternatives
        let previous = arrangement.featured?.alternatives.filter { !$0.hasSoloPositions } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(complete ? "Solos principais" : "Trecho anterior").font(.headline)
                if !complete, let lead = project.preferredLead {
                    Button("Ver solos principais") { session.chooseSection(lead) }
                }
                Spacer()
                if !arrangement.sections.isEmpty || !previous.isEmpty {
                    Menu("Trechos anteriores") {
                        ForEach(arrangement.sections) { section in
                            Button(section.passage.name) { session.chooseSection(section) }
                        }
                        if let lead = arrangement.featured {
                            ForEach(previous) { phrase in
                                Button(phrase.name) {
                                    var choice = lead
                                    choice.selected = phrase.id
                                    session.chooseSection(choice)
                                }
                            }
                        }
                    }.fixedSize()
                }
            }
            HStack(spacing: 9) {
                if let phrase = project.phrase {
                    Picker(complete ? "Solo" : "Trecho", selection: Binding(get: { phrase.id }, set: { id in
                        if let choice = options.first(where: { $0.id == id }) { session.select(choice) }
                    })) {
                        ForEach(options) { choice in
                            Text("\(choice.name) · \(choice.positionCount) posições").tag(choice.id)
                        }
                    }
                    Button { session.audition(phrase) } label: { Label("Ouvir", systemImage: "speaker.wave.2") }
                    Button(phrase.approved ? "Salvo" : "Salvar", action: session.approve).disabled(phrase.approved)
                }
                if session.rendering { ProgressView().controlSize(.small).accessibilityLabel("Preparando o áudio") }
            }
            if let phrase = project.phrase, let first = phrase.events.first, let last = phrase.events.last {
                Text("\(timeLabel(first.time))–\(timeLabel(last.end)) · \(phrase.explanation)")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        }.padding(10).card()
    }

    private func advancedControls(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                if let usage = session.usage { Text(usage).font(.caption2).foregroundStyle(Palette.muted) }
                Button("Corrigir análise") { correctMapAfterSettings = true; advanced = false }
            }
            HStack(spacing: 8) {
                Text("Timbre").font(.caption)
                ForEach(AmpPreset.allCases, id: \.self) { preset in
                    Button(preset.title) { session.changePreset(preset) }
                        .foregroundStyle(project.ampPreset == preset ? Palette.orange : Palette.ivory)
                }
            }
            PresentationControls(project: project, session: session)
            if project.phrase != nil {
                Button("Descartar proposta atual", role: .destructive, action: session.discard)
            }
        }.padding(12).card().disabled(session.busy != nil)
    }

    private func timeline(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Trecho e gravação").font(.headline)
                Spacer()
                Text("Tom · \(certainty(project.map.keyConfidence))    Pulso · \(certainty(project.map.tempoConfidence))")
                    .font(.caption).foregroundStyle(Palette.muted)
                    .accessibilityLabel("Confiança estimada. Tom \(certainty(project.map.keyConfidence)), pulso \(certainty(project.map.tempoConfidence)).")
            }
            Waveform(clock: session.clock, project: project, onSeek: session.seek)
            HStack(spacing: 9) {
                Text("Início")
                TimeInput(value: project.passage.start, maximum: project.map.duration) { value in
                    session.modify({ $0.passage.start = value }, record: true)
                }
                Text("Fim")
                TimeInput(value: project.passage.end, maximum: project.map.duration) { value in
                    session.modify({ $0.passage.end = value }, record: true)
                }
                Spacer()
                Menu("Seções sugeridas") {
                    ForEach(project.map.sections) { section in
                        Button("\(section.name) · \(timeLabel(section.start))") {
                            session.modify({ $0.passage = section }, record: true)
                        }.disabled(section.end - section.start < 1)
                    }
                }.fixedSize()
                Button { session.playPassage() } label: { Image(systemName: "play.fill") }
                    .accessibilityLabel("Tocar do início do trecho").disabled(session.rendering)
            }.font(.caption)
        }.padding(14).card()
    }

    private func chordTab(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Letra e cifra").font(.headline)
                Spacer()
                if project.chordSheet {
                    Button("Editar letra") { notation = true }
                } else {
                    Button("Gerar cifra com Whisper", action: session.generateChordSheet)
                        .disabled(session.busy != nil)
                }
            }
            if project.chordSheet, !project.lyrics.isEmpty {
                WordChordSheet(clock: session.clock, project: project, seek: session.seek)
            }
        }.padding(12).card()
    }
}

extension ExportKind: Identifiable {
    var id: Self { self }
}
func timeLabel(_ time: Double) -> String {
    let seconds = Int(max(0, time))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
func certainty(_ value: Double) -> String {
    if value >= 0.62 { return "alta" }
    if value >= 0.29 { return "moderada" }
    return "baixa"
}
extension View {
    func card() -> some View {
        modifier(StudioSurface())
    }
}
private struct StudioSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let border = contrast == .increased ? Palette.muted : Palette.stroke
        content.background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: contrast == .increased ? 1.5 : 0.7).allowsHitTesting(false) }
    }
}
struct ForgeButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .default).weight(.bold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(Color(red: 0.09, green: 0.056, blue: 0.024))
            .background(Palette.orange.opacity(configuration.isPressed ? 0.80 : 1), in: RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.975 : 1)
            .animation(reducedMotion ? nil : .spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.46)
    }
}
struct TimeInput: View {
    let value: Double
    let maximum: Double
    var update: (Double) -> Void
    @State private var draft = ""
    var body: some View {
        TextField("Segundos", text: $draft).font(.system(.caption, design: .monospaced))
            .frame(width: 72).accessibilityLabel("Segundos")
            .onAppear { reset() }.onChange(of: value) { _, _ in reset() }
            .onSubmit {
                if let seconds = Double(draft.replacingOccurrences(of: ",", with: ".")), seconds.isFinite {
                    update(min(maximum, max(0, seconds)))
                }
                reset()
            }
    }
    private func reset() { draft = String(format: "%.2f", value) }
}

struct HeroStrings: View {
    var body: some View {
        Canvas { g, size in
            for row in 0..<7 {
                var string = Path()
                let top = 40 + CGFloat(row) * 32
                string.move(to: CGPoint(x: -9, y: top + 29))
                string.addCurve(to: CGPoint(x: size.width + 7, y: top - 43),
                                control1: CGPoint(x: size.width * 0.32, y: top + 83),
                                control2: CGPoint(x: size.width * 0.77, y: top - 106))
                g.stroke(string, with: .color(row == 3 ? Palette.orange : Palette.stroke), lineWidth: row == 3 ? 2.3 : 1.0)
            }
            for dot in [CGPoint(x: 41, y: 129), CGPoint(x: 155, y: 137), CGPoint(x: 242, y: 93), CGPoint(x: 301, y: 76)] {
                g.fill(Path(ellipseIn: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)), with: .color(Palette.orange))
            }
        }.clipped()
    }
}
