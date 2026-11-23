import Foundation

/// Talks to vMix's web API (vMix > Settings > Web Controller must be on). Only sends what you press.
final class VMixLink: ObservableObject {
    @Published var status = "Not tested yet"
    @Published var connected = false

    private func url(_ host: String, _ port: Int, _ query: String) -> URL? {
        URL(string: "http://\(host):\(port)/api/\(query)")
    }

    /// Asks vMix for its version to prove the connection works.
    func test(host: String, port: Int) {
        guard let u = url(host, port, "") else { status = "That address is not valid"; return }
        status = "Connecting…"
        var req = URLRequest(url: u); req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err { self.connected = false; self.status = "Could not reach vMix: \(err.localizedDescription)"; return }
                guard let data, let text = String(data: data, encoding: .utf8), text.contains("<vmix>") else {
                    self.connected = false; self.status = "Something answered, but it is not vMix's web controller"; return
                }
                let ver = text.components(separatedBy: "<version>").dropFirst().first?.components(separatedBy: "</version>").first ?? "unknown"
                self.connected = true; self.status = "Connected to vMix \(ver)"
            }
        }.resume()
    }

    /// Runs one vMix function, for example "SetMasterVolume" with value 80 (0 to 100).
    func send(host: String, port: Int, function: String, value: Int? = nil) {
        var q = "?Function=\(function)"
        if let value { q += "&Value=\(value)" }
        guard let u = url(host, port, q) else { return }
        var req = URLRequest(url: u); req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                if let err { self.status = "vMix command failed: \(err.localizedDescription)" }
                else if let h = resp as? HTTPURLResponse { self.status = h.statusCode == 200 ? "Sent \(function)" : "vMix answered \(h.statusCode)" }
            }
        }.resume()
    }
}
