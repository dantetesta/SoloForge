import MusicCore
import SwiftUI

struct CapoSheet: View {
    let project: Project
    @ObservedObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var target: Int
    @State private var shift: Int
    @State private var selected: Int
    @State private var recording: Bool
    @State private var advice: [Director.CapoAdvice] = []
    @State private var error: String?
    @State private var request: UUID?

    init(project: Project, session: Session) {
        self.project = project
        self.session = session
        _target = State(initialValue: project.presentedKey.root)
        _shift = State(initialValue: project.transpose)
        _selected = State(initialValue: project.capo)
        _recording = State(initialValue: project.transpose == 0 || project.transposeRecording)
    }

    private func shifts(_ root: Int) -> [Int] {
        (-12...12).filter { pitchClass(project.compositionKey.root + $0) == root }.sorted {
            abs($0) == abs($1) ? $0 < $1 : abs($0) < abs($1)
        }
    }
    private func invalidate() {
        request = nil
        advice = []
        error = nil
        let options = project.capoOptions(transpose: shift)
        if !options.contains(where: { $0.fret == selected }) { selected = options.first?.fret ?? 0 }
    }
    var body: some View {
        let options = project.capoOptions(transpose: shift)
        let choice = options.first { $0.fret == selected }
        VStack(alignment: .leading, spacing: 15) {
            Text("Tom e capotraste").font(.title2.bold())
            HStack {
                Picker("Tom desejado", selection: $target) {
                    ForEach(0..<12) { root in
                        Text(Key(root: root, minor: project.compositionKey.minor).label).tag(root)
                    }
                }.onChange(of: target) { _, root in shift = shifts(root)[0]; invalidate() }
                Picker("Registro", selection: $shift) {
                    ForEach(shifts(target), id: \.self) { step in
                        Text(step == 0 ? "Original" : "\(step > 0 ? "+" : "")\(step) semitons").tag(step)
                    }
                }.onChange(of: shift) { _, _ in invalidate() }
            }
            if options.isEmpty {
                Text("O solo não cabe nesse registro com as técnicas atuais. Escolha outro registro ou tom.")
            } else {
                Picker("Capotraste", selection: $selected) {
                    ForEach(options) { option in
                        Text("\(option.fret == 0 ? "Sem capo" : "Casa \(option.fret)") · formas de \(option.shapeKey)").tag(option.fret)
                    }
                }
                if let choice {
                    Text("Som de \(Key(root: target, minor: project.compositionKey.minor).label) · formas de \(choice.shapeKey)")
                        .font(.headline)
                    if !choice.shapes.isEmpty { Text(choice.shapes.joined(separator: "  ·  ")).monospaced() }
                    if let low = choice.lowestMidi, let high = choice.highestMidi {
                        Text("Extensão do solo: \(noteName(low)) a \(noteName(high)) · \(choice.openNotes) notas em corda solta").font(.caption)
                    }
                }
                if shift != 0 { Toggle("Transpor também a gravação", isOn: $recording) }
                Divider()
                HStack {
                    Button("Pedir sugestões à OpenAI") { request = UUID() }.disabled(request != nil)
                    if request != nil { ProgressView().controlSize(.small) }
                    Text("API cobrada por uso").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(advice) { item in
                    HStack(alignment: .top) {
                        Button(item.fret == 0 ? "Sem capo" : "Casa \(item.fret)") { selected = item.fret }
                        Text(item.reason).font(.callout)
                    }
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aplicar") {
                    session.applyCapo(selected, transpose: shift, recording: recording)
                    dismiss()
                }.disabled(choice == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 585)
        .task(id: request) {
            guard let id = request else { return }
            do {
                let result = try await Director.adviseCapo(options: options, target: Key(root: target, minor: project.compositionKey.minor).label,
                                                           delta: shift, level: project.preferences.level)
                guard !Task.isCancelled, request == id else { return }
                advice = result
                error = nil
            } catch {
                guard !Task.isCancelled, request == id else { return }
                self.error = error.localizedDescription
            }
            request = nil
        }
    }
    private func noteName(_ midi: Int) -> String { "\(pitchNames[pitchClass(midi)])\(midi / 12 - 1)" }
}
