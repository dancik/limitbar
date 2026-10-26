import CryptoKit
import Foundation
import SQLite3

/// The Usage view: tokens per model per day, read from each CLI's own local logs — never from a
/// server, never by running a CLI. Logs are read only while the panel shows Usage, at most once a minute,
/// and only the bytes appended since the last read.
///
///   Claude — ~/.claude/projects/**/*.jsonl   one line per API reply, with `message.usage`
///   Codex  — ~/.codex/sessions/**/*.jsonl    `token_count` events carry the session's running total
///   Grok   — ~/.grok/sessions/*/*/usage.json per-turn totals per model, written by Grok Build itself
///   Gemini — ~/.gemini/antigravity-cli/conversations/*.db  one SQLite database per conversation; every
///            model step's metadata (protobuf) carries its time and token counts
///            (opened read-only; only those numbers and the model name are taken)
///
/// What is kept (~/Library/Caches/limitbar/usage.json, 0600): per log file a hashed key, its size, mtime,
/// inode and birth time, the read offset, and token counts per model and day; for Claude the replies of
/// the window under hashed ids (to count each reply once), for Codex the current model and running total.
/// Never a path, a project name, an id in the clear, or any text of a conversation.

struct ModelTotal: Codable, Equatable {
    var tokens = 0
    var calls = 0
}

/// day ("yyyy-MM-dd", local time) → model → totals
typealias DayBuckets = [String: [String: ModelTotal]]

struct VendorUsage: Equatable {
    var vendor: Vendor
    var reported: Bool          // false: this CLI keeps no token log limitbar can read
    var buckets: DayBuckets     // only days inside the window

    func total(_ days: [String]) -> ModelTotal {
        models(days).reduce(into: ModelTotal()) { $0.tokens = sat($0.tokens, $1.total.tokens); $0.calls = sat($0.calls, $1.total.calls) }
    }

    /// Models used on these days, most tokens first.
    func models(_ days: [String]) -> [(model: String, total: ModelTotal)] {
        var m: [String: ModelTotal] = [:]
        for d in days {
            for (k, v) in buckets[d] ?? [:] {
                var t = m[k, default: ModelTotal()]
                t.tokens = sat(t.tokens, v.tokens); t.calls = sat(t.calls, v.calls)
                m[k] = t
            }
        }
        return m.filter { $0.value.tokens > 0 || $0.value.calls > 0 }
            .sorted { $0.value.tokens != $1.value.tokens ? $0.value.tokens > $1.value.tokens : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    func tokens(on day: String) -> Int { (buckets[day] ?? [:]).values.reduce(0) { sat($0, $1.tokens) } }
}

struct UsageDay: Equatable {
    var key: String             // "yyyy-MM-dd", local
    var date: Date              // its start, local
}

struct UsageSummary: Equatable {
    var days: [UsageDay]        // the last 7 local days, oldest first; days.last is today
    var vendors: [Vendor: VendorUsage]
    var readAt: Date
    var keys: [String] { days.map(\.key) }
}

enum UsageDays {
    /// One formatter per thread: DateFormatter is costly to make.
    private static func formatter() -> DateFormatter {
        let k = "limitbar.dayFormatter"
        if let f = Thread.current.threadDictionary[k] as? DateFormatter, f.timeZone == TimeZone.current { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        Thread.current.threadDictionary[k] = f
        return f
    }

    static func key(_ d: Date) -> String { formatter().string(from: d) }

    /// Computed with the calendar, never by parsing a key back: in zones where a DST change skips
    /// midnight, "yyyy-MM-dd" has no 00:00 and a parsed key would be nil.
    static func window(_ now: Date = Date()) -> [UsageDay] {
        let c = Calendar.current, today = c.startOfDay(for: now)
        return (0..<7).reversed().compactMap { c.date(byAdding: .day, value: -$0, to: today) }
            .map { UsageDay(key: key($0), date: c.startOfDay(for: $0)) }
    }

    /// "2030-01-02T03:04:05.678901+00:00", "2030-01-02T03:04:05.678Z" → seconds since 1970, without a
    /// formatter (they are costly and this runs once per log line).
    static func epoch(_ s: String) -> Double? {
        let b = Array(s.utf8)
        guard b.count >= 19, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x20, b[13] == 0x3A, b[16] == 0x3A else { return nil }
        func n(_ i: Int, _ len: Int) -> Int? {
            var v = 0
            for j in i..<(i + len) { guard j < b.count, b[j] >= 0x30, b[j] <= 0x39 else { return nil }; v = v * 10 + Int(b[j] - 0x30) }
            return v
        }
        guard let y = n(0, 4), let mo = n(5, 2), let d = n(8, 2), let h = n(11, 2), let mi = n(14, 2), let se = n(17, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se < 61 else { return nil }
        var i = 19, frac = 0.0
        if i < b.count, b[i] == 0x2E {
            var scale = 0.1; i += 1
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { frac += Double(b[i] - 0x30) * scale; scale /= 10; i += 1 }
        }
        var offset = 0
        if i < b.count, b[i] == 0x2B || b[i] == 0x2D {
            guard let oh = n(i + 1, 2), let om = n(i + (i + 3 < b.count && b[i + 3] == 0x3A ? 4 : 3), 2) else { return nil }
            offset = (oh * 3600 + om * 60) * (b[i] == 0x2D ? -1 : 1)
        } else if !(i < b.count && (b[i] == 0x5A || b[i] == 0x7A)) {
            return nil                                  // no zone: refuse rather than guess
        }
        // days from civil (Howard Hinnant), proleptic Gregorian
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Double(days * 86400 + h * 3600 + mi * 60 + se - offset) + frac
    }

    static func dayKey(_ any: Any?) -> String? {
        (any as? String).flatMap(epoch).map { key(Date(timeIntervalSince1970: $0)) }
    }
}

/// A count from a log, bounded so that no corrupt or hostile file can overflow a sum (2^48 tokens is far
/// beyond any real reply) or make a negative count.
func logCount(_ any: Any?) -> Int {
    switch any {
    case let i as Int: return min(max(i, 0), 1 << 48)
    case let d as Double where d.isFinite: return Int(min(max(d, 0), Double(1 << 48)))
    case let u as UInt64: return Int(min(u, 1 << 48))
    default: return 0
    }
}

/// Addition that stops at Int.max instead of trapping: counts come from files anyone could have written.
func sat(_ a: Int, _ b: Int) -> Int {
    let (r, over) = a.addingReportingOverflow(b)
    return over ? (b > 0 ? Int.max : Int.min) : r
}

/// A model name from a log: short plain text only, or nil.
func logModel(_ any: Any?) -> String? {
    guard let s = any as? String, !s.isEmpty, s.utf8.count <= 100, !s.contains(where: { $0.isNewline }) else { return nil }
    return s
}

/// "1.23B", "456.7M", "12.34M", "567.8k", "890"
func compactTokens(_ n: Int) -> String {
    let x = Double(n)
    if x >= 1e9 { return String(format: "%.2fB", x / 1e9) }
    if x >= 1e8 { return String(format: "%.1fM", x / 1e6) }
    if x >= 1e6 { return String(format: "%.2fM", x / 1e6) }
    if x >= 1e3 { return String(format: "%.1fk", x / 1e3) }
    return String(n)
}

// MARK: - Index

/// One Claude reply as last seen: day, model, tokens.
private struct Reply: Codable, Equatable {
    var d: String
    var m: String
    var t: Int
}

private struct FileState: Codable {
    var vendor: Vendor
    var ino: UInt64 = 0
    var born: Double = 0        // with the inode: a replaced file is read again from the start
    var size: Int64 = 0
    var mtime: Double = 0
    var offset: Int64 = 0
    var skipping: Bool?         // inside a line too long to be a token record: skip to its end
    var buckets: DayBuckets = [:]           // Codex, Grok
    var replies: [String: Reply]?           // Claude: hashed reply id → its count
    var model: String?                      // Codex: the current turn's model
    var total: Int?                         // Codex: the session's running token total
}

private struct IndexFile: Codable {
    var version: Int
    var timeZone: String        // day keys are local days: another zone means reading everything again
    var files: [String: FileState]
}

/// Lists log files under a root, re-reading only directories whose mtime moved: adding or removing a file
/// changes its folder's mtime, so an unchanged folder still has the same entries. Symlinks are not followed.
private final class Tree {
    private let root: String
    private let match: (String) -> Bool
    private let depth: Int?     // only files exactly this many path components below the root
    private var dirs: [String: (mtime: timespec, subdirs: [String], files: [String])] = [:]

    /// The root itself may be a link (a dotfiles setup often links ~/.claude); nothing below it is followed.
    init(_ root: String, depth: Int? = nil, match: @escaping (String) -> Bool) {
        self.root = realpath(root, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root
        self.depth = depth; self.match = match
    }

    func files(stop: () -> Bool) -> [String]? {
        var out: [String] = [], stack = [(root, 0)], seen = Set<String>()
        while let (d, level) = stack.popLast() {
            if stop() { return nil }
            seen.insert(d)
            var st = stat()
            guard lstat(d, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            let known: (subdirs: [String], files: [String])
            if let k = dirs[d], k.mtime.tv_sec == st.st_mtimespec.tv_sec, k.mtime.tv_nsec == st.st_mtimespec.tv_nsec {
                known = (k.subdirs, k.files)
            } else {
                var subs: [String] = [], logs: [String] = []
                guard let h = opendir(d) else { continue }
                while let e = readdir(h) {
                    let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self) }
                    if name == "." || name == ".." { continue }
                    let p = d + "/" + name
                    var type = Int32(e.pointee.d_type)
                    if type == DT_UNKNOWN {         // some file systems do not say: ask, without following links
                        var t = stat()
                        guard lstat(p, &t) == 0 else { continue }
                        type = (t.st_mode & S_IFMT) == S_IFDIR ? DT_DIR : (t.st_mode & S_IFMT) == S_IFREG ? DT_REG : DT_UNKNOWN
                    }
                    if type == DT_DIR { subs.append(p) }
                    else if type == DT_REG, match(name) { logs.append(p) }
                }
                closedir(h)
                dirs[d] = (st.st_mtimespec, subs, logs)
                known = (subs, logs)
            }
            if depth.map({ level + 1 < $0 }) ?? true { stack += known.subdirs.map { ($0, level + 1) } }
            if depth.map({ level + 1 == $0 }) ?? true { out += known.files }
        }
        for k in dirs.keys where !seen.contains(k) { dirs[k] = nil }
        return out
    }
}

// MARK: - Scanner

final class UsageScanner {
    private let cacheFile: String?
    private var index: [String: FileState] = [:]
    private var indexZone = TimeZone.current.identifier
    private let trees: [(Vendor, Tree)]
    private static let indexVersion = 2
    /// A line longer than this cannot be a token record (those are a few KB); it is skipped unread.
    private static let maxLine = 64 << 20

    init(home: String, cacheFile: String?) {
        self.cacheFile = cacheFile
        trees = [(.claude, Tree("\(home)/.claude/projects") { $0.hasSuffix(".jsonl") }),
                 (.codex, Tree("\(home)/.codex/sessions") { $0.hasSuffix(".jsonl") }),
                 (.grok, Tree("\(home)/.grok/sessions", depth: 3) { $0 == "usage.json" }),
                 (.gemini, Tree("\(home)/.gemini/antigravity-cli/conversations", depth: 1) { $0.hasSuffix(".db") })]
        var ist = stat()
        if let f = cacheFile, lstat(f, &ist) == 0, ist.st_size < 64 << 20, let d = try? Data(contentsOf: URL(fileURLWithPath: f)),
           let i = try? JSONDecoder().decode(IndexFile.self, from: d),
           i.version == Self.indexVersion, i.timeZone == TimeZone.current.identifier {
            index = i.files
        }
    }

    /// nil when `stop` turned true first; what was read so far is kept, so the next scan goes on from there.
    func scan(now: Date = Date(), stop: () -> Bool = { false }) -> UsageSummary? {
        if indexZone != TimeZone.current.identifier { index = [:]; indexZone = TimeZone.current.identifier }
        let days = UsageDays.window(now)
        let first = days[0].key, cutoff = days[0].date.timeIntervalSince1970
        var visited = Set<String>()
        var stopped = false
        scanning: for (vendor, tree) in trees {
            guard let paths = tree.files(stop: stop) else { stopped = true; break }
            for path in paths {
                if stop() { stopped = true; break scanning }
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }   // links are not followed
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                guard mtime >= cutoff else { continue }          // untouched since before the window
                let key = Self.hash(path)
                let ino = UInt64(st.st_ino)
                let born = Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) / 1e9
                var s = index[key] ?? FileState(vendor: vendor)
                if s.vendor != vendor || s.ino != ino || s.born != born || st.st_size < s.offset {
                    s = FileState(vendor: vendor, ino: ino, born: born)      // new, replaced or truncated
                }
                var complete = true, readable = true
                if st.st_size != s.size || mtime != s.mtime {
                    autoreleasepool {
                        switch vendor {
                        case .claude, .codex:
                            let r = readLines(path, vendor, from: s.offset, skipping: s.skipping ?? false, size: st.st_size, stop: stop) {
                                if vendor == .claude { self.claudeLine($0, &s) } else { self.codexLine($0, &s) }
                            }
                            s.offset = r.offset
                            s.skipping = r.skipping ? true : nil
                            complete = r.finished
                            readable = r.ok           // could not read it: keep its size unstamped, again next time
                        case .grok: readable = grokFile(path, &s)
                        case .gemini:
                            switch withoutActuallyEscaping(stop, do: { geminiFile(path, &s, size: st.st_size, stop: $0) }) {
                            case .read: break
                            case .busy: readable = false
                            case .stopped: complete = false
                            }
                        }
                    }
                    if complete && readable { s.size = st.st_size; s.mtime = mtime }   // else: again next time
                }
                s.buckets = s.buckets.filter { $0.key >= first }
                s.replies = s.replies?.filter { $0.value.d >= first }
                index[key] = s
                visited.insert(key)
                if !complete { stopped = true; break scanning }
            }
        }
        if !stopped { index = index.filter { visited.contains($0.key) } }   // gone or older than the window
        save()
        if stopped { return nil }

        var vendors: [Vendor: VendorUsage] = [:]
        for v in [Vendor.codex, .grok, .gemini] {
            var b: DayBuckets = [:]
            for s in index.values where s.vendor == v {
                for (day, models) in s.buckets { for (m, t) in models { Self.add(&b, day, m, t.tokens, t.calls) } }
            }
            vendors[v] = VendorUsage(vendor: v, reported: true, buckets: b)
        }
        // Claude: one reply counts once even when it appears in several files (a resumed session can copy
        // its history into a new file); the copy that saw the most tokens wins.
        var replies: [String: Reply] = [:]
        for s in index.values where s.vendor == .claude {
            for (id, r) in s.replies ?? [:] where (replies[id]?.t ?? -1) < r.t { replies[id] = r }
        }
        var b: DayBuckets = [:]
        for r in replies.values { Self.add(&b, r.d, r.m, r.t, 1) }
        vendors[.claude] = VendorUsage(vendor: .claude, reported: true, buckets: b)
        return UsageSummary(days: days, vendors: vendors, readAt: now)
    }

    fileprivate static func add(_ b: inout DayBuckets, _ day: String, _ model: String, _ tokens: Int, _ calls: Int) {
        var t = b[day, default: [:]][model, default: ModelTotal()]
        t.tokens = sat(t.tokens, tokens)
        t.calls = sat(t.calls, calls)
        b[day, default: [:]][model] = t
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func save() {
        guard let f = cacheFile,
              let d = try? JSONEncoder().encode(IndexFile(version: Self.indexVersion, timeZone: indexZone, files: index))
        else { return }
        Paths.write(d, to: f)
    }

    // MARK: reading

    /// Reads from the saved offset to the last complete line, in 4 MB chunks. `onLine` sees only lines that
    /// pass a cheap byte check; a line longer than `maxLine` is skipped without being kept in memory.
    /// Returns false when `stop` cut the read short (the offset still ends on a whole line).
    private func readLines(_ path: String, _ vendor: Vendor, from start: Int64, skipping wasSkipping: Bool, size: Int64,
                           stop: () -> Bool, onLine: (UnsafeRawBufferPointer) -> Void) -> (offset: Int64, skipping: Bool, finished: Bool, ok: Bool) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return (start, wasSkipping, true, false) }
        var fst = stat()
        guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG else { close(fd); return (start, wasSkipping, true, false) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(start))) != nil else { return (start, wasSkipping, true, false) }
        var off = start                    // first byte not yet consumed
        var skipping = wasSkipping
        var buf = Data()                   // bytes read from `off` on
        var searched = 0                   // bytes of `buf` already known to hold no newline
        var finished = true, ok = true
        while off + Int64(buf.count) < size {
            if stop() { finished = false; break }
            let want = Int(min(Int64(4 << 20), size - off - Int64(buf.count)))
            let more: Bool = autoreleasepool {
                guard let chunk = try? h.read(upToCount: want), !chunk.isEmpty else { ok = false; return false }
                buf.append(chunk)
                let used: Int = buf.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return 0 }
                    var i = 0, from = searched
                    while from < raw.count, let nl = memchr(base + from, 0x0A, raw.count - from) {
                        let end = UnsafeRawPointer(nl) - base
                        if skipping { skipping = false }
                        else if end > i {
                            let line = UnsafeRawBufferPointer(rebasing: raw[i..<end])
                            if wanted(line, vendor) { onLine(line) }
                        }
                        i = end + 1; from = i
                    }
                    return i
                }
                off += Int64(used)
                buf = buf.subdata(in: used..<buf.count)
                searched = buf.count
                if buf.count > Self.maxLine {      // drop the oversized line's bytes, skip to its end
                    off += Int64(buf.count); buf = Data(); searched = 0; skipping = true
                }
                return true
            }
            guard more else { break }
        }
        return (off, skipping, finished, ok)
    }

    private static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private static let kUsage = bytes(#""usage":{"#), kAssistant = bytes(#""assistant""#),
                       kTokenCount = bytes(#""token_count""#), kTurn = bytes(#""turn_context""#)

    private func wanted(_ raw: UnsafeRawBufferPointer, _ v: Vendor) -> Bool {
        switch v {
        case .claude: return Self.find(raw, Self.kUsage) && Self.find(raw, Self.kAssistant)
        case .codex: return Self.find(raw, Self.kTokenCount) || Self.find(raw, Self.kTurn)
        default: return false
        }
    }

    private static func find(_ raw: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = raw.baseAddress else { return false }
        return needle.withUnsafeBytes { memmem(base, raw.count, $0.baseAddress, $0.count) != nil }
    }

    /// The fields of a Claude reply line, found by walking its JSON structure without decoding it: only
    /// keys of the line itself (`type`, `timestamp`) and of its `message` object (`model`, `id`, `usage`)
    /// are looked at, so nothing inside `content`, tool inputs or nested records (subagent progress lines
    /// carry whole replies of their own) can be taken for them. Strings are skipped with memchr; only short
    /// values of those keys are ever turned into Swift strings. nil when the line is not a reply.
    private static func claudeFields(_ raw: UnsafeRawBufferPointer) -> (id: String, model: String, time: String, usage: Data)? {
        guard let base = raw.baseAddress else { return nil }
        let n = raw.count
        var i = 0, depth = 0, inMessage = false
        var key: String?                    // the tracked key whose value comes next
        var type: String?, time: String?, model: String?, id: String?, requestId: String?
        var usageStart: Int?, usageEnd: Int?
        func string(_ q: Int) -> Int? {     // index of the quote that closes the string opening at q
            var p = q + 1
            while p < n, let hit = memchr(base + p, 0x22, n - p) {
                let e = UnsafeRawPointer(hit) - base
                var bs = 0, k = e - 1
                while k > q, raw[k] == 0x5C { bs += 1; k -= 1 }
                if bs % 2 == 0 { return e }
                p = e + 1
            }
            return nil
        }
        func text(_ a: Int, _ b: Int) -> String? {     // plain short values only; anything escaped → nil
            guard b - a <= 200, !UnsafeRawBufferPointer(rebasing: raw[a..<b]).contains(0x5C) else { return nil }
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[a..<b]), as: UTF8.self)
        }
        while i < n {
            switch raw[i] {
            case 0x22:
                guard let e = string(i) else { return nil }
                var j = e + 1
                while j < n, raw[j] == 0x20 || raw[j] == 0x09 || raw[j] == 0x0D { j += 1 }
                let tracked = depth == 1 || (depth == 2 && inMessage)
                if j < n, raw[j] == 0x3A {                       // a key
                    key = tracked ? text(i + 1, e) : nil
                    i = j + 1
                    continue
                }
                if tracked, let k = key {
                    let v = text(i + 1, e)
                    if depth == 1 {
                        if k == "type" { type = v } else if k == "timestamp" { time = v } else if k == "requestId" { requestId = v }
                    } else if k == "model" { model = v } else if k == "id" { id = v }
                }
                key = nil
                i = e + 1
            case 0x7B, 0x5B:
                if raw[i] == 0x7B {
                    if depth == 1, key == "message" { inMessage = true }
                    if depth == 2, inMessage, key == "usage", usageStart == nil { usageStart = i }
                }
                depth += 1; key = nil; i += 1
            case 0x7D, 0x5D:
                depth -= 1
                if depth == 2, inMessage, usageStart != nil, usageEnd == nil { usageEnd = i }
                if depth == 1 { inMessage = false }
                key = nil; i += 1
            default:
                i += 1
            }
        }
        guard type == "assistant", let m = model, let t = time, let rid = id ?? requestId,
              let a = usageStart, let b = usageEnd, b > a else { return nil }
        return (rid, m, t, Data(UnsafeRawBufferPointer(rebasing: raw[a...b])))
    }

    private func claudeLine(_ raw: UnsafeRawBufferPointer, _ s: inout FileState) {
        guard let f = Self.claudeFields(raw), f.model != "<synthetic>", logModel(f.model) != nil, let day = UsageDays.dayKey(f.time),
              let u = Fetch.json(f.usage) else { return }
        let n = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
            .reduce(0) { $0 + logCount(u[$1]) }
        // A reply is written once per content block, each line with the usage so far: the last one wins.
        var r = s.replies ?? [:]
        r[Self.hash(f.id)] = Reply(d: day, m: f.model, t: n)
        s.replies = r
    }

    private func codexLine(_ raw: UnsafeRawBufferPointer, _ s: inout FileState) {
        guard let e = Fetch.json(Data(raw)), let p = e["payload"] as? [String: Any] else { return }
        switch e["type"] as? String {
        case "turn_context":
            if let m = logModel(p["model"]) { s.model = m }
        case "event_msg" where p["type"] as? String == "token_count":
            guard let tu = (p["info"] as? [String: Any])?["total_token_usage"] as? [String: Any],
                  let day = UsageDays.dayKey(e["timestamp"]) else { return }
            let total = logCount(tu["input_tokens"]) + logCount(tu["output_tokens"])
            var delta = total - (s.total ?? 0)
            if delta < 0 { delta = total }               // a new running total (e.g. after a compaction)
            s.total = total
            if delta > 0 { Self.add(&s.buckets, day, s.model ?? "unknown model", delta, 1) }
        default:
            break
        }
    }

    /// usage.json is small and rewritten after every turn: read it whole, without following a link, and
    /// replace the counts only when it parses. false: it could not be read; tried again next time.
    private func grokFile(_ path: String, _ s: inout FileState) -> Bool {
        s.offset = 0
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var fst = stat()
        guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG else { return false }
        guard fst.st_size <= 16 << 20 else { s.buckets = [:]; return true }      // not Grok Build's file
        guard let d = try? h.read(upToCount: (16 << 20) + 1) else { return false }
        guard d.count <= 16 << 20 else { s.buckets = [:]; return true }            // grew past the bound
        guard let o = Fetch.json(d) else { return false }
        var b: DayBuckets = [:]
        func addModels(_ usage: Any?, day: String) {
            for (key, v) in (usage as? [String: Any]) ?? [:] {
                guard let m = logModel(key), let u = v as? [String: Any] else { continue }
                let n = u["totalTokens"] != nil ? logCount(u["totalTokens"]) : sat(logCount(u["inputTokens"]), logCount(u["outputTokens"]))
                Self.add(&b, day, m, n, logCount(u["modelCalls"]))
            }
        }
        let turns = (o["turns"] as? [[String: Any]]) ?? []
        if turns.isEmpty, let sess = o["session"] as? [String: Any], let day = UsageDays.dayKey(o["updatedAt"]) {
            addModels(sess["modelUsage"], day: day)
        }
        for t in turns { if let day = UsageDays.dayKey(t["endedAt"]) { addModels(t["modelUsage"], day: day) } }
        s.buckets = b
        return true
    }
}

// MARK: - Antigravity (Gemini)

extension UsageScanner {
    enum DBRead { case read, busy, stopped }

    /// One conversation database, read whole whenever it changed (they are a few MB at most). Each model
    /// step's `metadata` is a protobuf: field 1 = its time (seconds), field 9 = token counts, where
    /// 1 = model number, 2 = new input, 3 = output with thinking, 5 = cached input. The model's name comes
    /// from `gen_metadata` (1.4.1 = the same number, 1.19 = its name). Checked against agy's own JSON
    /// report: the sums of fields 2 and 3 equal its input and output tokens exactly.
    ///
    /// The file is treated as untrusted: opened read-only and immutable, symlinks refused, schema code not
    /// trusted, both names must be real tables, rows, blobs and time are bounded, and closing the panel
    /// interrupts the query. The counts already known for the file are replaced only by a read that
    /// completes. A file that is not agy's format counts nothing; one that runs out of time keeps what it
    /// had until it changes. `.busy`: agy is writing it, or it could not be read; tried again next time.
    fileprivate func geminiFile(_ path: String, _ s: inout FileState, size: Int64, stop: @escaping () -> Bool) -> DBRead {
        guard size <= 512 << 20 else { s.buckets = [:]; return .read }     // not a conversation of agy's
        // The databases use a write-ahead log. While it holds changes (a non-empty "-wal" next to it) agy is
        // writing: skip it until agy is done. Otherwise everything is in the file itself, so it is opened
        // immutable (a plain read-only open of a WAL database fails when it cannot create "-shm").
        var w = stat()
        if lstat(path + "-wal", &w) == 0, w.st_size > 0 { return .busy }
        var db: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let db = db else { sqlite3_close(db); return .busy }
        defer { sqlite3_close(db) }
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 4 << 20)
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 4096)
        _ = sqlite3_exec(db, "PRAGMA trusted_schema=OFF", nil, nil, nil)
        // Interrupt after 5 s, or as soon as the panel closes.
        final class Guard { let deadline = Date().addingTimeInterval(5); let stop: () -> Bool
                            var stopped = false, late = false
                            init(_ stop: @escaping () -> Bool) { self.stop = stop } }
        let guardBox = Guard(stop)
        sqlite3_progress_handler(db, 10_000, { ctx in
            guard let ctx = ctx else { return 1 }
            let g = Unmanaged<Guard>.fromOpaque(ctx).takeUnretainedValue()
            if g.stop() { g.stopped = true; return 1 }
            if Date() > g.deadline { g.late = true; return 1 }
            return 0
        }, Unmanaged.passUnretained(guardBox).toOpaque())
        defer { withExtendedLifetime(guardBox) {} }

        var transient = false        // locked or unreadable right now, as opposed to not agy's format
        func rows(_ sql: String, _ each: (Data) -> Void) -> Bool {
            var st: OpaquePointer?
            let prc = sqlite3_prepare_v2(db, sql, -1, &st, nil)
            guard prc == SQLITE_OK else { transient = [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_IOERR].contains(prc & 0xFF); return false }
            defer { sqlite3_finalize(st) }
            var n = 0
            while true {
                let rc = sqlite3_step(st)
                if rc == SQLITE_DONE { return true }
                guard rc == SQLITE_ROW else { transient = [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_IOERR].contains(rc & 0xFF); return false }
                n += 1
                guard n <= 200_000 else { return false }
                let len = Int(sqlite3_column_bytes(st, 0))
                if len <= 1 << 20, let p = sqlite3_column_blob(st, 0) { each(Data(bytes: p, count: len)) }
            }
        }
        var tables = 0
        let schema = rows("SELECT CAST(name AS BLOB) FROM sqlite_master WHERE type = 'table' AND name IN ('steps', 'gen_metadata')") { _ in tables += 1 }
        if guardBox.stopped { return .stopped }
        guard schema else { return .busy }        // could not even read its schema: keep what it had, again next time
        guard tables == 2 else { s.buckets = [:]; return .read }        // not agy's format: nothing to count

        var names: [UInt64: String] = [:]
        let gen = rows("SELECT data FROM gen_metadata") { d in
            guard let g = PB.message(PB.fields(d), 1), let u = PB.message(g, 4), let n = PB.int(u, 1),
                  let name = logModel(PB.bytes(g, 19).flatMap { String(data: $0, encoding: .utf8) }) else { return }
            names[n] = name
        }
        var b: DayBuckets = [:]
        let steps = gen && rows("SELECT metadata FROM steps WHERE metadata IS NOT NULL") { d in
            let f = PB.fields(d)
            guard let u = PB.message(f, 9), let t = PB.message(f, 1), let sec = PB.int(t, 1), sec < 1 << 40 else { return }
            let tokens = logCount(PB.int(u, 2)) + logCount(PB.int(u, 3)) + logCount(PB.int(u, 5))
            let model = PB.int(u, 1).flatMap { names[$0] } ?? "gemini"
            UsageScanner.add(&b, UsageDays.key(Date(timeIntervalSince1970: Double(sec))), model, tokens, 1)
        }
        if guardBox.stopped { return .stopped }
        if steps { s.buckets = b; return .read }
        if guardBox.late { return .read }         // out of time: keep what it had until it changes
        if transient { return .busy }             // locked right now: again next time
        s.buckets = [:]                           // not agy's format after all (columns, size): nothing to count
        return .read
    }
}

/// Just enough protobuf to read numbers by field number. Malformed input yields fewer fields, never a crash.
enum PB {
    enum Value { case int(UInt64), bytes(Data) }

    static func fields(_ d: Data) -> [(Int, Value)] {
        var out: [(Int, Value)] = []
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            func varint() -> UInt64? {
                var r: UInt64 = 0, shift: UInt64 = 0
                while i < raw.count, shift < 64 {
                    let c = raw[i]; i += 1
                    r |= UInt64(c & 0x7F) << shift
                    if c < 0x80 { return r }
                    shift += 7
                }
                return nil
            }
            while i < raw.count {
                guard let key = varint() else { return }
                let field = Int(key >> 3)
                switch key & 7 {
                case 0: guard let v = varint() else { return }; out.append((field, .int(v)))
                case 1: guard i + 8 <= raw.count else { return }; i += 8
                case 2:
                    guard let n = varint(), n <= UInt64(raw.count - i) else { return }
                    out.append((field, .bytes(Data(UnsafeRawBufferPointer(rebasing: raw[i..<(i + Int(n))])))))
                    i += Int(n)
                case 5: guard i + 4 <= raw.count else { return }; i += 4
                default: return
                }
            }
        }
        return out
    }

    static func int(_ f: [(Int, Value)], _ n: Int) -> UInt64? {
        for (k, v) in f where k == n { if case .int(let x) = v { return x } }
        return nil
    }

    static func bytes(_ f: [(Int, Value)], _ n: Int) -> Data? {
        for (k, v) in f where k == n { if case .bytes(let x) = v { return x } }
        return nil
    }

    static func message(_ f: [(Int, Value)], _ n: Int) -> [(Int, Value)]? { bytes(f, n).map(fields) }
}

// MARK: - Store

/// Reads usage only for someone looking: when the panel opens on Usage or switches to it, then every
/// 30 s while it stays open (each read at most once a minute unless forced). Closing the panel or
/// leaving Usage stops a read in progress; it goes on from there next time.
final class UsageStore: ObservableObject {
    @Published private(set) var summary: UsageSummary?
    @Published private(set) var reading = false

    // userInitiated: a read only ever starts because someone is looking at the Usage view
    private let queue = DispatchQueue(label: "limitbar.usage", qos: .userInitiated)
    private lazy var scanner = UsageScanner(home: CLI.home, cacheFile: "\(Paths.cache)/usage.json")
    private var lastRead = Date.distantPast
    private let stopLock = NSLock()
    private var stopFlag = false

    private var stopped: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return stopFlag }
        set { stopLock.lock(); stopFlag = newValue; stopLock.unlock() }
    }

    private var again = false

    func refresh(force: Bool = false) {
        let newDay = summary.map { $0.days.last?.key != UsageDays.key(Date()) } ?? false
        // A read still winding down (the panel was closed and opened again quickly): run once it ends.
        if reading { if stopped { again = true; stopped = false }; return }
        guard force || newDay || Date().timeIntervalSince(lastRead) > 60 else { return }
        reading = true
        stopped = false
        queue.async { [weak self] in
            guard let self = self else { return }
            let s = self.scanner.scan(stop: { self.stopped })
            DispatchQueue.main.async {
                if let s = s { self.summary = s; self.lastRead = Date() }
                self.reading = false
                if self.again { self.again = false; self.refresh() }
            }
        }
    }

    /// The panel closed or left Usage: stop reading.
    func pause() { stopped = true; again = false }
}
