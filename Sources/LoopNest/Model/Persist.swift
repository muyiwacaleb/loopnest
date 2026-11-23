import Foundation

/// Tolerant loading: settings saved by an older version keep working when new fields are added.
enum Persist {
    private static func obj<T: Encodable>(_ v: T) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) as? [String: Any]) ?? [:]
    }
    static func merged<T: Codable>(_ any: Any, _ def: T) -> T? {
        guard let o = any as? [String: Any] else { return nil }
        var base = obj(def)
        base.merge(o) { _, new in new }
        guard let d = try? JSONSerialization.data(withJSONObject: base) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    static func master(_ data: Data) -> MasterSettings? {
        guard let o = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return merged(o, MasterSettings())
    }
    static func strips(_ data: Data) -> [String: StripSettings]? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return o.compactMapValues { merged($0, StripSettings()) }
    }
    static func scenes(_ data: Data) -> [MixScene]? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return arr.compactMap { var s = $0
            if let m = s["master"], let mm = merged(m, MasterSettings()) { s["master"] = obj(mm) }
            if let st = s["strips"] as? [String: Any] { s["strips"] = st.compactMapValues { merged($0, StripSettings()).map { obj($0) } } }
            guard let d = try? JSONSerialization.data(withJSONObject: s) else { return nil }
            return try? JSONDecoder().decode(MixScene.self, from: d)
        }
    }
}
