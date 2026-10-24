import Foundation
import Network
import GemmaMeshKit

/// The memory authority's endpoint (PROTOCOL §4, `core/meshcore/memory_server.py`): `/memory/pull|push|status` on
/// :9401 while the app runs, announced over Bonjour as `_local-ai._tcp` with `api=memory`, instance `<device>-memory`.
/// The laptop's mirror finds it by itself, pushes its outbox and pulls everything new every 20 s. iOS suspends the app
/// in the background, so this serves only while the app is open (restarted when it comes back to the front).
final class MemoryServer: @unchecked Sendable {
    static let port: UInt16 = 9401

    private let store: MemoryStore
    private let model: String
    private let queue = DispatchQueue(label: "mesh.memory-server")
    private var listener: NWListener?
    /// Called on the main queue whenever the laptop's mirror pulls or pushes: the Mesh page's sync line.
    var onSynced: (() -> Void)?
    /// Called on the main queue after the laptop pushed new events, so the open screen can refresh.
    var onPushed: ((Int) -> Void)?
    /// Called on the main queue with a line for Settings: serving, or why not.
    var onState: ((String) -> Void)?

    var instance: String { "\(store.device)-memory" }

    init(store: MemoryStore, model: String) {
        self.store = store
        self.model = model
    }

    /// Starts serving and announces the service on this mesh (again, with the new name, when the mesh changes).
    func begin(mesh: String) {
        end()
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: MemoryServer.port)!)
            let txt: [String: String] = ["v": "1", "api": "memory", "base": "/memory", "auth": "none", "mesh": mesh, "tier": "T0",
                                         "model": model, "device": store.device, "load": "0.00"]
            l.service = NWListener.Service(name: instance, type: Discovery.serviceType, domain: nil, txtRecord: NWTXTRecord(txt))
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.report("serving on :\(MemoryServer.port) as \(self.instance)")
                case .failed(let e): self.report("cannot serve on :\(MemoryServer.port): \(e.localizedDescription)")
                case .waiting(let e): self.report("waiting for the network: \(e.localizedDescription)")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            listener = l
            l.start(queue: queue)
        } catch {
            report("cannot serve on :\(MemoryServer.port): \(error.localizedDescription)")
        }
    }

    func end() {
        listener?.cancel()
        listener = nil
    }

    private func report(_ s: String) { DispatchQueue.main.async { self.onState?(s) } }

    // ---- HTTP/1.1, just enough: one request per connection, GET or POST with a JSON body ----------

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buf
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").compactMap { line -> Int? in
                    let p = line.split(separator: ":", maxSplits: 1)
                    return p.count == 2 && p[0].lowercased() == "content-length" ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                let body = buf[end.upperBound...]
                if body.count >= length {
                    self.respond(c, head: head, body: Data(body.prefix(length)))
                    return
                }
            }
            if done || error != nil || buf.count > 64 << 20 { c.cancel(); return }
            self.read(c, buf)
        }
    }

    private func respond(_ c: NWConnection, head: String, body: Data) {
        let first = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let comps = URLComponents(string: target)
        let path = comps?.path ?? target
        let params = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        var status = 200
        var out: [String: Any]
        switch (method, path) {
        case ("GET", "/memory/status"):
            out = store.stats()
        case ("GET", "/memory/pull"):
            let after = Int64(params["after"] ?? "") ?? 0
            let limit = min(max(Int(params["limit"] ?? "") ?? 500, 1), 2000)
            let (events, last) = store.events(after: after, limit: limit)
            out = ["events": events.map { $0.json() }, "last": last]
            DispatchQueue.main.async { self.onSynced?() }
        case ("POST", "/memory/push"):
            if let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                let events = (o["events"] as? [[String: Any]] ?? []).compactMap(Event.from)
                let n = store.ingest(events)
                if n > 0 { DispatchQueue.main.async { self.onPushed?(n) } }
                DispatchQueue.main.async { self.onSynced?() }
                out = ["accepted": n]
            } else {
                status = 400
                out = ["error": ["message": "body is not JSON"]]
            }
        default:
            status = 404
            out = ["error": ["message": "not found"]]
        }
        let payload = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
        var resp = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
        resp.append(payload)
        c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
    }
}
