import CoreMedia
import Foundation
import MusicCore
import SoundAnalysis

enum VocalAnalysis {
    static func detect(in url: URL, duration: Double, progress: @escaping (Double) -> Void) throws -> [VocalHint]? {
        let terms = ["singing", "choir", "humming", "rapping", "speech", "vocal"]
        return try intervals(in: url, duration: duration, matching: { name in terms.contains { name.contains($0) } }, progress: progress)
    }

    static func guitar(in url: URL, duration: Double, progress: @escaping (Double) -> Void) throws -> [VocalHint]? {
        let labels: Set<String> = ["guitar", "electric_guitar", "acoustic_guitar", "steel_guitar_slide_guitar", "guitar_tapping"]
        return try intervals(in: url, duration: duration, matching: labels.contains, progress: progress)
    }

    private static func intervals(in url: URL, duration: Double, matching: (String) -> Bool,
                                  progress: @escaping (Double) -> Void) throws -> [VocalHint]? {
        guard duration <= 720,
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1),
              let analyzer = try? SNAudioFileAnalyzer(url: url) else { return nil }
        let labels = Set(request.knownClassifications.filter(matching))
        guard !labels.isEmpty else { return nil }
        request.overlapFactor = 0.20
        let observer = Observer(labels: labels, duration: duration, progress: progress)
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return nil }
        let completion = DispatchSemaphore(value: 0)
        analyzer.analyze { complete in
            observer.completed(complete)
            completion.signal()
        }
        while completion.wait(timeout: .now() + 0.05) == .timedOut {
            if Task.isCancelled {
                analyzer.cancelAnalysis()
                throw CancellationError()
            }
        }
        return observer.result()
    }

    private final class Observer: NSObject, SNResultsObserving {
        let labels: Set<String>
        let duration: Double
        let progress: (Double) -> Void
        let lock = NSLock()
        var hints: [VocalHint] = []
        var complete = false
        var failed = false

        init(labels: Set<String>, duration: Double, progress: @escaping (Double) -> Void) {
            self.labels = labels; self.duration = duration; self.progress = progress
        }
        func request(_ request: any SNRequest, didProduce result: any SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let start = max(0, result.timeRange.start.seconds)
            let end = min(duration, result.timeRange.end.seconds)
            if end > start { progress(end / duration) }
            guard end > start,
                  let estimate = result.classifications.first(where: { labels.contains($0.identifier) && $0.confidence >= 0.48 }) else { return }
            lock.lock(); defer { lock.unlock() }
            if let previous = hints.last, start <= previous.end + 0.16 {
                hints[hints.count - 1] = VocalHint(start: previous.start, end: max(previous.end, end), confidence: max(previous.confidence, estimate.confidence))
            } else { hints.append(VocalHint(start: start, end: end, confidence: estimate.confidence)) }
        }
        func request(_ request: any SNRequest, didFailWithError error: any Error) {
            lock.lock(); defer { lock.unlock() }
            failed = true
        }
        func completed(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            complete = value
        }
        func result() -> [VocalHint]? {
            lock.lock(); defer { lock.unlock() }
            return complete && !failed ? hints : nil
        }
    }
}
