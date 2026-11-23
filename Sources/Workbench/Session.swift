import AppKit
import Combine
import Foundation
import MusicCore
import UniformTypeIdentifiers

@MainActor
final class Session: ObservableObject {
    private struct RenderKey: Equatable {
        let source: String
        let events: [Event]
        let instrument: Instrument
        let tone: Tone
        let bpm: Double
        let preset: AmpPreset?
    }
    @Published private(set) var current: Project?
    @Published private(set) var recent: [Project] = []
    @Published private(set) var removed: [Project] = []
    @Published private(set) var busy: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var playback = false
    @Published private(set) var rendering = false
    @Published private(set) var sequenceMode = false
    @Published private(set) var studying = false
    @Published private(set) var studySoloID: UUID?
    @Published private(set) var hearingStudyGuitar = false
    var studySourceTitle: String { hearingStudyGuitar ? "Guitarra isolada" : (studySoloID == nil ? "Gravação original" : "Solo da tablatura") }
    private func studyAudio(_ study: RecordingStudy) -> URL? {
        currentRecording?.deletingLastPathComponent().appendingPathComponent("study-\(study.passage.id.uuidString).wav")
    }
    var hasStudyAudio: Bool {
        guard let study = current?.recordingStudy, let url = studyAudio(study) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @Published var studySpeed = 1.0 { didSet { if studying { updateMixer() } } }
    @Published var studyLoop = false
    @Published private(set) var studyRange: ClosedRange<Double>?
    @Published var needsOpenAI = false
    @Published var notice: String?
    var usage: String? { current?.arrangement?.usage }
    @Published var muteRecording = false { didSet { updateMixer() } }
    @Published var muteLead = false { didSet { updateMixer() } }
    @Published var canUndo = false
    let clock = Playhead()
    private let transport = Transport()
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("guitar-session-\(UUID())", isDirectory: true)
    private var store: Store?
    private var timer: AnyCancellable?
    private var job: Task<Void, Never>?
    private var renderJob: Task<Void, Never>?
    private var undoStack: [Project] = []
    private var renderCache: [(RenderKey, LeadRender)] = []
    private var renderToken = UUID()
    private var sequenceStartQueued = false
    private var auditionQueued = false
    private var auditionPlaying = false

    init(store providedStore: Store? = nil) {
        do {
            store = try providedStore ?? Store.standard()
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try refreshProjects()
        } catch { notice = error.localizedDescription }
        timer = Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
    }

    func open(_ project: Project) {
        do {
            auditionQueued = false
            guard let store else { throw WorkError.files }
            try Music.validate(project)
            try transport.load(recording: store.audio(for: project.id))
            var opened = project
            if let lead = opened.preferredLead {
                opened.activateSection(lead)
                opened.saveSectionEdits()
            }
            studying = false
            studyRange = nil
            current = opened
            clock.time = 0; playback = false
            undoStack.removeAll(); canUndo = false
            muteLead = false; muteRecording = false
            rebuild()
        } catch { notice = error.localizedDescription }
    }

    func home() {
        pause()
        studying = false
        studyRange = nil
        current = nil
        do { try refreshProjects() }
        catch { notice = error.localizedDescription }
        rebuild()
    }

    private func refreshProjects() throws {
        guard let store else { return }
        recent = try store.list()
        removed = try store.list(removed: true)
    }

    func setRemoved(_ project: Project, _ value: Bool) {
        do {
            try store?.setRemoved(project, value)
            try refreshProjects()
        } catch { notice = error.localizedDescription }
    }

    func deleteRemovedProject(_ id: UUID) {
        guard current == nil, busy == nil, let store else { return }
        do { try store.deleteRemovedProject(id) }
        catch { notice = error.localizedDescription }
        do { try refreshProjects() }
        catch { notice = error.localizedDescription }
    }

    func importAudio(_ url: URL, name: String) {
        guard let root = store?.folder else { return }
        run("Analisando gravação") { update in
            try Importer.importAudio(url, name: name, store: Store(folder: root), progress: update)
        } done: { self.open($0) }
    }

    func chooseAudio() {
        let panel = NSOpenPanel()
        panel.title = "Escolher gravação"
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Store.sourceExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAudio(url, name: String(url.deletingPathExtension().lastPathComponent.prefix(200)))
    }

    func importPortable() {
        let panel = NSOpenPanel()
        panel.title = "Abrir projeto portátil"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(exportedAs: "org.soloforge.community.guitarproject", conformingTo: .package)]
        guard panel.runModal() == .OK, let url = panel.url, let root = store?.folder else { return }
        openPortable(url, root: root)
    }

    private func openPortable(_ url: URL, root: URL) {
        run("Verificando projeto portátil") { update in
            try Store(folder: root).importPortable(url, progress: update)
        } done: { self.open($0) }
    }

    func openURL(_ url: URL) {
        if url.pathExtension == "guitarproject", let root = store?.folder { openPortable(url, root: root) }
        else { importAudio(url, name: url.deletingPathExtension().lastPathComponent) }
    }

    var currentRecording: URL? { current.flatMap { store?.audio(for: $0.id) } }

    func save() {
        guard let current, let store else { return }
        do { try store.save(current) }
        catch { notice = error.localizedDescription }
    }

    func modify(_ change: (inout Project) throws -> Void, rebuildAudio: Bool = false, record: Bool = false) {
        guard let original = current, let store else { return }
        var next = original
        do {
            try change(&next)
            next.saveSectionEdits()
            if next == original { return }
            try store.save(next)
            if record {
                undoStack.append(original)
                if undoStack.count > 32 { undoStack.removeFirst() }
                canUndo = true
            }
            current = next
            if rebuildAudio { rebuild() }
            else if playback && (next.loop != original.loop || (next.loop && next.passage != original.passage)) {
                pause()
                play()
            } else { updateMixer() }
        } catch { notice = error.localizedDescription }
    }

    @discardableResult
    func resetGeneratedMusic(projectID: UUID, includingLyrics: Bool) -> Bool {
        guard busy == nil, let project = current, project.id == projectID,
              project.hasGeneratedSolos || (includingLyrics && project.hasLyricsOrChords) else { return false }
        var cleared = project
        cleared.clearGeneratedMusic(includingLyrics: includingLyrics)
        auditionQueued = false
        modify({ $0 = cleared }, rebuildAudio: true, record: true)
        guard current == cleared else { return false }
        seek(0)
        updateMixer()
        return true
    }

    func undo() {
        guard !studying, var original = undoStack.popLast(), let store else { return }
        original.recordingStudy = current?.recordingStudy
        do {
            try store.save(original)
            current = original
            canUndo = !undoStack.isEmpty
            rebuild()
        } catch {
            undoStack.append(original)
            notice = error.localizedDescription
        }
    }

    func generateSong(_ level: Level) {
        guard let project = current, busy == nil else { return }
        var preferences = project.preferences
        preferences.level = level
        let passage = project.arrangement?.featured?.passage ?? Passage("Solos principais", 0, project.map.duration)
        guard SectionGrid(map: project.map, passage: passage).count >= SongStructure.minimumSoloPositions else {
            notice = "A gravação é curta demais para tocar \(SongStructure.minimumSoloPositions) posições neste andamento."
            return
        }
        pause()
        busy = "A IA está compondo solos para a música"
        progress = 0
        let requestedPreferences = preferences
        job = Task {
            defer { busy = nil; job = nil }
            do {
                let result = try await Director.plan(project: project, passage: passage, level: level, recording: currentRecording)
                try Task.checkCancellation()
                progress = 0.70
                let worker = Task.detached(priority: .userInitiated) {
                    try SongStructure.realize(result.plan, map: project.map, passages: [passage], preferences: requestedPreferences, featured: true)
                }
                let parts = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard current?.id == project.id, current?.map == project.map else { return }
                modify({ value in
                    guard var lead = parts.first else { throw MusicError.noCompleteSolo }
                    if value.capo != 0 || value.transpose != 0 {
                        lead.alternatives = lead.alternatives.filter {
                            (try? value.playableEvents($0, shift: value.transpose, capo: value.capo)) != nil
                        }
                        guard let first = lead.alternatives.first else { throw MusicError.unreachable }
                        lead.selected = first.id
                    }
                    let saved = value.arrangement?.featured?.alternatives.filter(\.approved) ?? []
                    lead.alternatives += saved.prefix(12 - lead.alternatives.count)
                    var timeline = value.arrangement?.sections ?? []
                    if value.arrangement == nil, !value.alternatives.isEmpty {
                        timeline = [SoloSection(passage: Passage("Propostas anteriores", 0, value.map.duration),
                                                alternatives: value.alternatives, selected: value.selected)]
                    }
                    value.arrangement = SoloArrangement(sections: timeline, level: level, model: Director.model, usage: result.usage)
                    value.arrangement?.featured = lead
                    value.preferences.level = level
                    value.ampPreset = result.plan.amp
                    value.tone = result.plan.amp.tone
                    value.preferences.instrument = result.plan.amp.instrument
                    value.activateSection(lead)
                }, rebuildAudio: true, record: true)
                progress = 1
            } catch is CancellationError {
                return
            } catch DirectionError.noKey {
                needsOpenAI = true
            } catch {
                if !Task.isCancelled { notice = error.localizedDescription }
            }
        }
    }

    func chooseSection(_ section: SoloSection) {
        if current?.activeSection == section.id && sequenceMode { rebuild() }
        modify({ $0.activateSection(section) }, rebuildAudio: true)
        seek(current?.passage.start ?? section.passage.start)
    }

    func playSequence() {
        guard current?.arrangement != nil, !rendering else { return }
        if sequenceMode { play() }
        else { rebuild(sequence: true) }
    }

    func changePreset(_ preset: AmpPreset) {
        modify({
            $0.ampPreset = preset
            $0.tone = preset.tone
            $0.preferences.instrument = preset.instrument
        }, rebuildAudio: true, record: true)
    }

    func select(_ phrase: Phrase) {
        modify({ $0.selected = phrase.id }, rebuildAudio: true)
    }

    func audition(_ phrase: Phrase) {
        guard let project = current else { return }
        if project.phrase?.id == phrase.id {
            if sequenceMode {
                auditionQueued = true
                rebuild()
                return
            }
            if auditionPlaying { pause(); return }
            if rendering { auditionQueued = true } else { startAudition() }
        } else {
            auditionQueued = true
            select(phrase)
            if current?.phrase?.id != phrase.id { auditionQueued = false }
        }
    }

    private func startAudition() {
        auditionQueued = false
        guard let project = current, let first = project.phrase?.events.first, let last = project.phrase?.events.last else { return }
        let from = project.showingFeatured ? project.passage.start : max(0, first.time - min(0.28, 16 / project.map.bpm))
        let through = min(project.map.duration, last.end + LeadRender.tail(project))
        do {
            updateMixer()
            try transport.play(from: from, until: through)
            clock.time = from
            playback = transport.playing
            auditionPlaying = playback
        } catch { notice = error.localizedDescription }
    }

    func approve() {
        modify({ project in
            guard let phrase = project.phrase, let index = project.alternatives.firstIndex(where: { $0.id == phrase.id }) else { return }
            project.alternatives[index].approved.toggle()
        }, record: true)
    }

    func discard() {
        modify({ project in
            if let phrase = project.phrase { project.alternatives.removeAll { $0.id == phrase.id } }
            project.selected = project.alternatives.first?.id
        }, rebuildAudio: true, record: true)
    }

    func applyCapo(_ fret: Int, transpose: Int, recording: Bool) {
        modify({ project in
            project.capoFret = fret == 0 ? nil : fret
            project.transpose = transpose
            project.transposeRecording = recording && transpose != 0
        }, rebuildAudio: true, record: true)
    }

    func transpose(_ value: Int, includeRecording: Bool) {
        modify({ $0.transpose = value; $0.transposeRecording = includeRecording }, rebuildAudio: true, record: true)
    }

    func moveFingering(_ position: Int) {
        modify({ project in
            if project.transpose == 0 && project.capo == 0, let phrase = project.phrase,
               let index = project.alternatives.firstIndex(where: { $0.id == phrase.id }) {
                project.alternatives[index].events = try Music.fingering(phrase.events, semitones: 0, position: position, level: phrase.level)
            }
            project.preferences.position = position
        }, rebuildAudio: true, record: true)
    }

    static func presentedEvents(_ project: Project) -> [Event] {
        guard let phrase = project.phrase else { return [] }
        return (try? project.playableEvents(phrase, shift: project.transpose, capo: project.capo)) ?? []
    }

    private func rebuild(sequence: Bool = false, studyLine: Phrase? = nil) {
        let token = UUID()
        renderToken = token
        renderJob?.cancel()
        let queued = auditionQueued
        pause()
        auditionQueued = queued
        sequenceMode = sequence
        sequenceStartQueued = sequence
        try? transport.load(lead: nil)
        hearingStudyGuitar = false
        studySoloID = studyLine?.id
        guard var project = current else { rendering = false; sequenceMode = false; return }
        let events: [Event]
        do {
            if studying {
                guard let studyLine, let study = project.recordingStudy else { rendering = false; updateMixer(); return }
                project = Project(name: project.name, sourceHash: project.sourceHash, map: study.map)
                project.tone.delay = 0
                project.tone.room = 0.08
                project.tone.sustain = 0.30
                events = studyLine.events
            } else if sequence, !project.showingFeatured, let arrangement = project.arrangement {
                events = try arrangement.sections.compactMap(\.phrase).flatMap { phrase -> [Event] in
                    try project.playableEvents(phrase, shift: project.transpose, capo: project.capo)
                }
            } else {
                events = Self.presentedEvents(project)
            }
        } catch {
            rendering = false
            sequenceMode = false
            notice = error.localizedDescription
            return
        }
        guard !events.isEmpty else { rendering = false; sequenceMode = false; return }
        let key = RenderKey(source: project.sourceHash, events: events, instrument: project.preferences.instrument,
                            tone: project.tone, bpm: project.map.bpm, preset: project.ampPreset)
        if let hit = renderCache.firstIndex(where: { $0.0 == key }) {
            let existing = renderCache.remove(at: hit)
            renderCache.append(existing)
            if (try? transport.load(lead: existing.1)) != nil {
                rendering = false
                updateMixer()
                resumeAfterRender()
                return
            }
            _ = renderCache.popLast()
        }
        let url = scratch.appendingPathComponent("\(token).wav")
        rendering = true
        let task = Task.detached(priority: .userInitiated) { [project] in try LeadRender.create(events: events, project: project, to: url) }
        renderJob = Task {
            do {
                let newFile = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                guard renderToken == token else { try? FileManager.default.removeItem(at: url); return }
                try transport.load(lead: newFile)
                renderCache.append((key, newFile))
                if renderCache.count > 8 { try? FileManager.default.removeItem(at: renderCache.removeFirst().1.url) }
                updateMixer()
                rendering = false
                resumeAfterRender()
            } catch {
                try? FileManager.default.removeItem(at: url)
                if renderToken == token && !(error is CancellationError) { notice = error.localizedDescription }
                if renderToken == token { auditionQueued = false; sequenceMode = false; studySoloID = nil; updateMixer() }
            }
            if renderToken == token { rendering = false }
        }
    }

    private func resumeAfterRender() {
        if sequenceStartQueued { startSequence() }
        else if auditionQueued {
            if studying {
                auditionQueued = false
                play()
            } else { startAudition() }
        }
    }

    private func startSequence() {
        sequenceStartQueued = false
        clock.time = 0
        followSequence(at: 0)
        play()
    }

    private func followSequence(at time: Double) {
        guard var project = current, !project.showingFeatured, let arrangement = project.arrangement,
              let section = arrangement.sections.last(where: { $0.passage.start <= time }),
              section.id != project.activeSection else { return }
        project.activateSection(section)
        current = project
    }

    func play() {
        guard let project = current, !rendering else { return }
        if playback { pause(); return }
        let localOnly = !sequenceMode && (project.arrangement != nil || project.loop)
        let range = studying ? (studyRange ?? 0...project.map.duration) : (localOnly ? project.passage.start...project.passage.end : 0...project.map.duration)
        let start = clock.time >= range.lowerBound && clock.time < range.upperBound - 0.02 ? clock.time : range.lowerBound
        do {
            updateMixer()
            try transport.play(from: start, until: range.upperBound)
            clock.time = start
            playback = transport.playing
        } catch { notice = error.localizedDescription }
    }

    func playPassage() {
        guard let project = current else { return }
        seek(project.passage.start)
        if !playback { play() }
    }

    func stop() {
        guard let project = current else { return }
        pause()
        seek(studying ? (studyRange?.lowerBound ?? 0) : (!sequenceMode && (project.arrangement != nil || project.loop) ? project.passage.start : 0))
    }

    func pause() {
        sequenceStartQueued = false
        auditionQueued = false
        auditionPlaying = false
        let wasPlaying = playback
        transport.pause()
        if wasPlaying { clock.time = transport.position }
        playback = false
    }

    func seek(_ time: Double) {
        let wasPlaying = playback
        transport.seek(time)
        playback = false
        clock.time = transport.position
        if sequenceMode { followSequence(at: clock.time) }
        if wasPlaying { play() }
    }

    private func tick() {
        guard playback else { return }
        let ended = transport.update()
        clock.time = transport.position
        if sequenceMode { followSequence(at: clock.time) }
        if ended {
            playback = false
            if studying {
                if studyLoop { seek(studyRange?.lowerBound ?? 0); play() }
                return
            }
            if sequenceMode { return }
            if auditionPlaying { auditionPlaying = false; return }
            if let project = current, project.loop {
                seek(project.passage.start)
                play()
            }
        }
    }

    private func updateMixer() {
        guard let project = current else { return }
        if studying {
            var levels = MixLevels(project: project)
            levels.music = studySoloID == nil && !hearingStudyGuitar ? 1 : 0
            levels.lead = 1 - levels.music
            transport.configure(levels: levels, rate: studySpeed, semitones: 0)
            return
        }
        let levels = MixLevels(project: project, muteMusic: muteRecording, muteLead: muteLead)
        transport.configure(levels: levels, rate: project.speed, semitones: project.transposeRecording ? project.transpose : 0)
    }

    func cancel() { job?.cancel() }

    func switchStudio(study: Bool) {
        guard busy == nil, studying != study, let project = current else { return }
        pause()
        auditionQueued = false
        studying = study
        studyRange = nil
        rebuild()
        seek(study ? 0 : project.passage.start)
        if study {
            if let old = project.recordingStudy {
                if !old.usedGuitarTrack && (old.analysisVersion ?? 1) < RecordingStudy.currentAnalysisVersion {
                    analyzeRecording(from: old.passage.start, to: old.passage.end)
                }
            } else if project.map.duration <= 600 {
                analyzeRecording(from: 0, to: project.map.duration)
            }
        }
    }

    func selectStudyRange(_ range: ClosedRange<Double>?) {
        guard studying else { return }
        pause()
        if studySoloID != nil || hearingStudyGuitar { rebuild() }
        studyRange = range
        seek(range?.lowerBound ?? 0)
    }

    func auditionStudyGuitar(_ range: ClosedRange<Double>) {
        guard studying, let study = current?.recordingStudy, let url = studyAudio(study) else { return }
        selectStudyRange(range)
        rebuild()
        let offset = study.usedGuitarTrack ? 0 : study.passage.start
        do {
            try transport.load(lead: LeadRender(url: url, offset: Int64((offset * AudioFiles.rate).rounded())))
            hearingStudyGuitar = true
            play()
        } catch { notice = error.localizedDescription }
    }

    func auditionStudyLine(_ id: UUID) {
        guard studying, let line = current?.recordingStudy?.lines.first(where: { $0.id == id }),
              let first = line.events.first, let last = line.events.last else { return }
        if studySoloID == id {
            if rendering { return }
            play()
            return
        }
        pause()
        studyRange = first.time...last.end
        seek(first.time)
        auditionQueued = true
        rebuild(studyLine: line)
    }

    func analyzeRecording(from: Double, to: Double, guitarTrack: URL? = nil) {
        guard studying, busy == nil, let project = current, let recording = currentRecording else { return }
        let passage = Passage("Trecho analisado", from, to)
        do { try Music.validate(passage, duration: project.map.duration) }
        catch { notice = error.localizedDescription; return }
        let original: AudioMap?
        do { original = try project.recordingStudy?.map ?? store?.cached(project.sourceHash) }
        catch { notice = error.localizedDescription; return }
        run(guitarTrack == nil ? "Separando e transcrevendo a guitarra" : "Transcrevendo a pista de guitarra") { update in
            let map = try original ?? Analyzer.analyze(recording) { update($0 * 0.15) }
            let staging = try StudyAudioStaging()
            let input = staging.audio
            if let guitarTrack {
                let duration = try AudioFiles.decode(guitarTrack, to: input) { update(0.15 + 0.10 * $0) }
                guard abs(duration - project.map.duration) <= 0.1 else {
                    throw WorkError.audio("A pista de guitarra precisa começar no mesmo ponto e ter a mesma duração da gravação.")
                }
            } else {
                try GuitarSeparation.isolate(recording, passage: passage, to: input) { update(0.15 + $0 * 0.65) }
            }
            let lines = try RecordedMelody.transcribe(input, passage: passage, audioOrigin: guitarTrack == nil ? from : 0,
                    mix: guitarTrack == nil ? recording : nil,
                    vocalHints: guitarTrack == nil ? (map.vocalHints ?? []) : []) { update(0.80 + $0 * 0.20) }
            return (RecordingStudy(map: map, passage: passage, lines: lines, usedGuitarTrack: guitarTrack != nil), staging)
        } done: { result in
            guard self.current?.id == project.id else { return }
            let (result, staging) = result
            guard let destination = self.studyAudio(result) else { return }
            let previous = self.current?.recordingStudy.flatMap { self.studyAudio($0) }
            do { try FileManager.default.moveItem(at: staging.audio, to: destination) }
            catch { self.notice = error.localizedDescription; return }
            self.modify { state in
                var study = result
                study.referenceSheet = state.recordingStudy?.referenceSheet
                study.lyrics = state.recordingStudy?.lyrics
                state.recordingStudy = study
            }
            if self.current?.recordingStudy?.passage.id == result.passage.id {
                if let previous { try? FileManager.default.removeItem(at: previous) }
            } else { try? FileManager.default.removeItem(at: destination) }
            self.selectStudyRange(nil)
        }
    }

    func studyLyrics() {
        guard studying, let project = current, project.recordingStudy != nil, let recording = currentRecording else { return }
        run("Transcrevendo a letra da gravação") { update in
            try WhisperLocal.makeLyrics(recording: recording, duration: project.map.duration, progress: update)
        } done: { lyrics in
            guard self.current?.id == project.id else { return }
            self.modify { $0.recordingStudy?.lyrics = lyrics }
        }
    }

    func generateChordSheet() {
        guard let project = current, let recording = currentRecording else { return }
        if !project.lyrics.isEmpty {
            modify({ $0.chordSheet = true }, record: true)
            return
        }
        run("Transcrevendo a letra localmente com Whisper") { update in
            try WhisperLocal.makeLyrics(recording: recording, duration: project.map.duration, progress: update)
        } done: { verses in
            guard self.current?.id == project.id else { return }
            self.modify({ $0.lyrics = verses; $0.chordSheet = true }, record: true)
        }
    }

    func export(_ kind: ExportKind, options: ExportOptions = ExportOptions()) {
        guard busy == nil, let project = current, let root = store?.folder, let recording = store?.audio(for: project.id) else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = kind.rawValue
        panel.nameFieldStringValue = project.name + "." + kind.ext
        panel.allowedContentTypes = [kind.contentType]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let events = Self.presentedEvents(project)
        let currentLevels = MixLevels(project: project, muteMusic: muteRecording, muteLead: muteLead)
        run("Exportando \(kind.ext.uppercased())") { update in
            try Exporter.export(kind, project: project, events: events, recording: recording,
                                levels: currentLevels, options: options, library: root, to: destination, progress: update)
        } done: { _ in self.notice = "Arquivo salvo em \(destination.path)" }
    }

    private func run<T>(_ title: String, work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) throws -> T,
                        done: @escaping (T) -> Void) {
        guard busy == nil else { return }
        busy = title
        progress = 0
        let gate = ProgressGate()
        let notify: @Sendable (Double) -> Void = { [weak self] value in
            guard gate.allow(value) else { return }
            Task { @MainActor [weak self] in guard let self, self.busy == title else { return }; self.progress = max(self.progress, min(1, value)) }
        }
        let worker = Task.detached(priority: .userInitiated) { try work(notify) }
        job = Task {
            defer { busy = nil; job = nil }
            do {
                let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                done(value)
            } catch is CancellationError {
                notice = "Operação cancelada."
            } catch { notice = error.localizedDescription }
        }
    }
}

final class Playhead: ObservableObject {
    @Published var time = 0.0
}
private final class ProgressGate: @unchecked Sendable {
    let lock = NSLock()
    private var previous = -1.0
    func allow(_ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value >= 1 || value - previous >= 0.007 else { return false }
        previous = value
        return true
    }
}

private final class StudyAudioStaging: @unchecked Sendable {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var audio: URL { folder.appendingPathComponent("guitarra.wav") }
    init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: folder) }
}
