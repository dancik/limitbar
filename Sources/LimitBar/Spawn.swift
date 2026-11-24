import Darwin
import Foundation

/// Child processes for the vendor CLIs. Each runs in its own session (POSIX_SPAWN_SETSID), so a timeout
/// kills the whole process group — node, helpers and all — not just the first pid.
final class Child {
    let pid: pid_t
    private let inFD: Int32
    private let outFD: Int32
    private var buffer = Data()
    private var inputClosed = false
    private var reaped = false

    private static let SETSID: Int16 = 0x0400            // POSIX_SPAWN_SETSID
    private static let CLOEXEC_DEFAULT: Int16 = 0x4000   // POSIX_SPAWN_CLOEXEC_DEFAULT
    /// A CLI that prints more than this is not answering a quota question; stop reading.
    static let maxOutput = 4 << 20

    init?(_ argv: [String], env: [String: String], cwd: String = CLI.workDir) {
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { return nil }
        guard pipe(&outPipe) == 0 else { close(inPipe[0]); close(inPipe[1]); return nil }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Child.SETSID | Child.CLOEXEC_DEFAULT)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }

        var p: pid_t = 0
        let envList = env.map { "\($0.key)=\($0.value)" }
        let rc = withCStrings(argv) { cargv in
            withCStrings(envList) { cenv in posix_spawn(&p, argv[0], &fa, &attr, cargv, cenv) }
        }
        close(inPipe[0]); close(outPipe[1])
        guard rc == 0 else { close(inPipe[1]); close(outPipe[0]); return nil }
        pid = p; inFD = inPipe[1]; outFD = outPipe[0]
        _ = fcntl(outFD, F_SETFL, fcntl(outFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
    }

    func write(_ s: String) {
        guard !inputClosed else { return }
        let d = Array(s.utf8)
        d.withUnsafeBytes { _ = Darwin.write(inFD, $0.baseAddress, d.count) }
    }

    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        close(inFD)
    }

    /// Next newline-terminated line, or nil at EOF / deadline.
    func readLine(until deadline: Date) -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(decoding: line, as: UTF8.self)
            }
            guard fill(until: deadline) else {
                if buffer.isEmpty { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
        }
    }

    /// Everything until EOF (or deadline). `timedOut` tells which.
    func readAll(until deadline: Date) -> (Data, timedOut: Bool) {
        while fill(until: deadline) {}
        return (buffer, Date() >= deadline)
    }

    private func fill(until deadline: Date) -> Bool {
        guard buffer.count < Child.maxOutput else { return false }
        let ms = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
        if ms == 0 { return false }
        var pfd = pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, ms) > 0 else { return false }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(outFD, &chunk, chunk.count)
        if n <= 0 { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    /// TERM the whole group, then KILL, then reap — no orphans, no zombies.
    func terminate() {
        guard !reaped else { return }
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<20 {
            if waitpid(pid, &status, WNOHANG) == pid { kill(-pid, SIGKILL); cleanup(); return }
            usleep(50_000)
        }
        kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
        cleanup()
    }

    /// Wait for a normal exit after output ended; kill if it lingers. Returns the exit code, -1 if killed.
    func finish(within seconds: TimeInterval = 2) -> Int32 {
        var status: Int32 = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if waitpid(pid, &status, WNOHANG) == pid {
                kill(-pid, SIGKILL)              // helpers the CLI left behind in its group
                cleanup()
                return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
            }
            usleep(50_000)
        }
        terminate()
        return -1
    }

    private func cleanup() {
        guard !reaped else { return }
        reaped = true
        close(outFD)
        closeInput()
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { ptrs.forEach { free($0) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}

enum CLI {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Where the vendor CLIs install themselves. Fixed: PATH is never taken from the environment, so a
    /// directory added by some other tool is never searched.
    static let searchPath = ["\(home)/.local/bin", "\(home)/.grok/bin", "/opt/homebrew/bin", "/usr/local/bin",
                             "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
    static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// A private, empty working directory: no CLI ever runs inside a project and picks up its config.
    static let workDir: String = {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("limitbar-cwd")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }()

    enum Found { case ok(String), missing, untrusted(String) }

    /// The executable for `name`: an explicit path from `defaults write io.github.dancik.limitbar <name>Path
    /// /abs/path` first, then the fixed search path. Only files that pass `trusted` are ever run.
    static func find(_ name: String) -> Found {
        if let p = UserDefaults.standard.string(forKey: "\(name)Path"), p.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: p) else { return .missing }
            return trusted(p) ? .ok(p) : .untrusted(p)
        }
        for dir in searchPath {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return trusted(p) ? .ok(p) : .untrusted(p) }
        }
        return .missing
    }

    /// An executable given for one account (extra-accounts.json, or found in T3 Code's tools folder): the
    /// same `trusted` check as for every other binary.
    static func check(_ p: String) -> Found {
        guard FileManager.default.isExecutableFile(atPath: p) else { return .missing }
        return trusted(p) ? .ok(p) : .untrusted(p)
    }

    /// Whether another local account could replace what we are about to run. The path, its resolved target
    /// and every directory above both, up to `/`, must be owned by this user or root, not writable by
    /// "others", writable by group only for `admin` (who can sudo anyway), and carry no ACL entry that
    /// grants anyone write access. A file that fails is never run.
    static func trusted(_ path: String) -> Bool {
        guard let rp = realpath(path, nil) else { return false }
        let target = String(cString: rp); free(rp)
        guard FileManager.default.isExecutableFile(atPath: target), safeNode(path, isLink: true) else { return false }
        return safeChain(target) && safeChain((path as NSString).deletingLastPathComponent)
    }

    /// `p` and all its ancestors pass `safeNode`.
    static func safeChain(_ p: String) -> Bool {
        var cur = p
        while true {
            guard safeNode(cur, isLink: false) else { return false }
            if cur == "/" || cur.isEmpty { return true }
            cur = (cur as NSString).deletingLastPathComponent
        }
    }

    private static let adminGroup: gid_t = 80

    static func safeNode(_ p: String, isLink: Bool) -> Bool {
        var st = stat()
        guard lstat(p, &st) == 0 else { return false }
        guard st.st_uid == getuid() || st.st_uid == 0 else { return false }
        if isLink && (st.st_mode & S_IFMT) == S_IFLNK { return true }     // a symlink's own mode means nothing
        if (st.st_mode & S_IWOTH) != 0 { return false }
        if (st.st_mode & S_IWGRP) != 0 && st.st_gid != adminGroup && st.st_gid != 0 { return false }
        return !aclGrantsWrite(p)
    }

    /// Any ALLOW entry in the extended ACL that lets someone write, delete or change ownership/permissions.
    static func aclGrantsWrite(_ p: String) -> Bool {
        guard let acl = acl_get_link_np(p, ACL_TYPE_EXTENDED) else { return false }    // no ACL
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writes: [acl_perm_t] = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                                    ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let e = entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(e, &tag) == 0, tag == ACL_EXTENDED_ALLOW else { continue }
            var perms: acl_permset_t?
            guard acl_get_permset(e, &perms) == 0, let ps = perms else { return true }
            if writes.contains(where: { acl_get_perm_np(ps, $0) == 1 }) { return true }
        }
        return false
    }

    /// The environment a CLI gets is an allowlist, not ours minus a denylist: API keys, GitHub tokens, SSH
    /// agent sockets and anything else we were started with stay out. The CLI's own directories go first
    /// on PATH so a Node-based CLI finds the `node` it was installed with.
    static func env(for binary: String) -> [String: String] {
        let mine = ProcessInfo.processInfo.environment
        var e: [String: String] = [:]
        for k in ["USER", "LOGNAME", "TMPDIR"] { if let v = mine[k] { e[k] = v } }
        let real = ((binary as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent
        let link = (binary as NSString).deletingLastPathComponent
        // Only directories nobody else can write to: a Node-based CLI's `#!/usr/bin/env node` resolves
        // through this PATH, so an unchecked directory here would undo the check on the CLI itself.
        var path: [String] = []
        for d in [link, real] + searchPath + systemPath where !path.contains(d) && safeChain(d) { path.append(d) }
        e["PATH"] = path.joined(separator: ":")
        e["HOME"] = home
        e["LANG"] = "en_US.UTF-8"
        e["NO_COLOR"] = "1"
        return e
    }

    /// How to start `binary`: itself if it is a native executable; for a script (`#!/usr/bin/env node`,
    /// `#!/bin/sh`) its interpreter first — resolved here, checked with `trusted`, and passed explicitly, so
    /// nothing is looked up through PATH. nil = the interpreter is missing or untrusted: do not run.
    static func launch(_ binary: String) -> [String]? {
        guard let h = FileHandle(forReadingAtPath: binary) else { return nil }
        let head = h.readData(ofLength: 512); try? h.close()
        guard head.starts(with: Array("#!".utf8)) else { return [binary] }
        guard let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first else { return nil }
        var parts = line.dropFirst(2).split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts[0] == "/usr/bin/env" {
            parts.removeFirst()
            while let f = parts.first, f.hasPrefix("-") { parts.removeFirst() }   // `env -S` and the like
            guard let name = parts.first, case .ok(let found) = find(name), let rp = realpath(found, nil) else { return nil }
            parts[0] = String(cString: rp); free(rp)
        }
        guard parts[0].hasPrefix("/"), trusted(parts[0]) else { return nil }
        return parts + [binary]
    }

    struct Output { let data: Data; let code: Int32 }

    /// Run `binary` with `args` to completion under a hard deadline. nil if it could not start or timed out.
    static func run(_ binary: String, _ args: [String], timeout: TimeInterval = 20,
                    extraEnv: [String: String] = [:], envFor: String? = nil) -> Output? {
        let start = binary == "/usr/bin/sandbox-exec" ? [binary] : launch(binary)
        guard let argv0 = start,
              let c = Child(argv0 + args, env: env(for: envFor ?? binary).merging(extraEnv) { $1 }) else { return nil }
        c.closeInput()
        let (data, timedOut) = c.readAll(until: Date().addingTimeInterval(timeout))
        if timedOut { c.terminate(); return nil }
        return Output(data: data, code: c.finish())
    }

    enum RPCResult { case ok([String: Any]), failed(String) }

    /// One JSON-RPC exchange over stdio: initialize, optional notification, one call; then kill.
    /// `argv` may wrap `binary` (e.g. in sandbox-exec); the environment is built for `binary`.
    /// `then` is an optional second call made after the first one answered; its result is ignored when it
    /// fails and delivered through `second` when it works (used for the account fingerprint).
    static func rpc(_ argv: [String], binary: String, initialize: [String: Any], notify: String? = nil,
                    method: String, params: [String: Any] = [:], timeout: TimeInterval = 20,
                    extraEnv: [String: String] = [:], then: (String, [String: Any])? = nil,
                    second: (([String: Any]) -> Void)? = nil) -> RPCResult {
        guard let c = Child(argv, env: env(for: binary).merging(extraEnv) { $1 }) else { return .failed("could not start") }
        defer { c.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        func send(_ o: [String: Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
            c.write(String(decoding: d, as: UTF8.self) + "\n")
        }
        func reply(_ id: Int) -> [String: Any]? {
            while let line = c.readLine(until: deadline) {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if (o["id"] as? Int) == id { return o }
            }
            return nil
        }
        func failure(_ o: [String: Any]?) -> String {
            guard let o = o else { return Date() >= deadline ? "timed out" : "no answer" }
            return ((o["error"] as? [String: Any])?["message"] as? String) ?? "unexpected answer"
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": initialize])
        let i = reply(1)
        guard i?["result"] != nil else { return .failed(failure(i)) }
        if let n = notify { send(["jsonrpc": "2.0", "method": n, "params": [String: Any]()]) }
        send(["jsonrpc": "2.0", "id": 2, "method": method, "params": params])
        let r = reply(2)
        guard let result = r?["result"] as? [String: Any] else { return .failed(failure(r)) }
        if let (m, p) = then {
            send(["jsonrpc": "2.0", "id": 3, "method": m, "params": p])
            if let r3 = reply(3)?["result"] as? [String: Any] { second?(r3) }
        }
        return .ok(result)
    }
}
