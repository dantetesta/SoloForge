import Foundation
import MusicCore
import Testing
@testable import Workbench

@MainActor @Test func boardFindsEveryStringAndFretAndLimitsBend() {
    let layout = PracticeBoard.Layout(size: CGSize(width: 740, height: 163))
    for string in 0..<6 {
        for fret in 0...22 {
            let position = CGPoint(x: layout.x(Double(fret)), y: layout.y(string))
            #expect(layout.anchor(at: position) == .init(string: string, fret: fret))
        }
    }
    #expect(layout.anchor(at: .zero) == nil)
    #expect(PracticeBoard.bendAmount(1) == 0)
    #expect(PracticeBoard.bendAmount(-24) == 1)
    #expect(PracticeBoard.bendAmount(500) == 2)
}

@Test func heldBoardNoteBendsAndReturnsAfterRecordedSampleEnds() throws {
    let rate = AudioFiles.rate
    let values = (0..<Int(rate * 0.5)).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / rate)) }
    let loop = try #require(SustainLoop(values: values, rate: rate, pitch: 69))
    let wave = Wave(values: values, rate: rate, gain: 1, loop: loop)
    let event = Event(time: 0, duration: 3, string: 0, fret: 5, velocity: 0.85)
    var tone = Tone.suggested(.clean)
    tone.room = 0; tone.delay = 0; tone.sustain = 1
    var note = BoardVoice(string: GuitarVoice(event: event, sample: wave, semitones: 0, sustain: 1, acoustic: false, softer: false),
                          amp: GuitarAmplifier(instrument: .clean, preset: nil, tone: tone, bpm: 120))
    func measure(_ semitones: Double) -> Double {
        let ratio = pow(2, semitones / 12)
        let n = Int(rate * 0.3)
        for _ in 0..<n { _ = note.next(target: ratio) }
        var crossings = 0, previous: Float = 0
        for _ in 0..<n {
            let sample = note.next(target: ratio).0
            if previous <= 0, sample > 0 { crossings += 1 }
            previous = sample
        }
        return Double(crossings) * rate / Double(n)
    }
    #expect(abs(measure(0) - 440) < 5)
    #expect(abs(measure(2) - 493.88) < 5)
    #expect(abs(measure(0) - 440) < 5)
    note.releaseAt = note.age
    for _ in 0..<Int(rate * 0.16) { _ = note.next(target: 1) }
    #expect(note.finished && note.next(target: 1).0 == 0)
}

@Test func naturalSeventhFretProducesThirdPartialAndCapoAdviceRejectsImpossibleFrets() throws {
    let event = Event(time: 0, duration: 1.5, string: 5, fret: 7, velocity: 0.8, technique: .harmonic)
    let wave = Wave(values: [0,0], rate: AudioFiles.rate, gain: 1)
    var voice = GuitarVoice(event: event, sample: wave, semitones: 0, sustain: 0.5, acoustic: true, softer: false)
    var crossings = 0, prev: Float = 0
    for i in 0..<Int(AudioFiles.rate) {
        let v = voice.sample(at: Double(i) / AudioFiles.rate)
        if v > 0, prev <= 0 { crossings += 1 }
        prev = v
    }
    #expect(abs(Double(crossings) - 246.94) < 2)
    let reply = Data(#"{"choices":[{"fret":4,"reason":"Formas de Dó"}]}"#.utf8)
    #expect(try Director.validatedAdvice(reply, allowed: [2,4]).first?.fret == 4)
    #expect(throws: DirectionError.self) { try Director.validatedAdvice(reply, allowed: [0,2]) }
}
