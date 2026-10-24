import Foundation
import Network
import GemmaMeshKit

/// Browses `_local-ai._tcp` (PROTOCOL §1) with Bonjour. Keeps `api=openai` records of this phone's mesh;
/// `api=memory` is a phone's memory service, never a model. A record is not proof the node answers: the chat model
/// health-checks every node before routing to it. Needs NSBonjourServices and the local network permission.
final class Discovery: @unchecked Sendable {
    static let serviceType = "_local-ai._tcp"

    private let queue = DispatchQueue(label: "mesh.discovery")
    private var browser: NWBrowser?
    private var found: [String: Node] = [:]
    private var resolving: [String: NWConnection] = [:]

    /// Called on the main queue with every node found, by service name.
    var onChange: (([String: Node]) -> Void)?
    /// Called on the main queue when browsing fails, e.g. the local network permission was declined.
    var onProblem: ((String?) -> Void)?
    /// Our own memory record, so the phone does not list itself.
    var selfName: String?

    var mesh: String = "default" {
        didSet { if oldValue != mesh { queue.async { self.found = [:]; self.publish() }; if browser != nil { stop(); start() } } }
    }

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Discovery.serviceType, domain: nil), using: NWParameters())
        b.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let e), .waiting(let e):
                DispatchQueue.main.async { self?.onProblem?("Local network: \(e.localizedDescription)") }
            case .ready:
                DispatchQueue.main.async { self?.onProblem?(nil) }
            default: break
            }
        }
        b.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .added(let r): self.resolve(r)
                case .changed(old: _, new: let r, flags: _): self.resolve(r)
                case .removed(let r):
                    if case .service(let name, _, _, _) = r.endpoint, self.found.removeValue(forKey: name) != nil { self.publish() }
                default: break
                }
            }
        }
        browser = b
        b.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        queue.async {
            self.resolving.values.forEach { $0.cancel() }
            self.resolving = [:]
            self.found = [:]
            self.publish()
        }
    }

    private func publish() {
        let snapshot = found
        DispatchQueue.main.async { self.onChange?(snapshot) }
    }

    /// The TXT record says who it is; a short TCP connection to the service gives its IPv4 address.
    private func resolve(_ r: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = r.endpoint, name != selfName else { return }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = r.metadata { txt = record.dictionary }
        guard (txt["mesh"] ?? "default") == mesh, (txt["api"] ?? "openai") == "openai" else { return }

        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: r.endpoint, using: params)
        resolving[name]?.cancel()
        resolving[name] = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = conn.currentPath?.remoteEndpoint {
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    let node = Node(id: "mdns:\(name)", device: txt["device"] ?? name, url: "http://\(h):\(port.rawValue)",
                                    tier: txt["tier"] ?? "?", model: txt["model"] ?? "", discovered: true)
                    self.found[name] = node
                    self.publish()
                }
                conn.cancel()
                self.resolving[name] = nil
            case .failed, .cancelled:
                self.resolving[name] = nil
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak conn] in conn?.cancel() }
    }
}
