import Foundation
import SwiftUI

// MARK: - JSON

/// The server's payloads are wide and loosely shaped (a run file carries steps,
/// asks, usage, phases...), so the client reads them through one dynamic type
/// and thin typed views on top, rather than a Codable mirror that breaks on
/// every new field.
enum JSON: Codable, Hashable {
    case null, bool(Bool), num(Double), str(String), arr([JSON]), obj([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .num(n) }
        else if let s = try? c.decode(String.self) { self = .str(s) }
        else if let a = try? c.decode([JSON].self) { self = .arr(a) }
        else { self = .obj(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .num(let n): try c.encode(n)
        case .str(let s): try c.encode(s)
        case .arr(let a): try c.encode(a)
        case .obj(let o): try c.encode(o)
        }
    }

    subscript(_ key: String) -> JSON {
        if case .obj(let o) = self { return o[key] ?? .null }
        return .null
    }

    var string: String {
        switch self {
        case .str(let s): return s
        case .num(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }
    var double: Double {
        switch self {
        case .num(let n): return n
        case .str(let s): return Double(s) ?? 0
        case .bool(let b): return b ? 1 : 0
        default: return 0
        }
    }
    var int: Int { Int(double) }
    var bool: Bool {
        switch self {
        case .bool(let b): return b
        case .num(let n): return n != 0
        case .str(let s): return !s.isEmpty
        default: return false
        }
    }
    var array: [JSON] { if case .arr(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .obj(let o) = self { return o }; return [:] }
    var isNull: Bool { if case .null = self { return true }; return false }
    var nonEmpty: String? { let s = string; return s.isEmpty ? nil : s }

    /// Decodes through JSONSerialization. The Codable `init(from:)` above
    /// tries each case in turn, and every miss throws (and discards) a
    /// DecodingError: on a long transcript that was most of the time spent
    /// opening a chat. This is several times faster.
    static func parse(_ data: Data) -> JSON? {
        guard !data.isEmpty, let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(any: o)
    }

    /// A JSON string held inside a payload (a tool call's `raw` input),
    /// parsed once: transcripts and the to-do pill read these on every render.
    /// `.null` when it isn't JSON (yet: arguments stream in as fragments).
    static func parse(text s: String) -> JSON {
        guard !s.isEmpty else { return .null }
        let key = s as NSString
        if let hit = parseMemo.object(forKey: key) { return hit.v }
        let v = parse(Data(s.utf8)) ?? .null
        parseMemo.setObject(JSONRef(v), forKey: key)
        return v
    }

    private static let parseMemo: NSCache<NSString, JSONRef> = {
        let c = NSCache<NSString, JSONRef>()
        c.countLimit = 4000
        return c
    }()

    init(any o: Any) {
        switch o {
        case let s as String: self = .str(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .num(n.doubleValue)
        case let a as [Any]: self = .arr(a.map(JSON.init(any:)))
        case let d as [String: Any]: self = .obj(d.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }
}

final class JSONRef {
    let v: JSON
    init(_ v: JSON) { self.v = v }
}

// MARK: - API

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum API {
    static let port: String = {
        if let p = ProcessInfo.processInfo.environment["BRIDGE_PORT"], !p.isEmpty { return p }
        return Bundle.main.object(forInfoDictionaryKey: "BridgePort") as? String ?? "4319"
    }()
    static let base = URL(string: "http://127.0.0.1:\(port)")!
    static let root: String = {
        if let r = ProcessInfo.processInfo.environment["BRIDGE_ROOT"], !r.isEmpty { return r }
        return Bundle.main.object(forInfoDictionaryKey: "BridgeRoot") as? String ?? ""
    }()

    static func url(_ path: String) -> URL { URL(string: base.absoluteString + path)! }

    static func request(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> JSON {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, res) = try await URLSession.shared.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = JSON.parse(data) else {
            throw APIError(message: status >= 400 ? "HTTP \(status)" : "The server sent something that isn't Bridge's API (is another app on port \(port)?)")
        }
        if status >= 400 || json["ok"] == .bool(false) {
            throw APIError(message: json["error"].nonEmpty ?? "HTTP \(status)")
        }
        return json
    }

    static func get(_ path: String) async throws -> JSON { try await request("GET", path) }
    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:]) async throws -> JSON { try await request("POST", path, body) }
    @discardableResult
    static func delete(_ path: String) async throws -> JSON { try await request("DELETE", path) }

    static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
}

// MARK: - Server-sent events

/// Reads /api/events for as long as the app runs, reconnecting after a drop.
/// Every frame the server writes is a single `event:` line then a single
/// `data:` line, so a data line completes a frame.
final class EventStream {
    private var task: Task<Void, Never>?

    func start(_ onEvent: @escaping @MainActor (String, JSON) -> Void, onConnect: @escaping @MainActor (Bool) -> Void) {
        task = Task.detached {
            while !Task.isCancelled {
                do {
                    var req = URLRequest(url: API.url("/api/events"))
                    req.timeoutInterval = .infinity
                    let (bytes, res) = try await URLSession.shared.bytes(for: req)
                    let http = res as? HTTPURLResponse
                    guard http?.statusCode == 200, (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("event-stream") else {
                        throw APIError(message: "no event stream at /api/events")
                    }
                    await onConnect(true)
                    var event = "message"
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let raw = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                            if let json = JSON.parse(raw) {
                                let name = event
                                await onEvent(name, json)
                            }
                            event = "message"
                        }
                    }
                } catch {}
                await onConnect(false)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
}

// MARK: - Local view state

/// SwiftUI's `@State` is a compiler macro the Command Line Tools don't ship, so
/// views keep their local state in one of these instead.
final class Box<T>: ObservableObject {
    @Published var v: T
    init(_ v: T) { self.v = v }
}

// MARK: - Formatting

enum Fmt {
    /// "Checked just now" / "Checked 5m ago".
    static func checked(_ seconds: Double) -> String {
        let a = ago(seconds)
        return a.isEmpty ? "" : a == "now" ? "Checked just now" : a.contains(" ") ? "Checked \(a)" : "Checked \(a) ago"
    }

    // Formatters are costly to make (each loads locale data) and these run
    // per row and per message on every render: made once, reused. Rendering
    // happens on the main thread, so sharing them is safe.
    private static let monthDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    private static let hourMinute: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dayTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f }()
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let isoPlain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoLock = NSLock()
    private static var isoMemo: [String: Double] = [:]

    static func ago(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let d = Date().timeIntervalSince1970 - seconds
        if d < 60 { return "now" }
        if d < 3600 { return "\(Int(d / 60))m" }
        if d < 86400 { return "\(Int(d / 3600))h" }
        if d < 86400 * 30 { return "\(Int(d / 86400))d" }
        return monthDay.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// Memoised: PR and issue lists sort by these timestamps, which parsed
    /// every string O(n log n) times per render.
    static func iso(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        isoLock.lock()
        defer { isoLock.unlock() }
        if let v = isoMemo[s] { return v }
        let v = (isoFrac.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970 ?? 0
        if isoMemo.count > 20_000 { isoMemo.removeAll(keepingCapacity: true) }
        isoMemo[s] = v
        return v
    }

    static func money(_ n: Double) -> String {
        if n == 0 { return "$0" }
        return n < 1 ? String(format: "$%.2f", n) : String(format: "$%.2f", n)
    }

    static func tokens(_ n: Int) -> String {
        let short = { (v: Double, u: String) in (v >= 100 || v.rounded() == v ? String(format: "%.0f", v) : String(format: "%.1f", v)) + u }
        return n >= 1_000_000 ? short(Double(n) / 1_000_000, "M") : n >= 1000 ? short(Double(n) / 1000, "k") : "\(n)"
    }

    /// "Today", "Yesterday", else "Mon, Nov 24".
    static func day(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let d = Date(timeIntervalSince1970: seconds)
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return weekdayDay.string(from: d)
    }
    private static let weekdayDay: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE MMM d"); return f }()

    /// "14:05" in the user's clock style.
    static func time(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        return hourMinute.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func clock(_ seconds: Double) -> String {
        let d = Date(timeIntervalSince1970: seconds)
        return (Calendar.current.isDateInToday(d) ? hourMinute : dayTime).string(from: d)
    }
}

func openURL(_ s: String) {
    if let u = URL(string: s), !s.isEmpty { NSWorkspace.shared.open(u) }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Streamed deltas

/// Applies one `delta` event (server/jobs.js `push`) to a run held in memory:
/// the same patch vocabulary the stream writes to disk, so a streaming chat
/// updates per token without re-fetching its transcript. nil means "can't
/// apply here" (an ask, a task, the turn's end, a step not seen yet): the
/// caller re-fetches.
enum Delta {
    static func apply(_ d: JSON, to run: JSON) -> JSON? {
        guard case .obj(var r) = run, case .arr(var msgs)? = r["messages"] else { return nil }
        let msgId = d["msgId"].string
        guard !msgId.isEmpty, let k = msgs.lastIndex(where: { $0["id"].string == msgId }), case .obj(var m) = msgs[k] else { return nil }
        var steps = (m["steps"] ?? .null).array

        func edit(_ i: Int, _ f: (inout [String: JSON]) -> Void) -> Bool {
            guard steps.indices.contains(i), case .obj(var st) = steps[i] else { return false }
            f(&st)
            steps[i] = .obj(st)
            return true
        }

        if case .obj(let b) = d["blockStart"] {
            let i = (b["i"] ?? .null).int, step = b["step"] ?? .null
            if i == steps.count { steps.append(step) } else if steps.indices.contains(i) { steps[i] = step } else { return nil }
        } else if case .obj(let b) = d["blockDelta"] {
            let text = (b["text"] ?? .null).string
            let ok = edit((b["i"] ?? .null).int) { st in
                let cur = (st["text"] ?? .null).string
                // The server's caps (jobs.js CAP): past them it stops appending.
                if cur.utf16.count < ((st["kind"] ?? .null).string == "thinking" ? 40000 : 80000) { st["text"] = .str(cur + text) }
            }
            if !ok { return nil }
        } else if case .obj(let b) = d["blockEnd"] {
            if !edit((b["i"] ?? .null).int, { $0["streaming"] = .bool(false) }) { return nil }
        } else if case .obj(let b) = d["blockTokens"] {
            if !edit((b["i"] ?? .null).int, { $0["tokens"] = b["tokens"] ?? .null; $0["approx"] = b["approx"] ?? .null }) { return nil }
        } else if case .obj(let b) = d["blockDetail"] {
            let ok = edit((b["i"] ?? .null).int) { st in
                st["detail"] = b["detail"] ?? .null
                if let raw = b["raw"] { st["raw"] = raw }
            }
            if !ok { return nil }
        } else if case .obj(let b) = d["blockResult"] {
            let ok = edit((b["i"] ?? .null).int) { st in
                st["result"] = b["result"] ?? .null
                st["ok"] = b["ok"] ?? .null
                st["resultLines"] = b["resultLines"] ?? .null
            }
            if !ok { return nil }
        } else if !d["usage"].isNull, d["done"].isNull {
            m["usage"] = d["usage"]
            msgs[k] = .obj(m)
            r["messages"] = .arr(msgs)
            return .obj(r)
        } else {
            return nil
        }
        m["steps"] = .arr(steps)
        msgs[k] = .obj(m)
        r["messages"] = .arr(msgs)
        return .obj(r)
    }
}
