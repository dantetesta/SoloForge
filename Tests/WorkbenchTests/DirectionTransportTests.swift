import Foundation
import Testing
@testable import Workbench

private final class StreamStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.lastPathComponent == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let status = url.lastPathComponent == "gateway" ? 504 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let events = [
            #"{"type":"response.created"}"#,
            #"{"type":"response.output_text.delta","delta":"partial"}"#
        ]
        for event in events { send(event) }
        switch url.lastPathComponent {
        case "complete": send(#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)
        case "incomplete": send(#"{"type":"response.incomplete","response":{"status":"incomplete","output":[]}}"#)
        default: break
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func send(_ event: String) {
        client?.urlProtocol(self, didLoad: Data("data: \(event)\n\n".utf8))
    }
    override func stopLoading() {}
}

@Test func generationWaitsForCompletionAndDistinguishesTimeouts() async throws {
    func receive(_ route: String) async throws -> Director.Response {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamStub.self]
        return try await Director.receive(URLRequest(url: URL(string: "https://offline.invalid/" + route)!),
                                          configuration: config)
    }
    #expect(try await receive("complete").status == "completed")
    for route in ["partial", "incomplete", "timeout", "gateway"] {
        do {
            _ = try await receive(route)
            Issue.record("Unexpected success for \(route)")
        } catch let error as DirectionError {
            switch (route, error) {
            case ("partial", .interrupted), ("incomplete", .incomplete), ("timeout", .timeout), ("gateway", .response(504)): break
            default: Issue.record("Unexpected streaming error for \(route)")
            }
        }
    }
}
