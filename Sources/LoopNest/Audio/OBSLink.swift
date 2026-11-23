import Foundation
import CryptoKit

/// Talks to OBS Studio's built-in WebSocket server (OBS 28+: Tools → WebSocket Server Settings).
/// Shows live / recording state and lets you switch scenes. It never starts or stops your stream.
final class OBSLink: ObservableObject {
    struct Config: Codable { var host = "127.0.0.1"; var port = 4455; var password = ""; var autoConnect = false }
    @Published var config = Config() { didSet { if let d = try? JSONEncoder().encode(config) { UserDefaults.standard.set(d, forKey: "obs") } } }
    @Published var state = "Not connected"
    @Published var connected = false
    @Published var streaming = false
    @Published var recording = false
    @Published var scenes: [String] = []
    @Published var currentScene = ""
    var onSceneChanged: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var wantConnected = false
    private var retry: Timer?

    init() {
        if let d = UserDefaults.standard.data(forKey: "obs"), let c = try? JSONDecoder().decode(Config.self, from: d) { config = c }
        if config.autoConnect && !AppState.safeLaunch { connect() }
    }

    func connect() { wantConnected = true; config.autoConnect = true; open() }
    func disconnect() {
        wantConnected = false; config.autoConnect = false
        retry?.invalidate(); task?.cancel(with: .goingAway, reason: nil); task = nil
        connected = false; streaming = false; recording = false; state = "Not connected"
    }

    private func open() {
        retry?.invalidate(); task?.cancel(with: .goingAway, reason: nil)
        guard let url = URL(string: "ws://\(config.host):\(config.port)") else { state = "Bad address"; return }
        state = "Connecting…"
        let t = session.webSocketTask(with: url); task = t; t.resume(); receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure(let e): DispatchQueue.main.async { self.dropped(e.localizedDescription) }
            case .success(let m):
                if case .string(let s) = m { DispatchQueue.main.async { self.handle(s) } }
                self.receive(t)
            }
        }
    }

    private func dropped(_ why: String) {
        connected = false; streaming = false; recording = false
        state = wantConnected ? "OBS not reachable — is OBS open with WebSocket on? Retrying…" : "Not connected"
        task = nil
        if wantConnected { retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.open() } }
    }

    private func send(_ op: Int, _ d: [String: Any]) {
        guard let t = task, let data = try? JSONSerialization.data(withJSONObject: ["op": op, "d": d]),
              let s = String(data: data, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }
    private func request(_ type: String, _ data: [String: Any] = [:]) {
        send(6, ["requestType": type, "requestId": type, "requestData": data])
    }
    private func b64sha(_ s: String) -> String { Data(SHA256.hash(data: Data(s.utf8))).base64EncodedString() }

    private func handle(_ text: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let op = o["op"] as? Int, let d = o["d"] as? [String: Any] else { return }
        switch op {
        case 0:   // Hello -> Identify
            var ident: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": 4 | 64]
            if let a = d["authentication"] as? [String: Any], let ch = a["challenge"] as? String, let salt = a["salt"] as? String {
                let secret = b64sha(config.password + salt)
                ident["authentication"] = b64sha(secret + ch)
            }
            send(1, ident)
        case 2:   // Identified
            connected = true; state = "Connected to OBS"
            request("GetSceneList"); request("GetStreamStatus"); request("GetRecordStatus")
        case 5:   // Event
            guard let type = d["eventType"] as? String, let ev = d["eventData"] as? [String: Any] else { return }
            switch type {
            case "StreamStateChanged": streaming = (ev["outputActive"] as? Bool) ?? streaming
            case "RecordStateChanged": recording = (ev["outputActive"] as? Bool) ?? recording
            case "CurrentProgramSceneChanged":
                if let n = ev["sceneName"] as? String { currentScene = n; onSceneChanged?(n) }
            case "SceneListChanged": request("GetSceneList")
            default: break
            }
        case 7:   // Response
            guard let type = d["requestType"] as? String, let r = d["responseData"] as? [String: Any] else {
                if (d["requestStatus"] as? [String: Any])?["result"] as? Bool == false, connected == false { state = "OBS refused the connection — check the password" }
                return
            }
            switch type {
            case "GetSceneList":
                currentScene = (r["currentProgramSceneName"] as? String) ?? currentScene
                let arr = (r["scenes"] as? [[String: Any]]) ?? []
                scenes = arr.compactMap { $0["sceneName"] as? String }.reversed()      // OBS lists bottom-to-top
            case "GetStreamStatus": streaming = (r["outputActive"] as? Bool) ?? false
            case "GetRecordStatus": recording = (r["outputActive"] as? Bool) ?? false
            default: break
            }
        default: break
        }
    }

    func switchScene(_ name: String) { request("SetCurrentProgramScene", ["sceneName": name]) }
}
