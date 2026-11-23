import MusicCore
import SwiftUI

struct WordChordSheet: View {
    @ObservedObject var clock: Playhead
    let project: Project
    let seek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if project.capo > 0 {
                Text("\(project.capoLabel) · cifras indicam as formas a tocar").font(.caption)
            }
            if project.lyrics.contains(where: { $0.words == nil }) {
                Text("Versos digitados têm posicionamento aproximado.")
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(project.lyrics) { lyric in
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 5) {
                                Button { seek(lyric.time) } label: {
                                    Text(timeLabel(lyric.time))
                                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(Palette.muted)
                                        .frame(width: 36, alignment: .leading)
                                }.buttonStyle(.plain).accessibilityLabel("Ir para verso em \(timeLabel(lyric.time))")
                                ForEach(Array(LyricHarmony.align(lyric, project: project).enumerated()), id: \.offset) { _, token in
                                    let playing = token.word.start <= clock.time && clock.time < token.word.end
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(token.chords.isEmpty ? " " : token.chords.joined(separator: " "))
                                            .font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(Palette.orange)
                                        Text(token.word.text).font(.system(.callout, design: .monospaced))
                                            .foregroundStyle(playing ? Palette.orange : Palette.ivory)
                                    }.fixedSize()
                                }
                            }
                        }
                    }
                }.padding(9)
            }.frame(maxHeight: .infinity)
                .background(Palette.inset, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
