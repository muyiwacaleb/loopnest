import Foundation
import Network

/// Local remote control for Stream Deck, Bitfocus Companion, scripts and OSC apps.
/// Two listeners, both reachable only from this computer (loopback), both off until you switch them on in Settings:
///   HTTP on port 9123   e.g.  http://127.0.0.1:9123/mute/Browser     (Companion "Generic HTTP", Stream Deck "Website" action)
///   OSC (UDP) on 9124   e.g.  /loopnest/fader/Browser 0.75
final class RemoteControl: ObservableObject {
    static let httpPort: UInt16 = 9123
    static let oscPort: UInt16 = 9124
    @Published private(set) var running = false
    @Published private(set) var lastCommand = ""
    @Published private(set) var errorText = ""
    var handler: (([String], Float?) -> String)?      // runs on the main thread

    private var http: NWListener?
    private var osc: NWListener?
    private let queue = DispatchQueue(label: "loopnest.remote", qos: .utility)

    func start() {
        stop()
        errorText = ""
        do {
            let tcp = NWParameters.tcp
            tcp.requiredInterfaceType = .loopback
            let h = try NWListener(using: tcp, on: NWEndpoint.Port(rawValue: Self.httpPort)!)
            h.newConnectionHandler = { [weak self] c in self?.serve(c) }
            h.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st { DispatchQueue.main.async { self?.errorText = "HTTP port \(Self.httpPort): \(e.localizedDescription)"; self?.running = false } }
            }
            h.start(queue: queue); http = h

            let udp = NWParameters.udp
            udp.requiredInterfaceType = .loopback
            let o = try NWListener(using: udp, on: NWEndpoint.Port(rawValue: Self.oscPort)!)
            o.newConnectionHandler = { [weak self] c in self?.receiveOSC(c) }
            o.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st { DispatchQueue.main.async { self?.errorText = "OSC port \(Self.oscPort): \(e.localizedDescription)" } }
            }
            o.start(queue: queue); osc = o
            running = true
        } catch {
            errorText = "Could not start: \(error.localizedDescription)"
            running = false
        }
    }
    func stop() { http?.cancel(); osc?.cancel(); http = nil; osc = nil; running = false }

    // MARK: HTTP
    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let line = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { self.reply(c, 405, "{\"error\":\"use GET\"}"); return }
            var path = String(parts[1])
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            let comps = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            var value: Float?
            var cmd = comps
            if let last = comps.last, let v = Float(last), comps.count >= 2 { value = v; cmd = Array(comps.dropLast()) }
            DispatchQueue.main.async {
                let out = self.handler?(cmd, value) ?? "{\"error\":\"not ready\"}"
                self.lastCommand = "HTTP /" + comps.joined(separator: "/")
                self.queue.async { self.reply(c, out.hasPrefix("{\"error\"") ? 404 : 200, out) }
            }
        }
    }
    private func reply(_ c: NWConnection, _ code: Int, _ body: String) {
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        c.send(content: (head + body).data(using: .utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: OSC
    private func receiveOSC(_ c: NWConnection) {
        c.start(queue: queue)
        func next() {
            c.receiveMessage { [weak self] data, _, _, err in
                guard let self else { return }
                if let data, let (addr, val) = Self.parseOSC(data) {
                    let comps = addr.split(separator: "/").map(String.init).filter { $0 != "loopnest" || false }
                    var parts = comps
                    if parts.first == "loopnest" { parts.removeFirst() }
                    DispatchQueue.main.async { _ = self.handler?(parts, val); self.lastCommand = "OSC " + addr }
                }
                if err == nil { next() } else { c.cancel() }
            }
        }
        next()
    }
    /// Reads one OSC message: address, then an optional float or int argument.
    static func parseOSC(_ d: Data) -> (String, Float?)? {
        let b = [UInt8](d)
        guard let z = b.firstIndex(of: 0), z > 0, b[0] == 0x2F else { return nil }
        let addr = String(decoding: b[0..<z], as: UTF8.self)
        var i = (z + 4) & ~3
        guard i < b.count, b[i] == 0x2C else { return (addr, nil) }      // no type tags
        guard let tz = b[i...].firstIndex(of: 0) else { return (addr, nil) }
        let tags = String(decoding: b[(i + 1)..<tz], as: UTF8.self)
        i = (tz + 4) & ~3
        guard let t = tags.first, i + 4 <= b.count else { return (addr, nil) }
        let u = (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
        if t == "f" { return (addr, Float(bitPattern: u)) }
        if t == "i" { return (addr, Float(Int32(bitPattern: u))) }
        return (addr, nil)
    }
}
