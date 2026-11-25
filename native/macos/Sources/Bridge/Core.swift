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
        guard let json = try? JSONDecoder().decode(JSON.self, from: data) else {
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
                            if let json = try? JSONDecoder().decode(JSON.self, from: raw) {
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
    static func ago(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let d = Date().timeIntervalSince1970 - seconds
        if d < 60 { return "now" }
        if d < 3600 { return "\(Int(d / 60))m" }
        if d < 86400 { return "\(Int(d / 3600))h" }
        if d < 86400 * 30 { return "\(Int(d / 86400))d" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func iso(_ s: String) -> Double {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970 ?? 0
    }

    static func money(_ n: Double) -> String {
        if n == 0 { return "$0" }
        return n < 1 ? String(format: "$%.2f", n) : String(format: "$%.2f", n)
    }

    static func tokens(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }

    static func clock(_ seconds: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: seconds)) ? "HH:mm" : "MMM d, HH:mm"
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }
}

func openURL(_ s: String) {
    if let u = URL(string: s), !s.isEmpty { NSWorkspace.shared.open(u) }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
