import XCTest
import Foundation
import RelaySwarmCore
import RelaySwarmMedia

final class ReleasedLinkTraceTests: XCTestCase {
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
    private func bytes(_ value: Any?) -> Data? {
        guard let value = value as? [String: Int], let length = value["len"], let seed = value["seed"] else { return nil }
        return Data((0..<length).map { UInt8((seed + $0 * 31) & 255) })
    }
    private func fingerprint(_ bytes: Data?) -> Any {
        guard let bytes else { return NSNull() }
        return ["len": bytes.count, "sha": String(mediaSHA256(bytes).prefix(16))] as [String: Any]
    }
    private func event(_ action: PeerLinkEvent) -> [String: Any] {
        switch action {
        case .sendText(let text): return ["sendText": text]
        case .sendBinary(let bytes): return ["sendBinary": fingerprint(bytes)]
        case .closed(let reason): return ["closed": reason]
        case .report(let report): return ["result": ["outcome": report.outcome == .sendError ? "send-error" : String(describing: report.outcome),
            "receivedBytes": report.receivedBytes, "metadataReceived": report.metadataReceived, "draining": report.draining,
            "closeReason": report.closeReason.map { $0 as Any } ?? NSNull()]]
        case .resolved(_, let bytes): return ["resolved": fingerprint(bytes)]
        case .haveChanged(let keys): return ["haveChanged": keys]
        case .scheduleChanged: return ["scheduleChanged": true]
        case .serveRequest(let key): return ["serveRequest": key]
        case .serveRange(let key, let span): return ["serveRange": [key, span.start, span.end]]
        case .uploadCancelled(let bytes): return ["uploadCancelled": bytes]
        case .progress(let received, let size): return ["progress": [received, size]]
        }
    }
    func testAll48JavaScriptLinkTracesMatchTheDownloadedNativeCore() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "link-traces", withExtension: "json", subdirectory: "Fixtures"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let traces = try XCTUnwrap(document["traces"] as? [[String: Any]])
        XCTAssertEqual(traces.count, 48)
        for trace in traces {
            let config = try XCTUnwrap(trace["config"] as? [String: Any])
            var now: UInt64 = 1_792_000_000_000, requestID: UInt64?
            func n(_ value: Any?, _ fallback: UInt64 = 0) -> UInt64 { (value as? NSNumber)?.uint64Value ?? fallback }
            let link = PeerLink(settings: LinkSettings(maxSegmentBytes: n(config["maxSegmentBytes"]),
                maxQueuedRequests: UInt32(n(config["maxQueuedRequests"])), drainTimeoutMs: n(config["drainTimeoutMs"]), reliable: config["reliable"] as? Bool ?? false), now: now)
            let steps = try XCTUnwrap(trace["steps"] as? [[String: Any]]), expected = try XCTUnwrap(trace["expected"] as? [[String: Any]])
            for (index, step) in steps.enumerated() {
                let input = try XCTUnwrap(step["in"] as? [String: Any])
                var update = link.state(), actions = [PeerLinkEvent]()
                if let value = input["request"] as? [String: Any] {
                    update = link.request(now: now, key: value["key"] as! String, timeoutMs: n(value["timeoutMs"]), expectedSize: (value["expectedSize"] as? NSNumber)?.uint64Value)
                    requestID = update.requestId ?? requestID
                } else if let text = input["text"] as? String { update = link.handleText(now: now, text: text) }
                else if input["binary"] != nil { update = link.handleBinary(now: now, chunk: bytes(input["binary"])!) }
                else if let advance = input["advance"] {
                    let target = now + n(advance)
                    while let deadline = update.nextDeadline, deadline <= target {
                        actions += update.events; now = max(now, deadline); update = link.tick(now: deadline)
                    }
                    now = target
                } else if input["abort"] != nil, let requestID {
                    update = link.abort(now: now, id: requestID, abandoned: input["abort"] as? String == "abandon")
                } else if input["serve"] != nil { update = link.serveResponse(now: now, bytes: bytes(input["serve"])) }
                else if input["drain"] != nil { update = link.bufferedAmountLow(now: now, buffered: 0) }
                else if let reason = input["close"] as? String { update = link.closeLink(reason: reason) }
                else if let keys = input["sendHave"] as? [String] { update = link.sendHave(keys: keys) }
                else if let value = input["sendHaveChange"] as? [String: [String]] { update = link.sendHaveChange(add: value["add"]!, del: value["del"]!) }
                else if let value = input["sendContribution"] as? [String: Any] { update = link.sendContribution(serving: value["serving"] as? Bool ?? false, rendition: value["rendition"] as? String) }
                else if let value = input["sendFetching"] as? [String: Any] { update = link.sendFetching(key: value["k"] as! String, leaseMs: n(value["ms"])) }
                actions += update.events
                let events = actions.filter { if case .resolved = $0 { return false }; return true }.map(event)
                    + actions.filter { if case .resolved = $0 { return true }; return false }.map(event)
                let sets = link.sets()
                let state: [String: Any] = ["have": sets.have, "fetching": sets.fetching.map { [$0.key, $0.at] as [Any] },
                    "renditions": sets.renditions.map { [$0.key, $0.at] as [Any] }, "serving": sets.serving,
                    "rendition": sets.rendition.map { $0 as Any } ?? NSNull(), "busy": update.busy, "outboundInFlight": update.outboundInFlight,
                    "closed": update.closed, "bytesIn": update.bytesIn, "bytesOut": update.bytesOut]
                XCTAssertEqual(try json(events), try json(expected[index]["events"]!), "\(trace["name"]!) step \(index) events")
                XCTAssertEqual(try json(state), try json(expected[index]["state"]!), "\(trace["name"]!) step \(index) state")
            }
        }
    }
}
