import SwiftUI
import AppKit

// MARK: - Model

/// 一条 TCP LISTEN 绑定：端口 + 协议族 + 绑定地址。
struct Listener: Hashable {
    let port: String
    let ip: String      // "v4" / "v6"
    let addr: String    // "*" / "0.0.0.0" / "127.0.0.1" / "[::1]" ...
    var label: String { "\(ip == "v6" ? "TCPv6" : "TCPv4") \(addr):\(port)" }
}

/// 折叠进根行的子进程。
struct Member: Hashable, Identifiable {
    let pid: Int
    let command: String
    var id: Int { pid }
}

struct ProcInfo: Identifiable, Hashable {
    var id: Int { pid }
    let pid: Int
    let ppid: Int
    let cpu: Double
    let mem: Double
    let family: String      // node / python / java / go / other ...
    let exeBase: String     // e.g. python3.13
    let command: String
    let elapsed: String     // ps etime 原始值
    var cwd: String?
    var listeners: [Listener]
    var members: [Member]   // 被折叠的子进程（不含自身）
    var project: String
    var isGhost: Bool = false   // 已退出、仅留影展示
    var diedAt: Date? = nil

    /// 去重后的端口列表（保持监听顺序）。
    var uniquePorts: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for l in listeners where seen.insert(l.port).inserted { out.append(l.port) }
        return out
    }

    /// 端口徽章文案：只在「非常规绑定」时追加提示（v6-only / 仅回环）。
    var portBadges: [String] {
        uniquePorts.map { port in
            let ls = listeners.filter { $0.port == port }
            let ips = Set(ls.map { $0.ip })
            let addrs = Set(ls.map { $0.addr })
            if ips == ["v6"] { return ":\(port) v6" }
            if addrs.isSubset(of: loopbackAddrs) { return ":\(port) lo" }
            return ":\(port)"
        }
    }
}

let loopbackAddrs: Set<String> = ["127.0.0.1", "[::1]", "::1", "localhost"]

// MARK: - Shell helpers

func shell(_ launchPath: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Classification

let familyPrefixes: [(String, String)] = [
    ("node", "node"), ("npm", "node"), ("npx", "node"), ("pnpm", "node"),
    ("yarn", "node"), ("vite", "node"), ("nodemon", "node"), ("ts-node", "node"),
    ("tsx", "node"), ("pm2", "node"), ("bun", "node"), ("deno", "node"),
    ("python", "python"), ("uvicorn", "python"), ("gunicorn", "python"),
    ("flask", "python"), ("uv", "python"), ("pip", "python"),
    ("java", "java"), ("kotlin", "java"), ("gradle", "java"), ("mvn", "java"),
    ("go", "go"), ("ruby", "ruby"), ("rails", "ruby"), ("php", "php"),
    ("dotnet", "dotnet"), ("cargo", "rust"), ("rustc", "rust"),
]

let excludeSubstrings = [
    "/Applications/", "/System/", "/Library/Apple", "/usr/libexec", "/usr/sbin/",
    "com.apple.", "Qoder", ".qoder", "WeChat", "微信", "Steam", "Battle.net",
    "Adobe", "/Library/Application Support", "/private/var/", "KernelEventAgent",
    "WindowServer", "/Library/PrivilegedHelperTools",
]

// 命令行第一个字段（可执行文件路径）的文件名部分。
func exeBaseName(_ command: String) -> String {
    let argv0 = command.split(separator: " ").first.map(String.init) ?? ""
    return (argv0 as NSString).lastPathComponent
}

func classify(_ command: String) -> (family: String, base: String)? {
    let base = exeBaseName(command)
    let lower = base.lowercased()
    for (prefix, fam) in familyPrefixes where lower.hasPrefix(prefix) {
        return (fam, base)
    }
    return nil
}

func isExcluded(_ command: String) -> Bool {
    for s in excludeSubstrings where command.contains(s) { return true }
    return false
}

// 兜底规则用到的 family 名：不属于任何已知开发工具链、但确实在监听 TCP 端口的进程。
let otherFamily = "other"

// MARK: - Elapsed formatting

/// ps etime 格式：SS | MM:SS | HH:MM:SS | D-HH:MM:SS
func formatElapsed(_ e: String) -> String {
    var days = 0
    var rest = e
    if let d = rest.firstIndex(of: "-") {
        days = Int(rest[..<d]) ?? 0
        rest = String(rest[rest.index(after: d)...])
    }
    let parts = rest.split(separator: ":").compactMap { Int($0) }
    var h = 0, m = 0, s = 0
    switch parts.count {
    case 1: s = parts[0]
    case 2: m = parts[0]; s = parts[1]
    case 3: h = parts[0]; m = parts[1]; s = parts[2]
    default: return e
    }
    h += days * 24
    if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
    if m > 0 { return "\(m)m\(String(format: "%02d", s))s" }
    return "\(s)s"
}

// MARK: - Project grouping

func displayPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
    return path
}

func projectRoot(from cwd: String?) -> String {
    guard let cwd = cwd, !cwd.isEmpty else { return "未知目录" }
    let fm = FileManager.default
    let markers = [".git", "package.json", "pyproject.toml", "pom.xml", "go.mod",
                   "Cargo.toml", "build.gradle", "requirements.txt", "composer.json",
                   "uv.lock", "Pipfile"]
    var url = URL(fileURLWithPath: cwd)
    let home = NSHomeDirectory()
    var depth = 0
    while depth < 8 {
        for m in markers where fm.fileExists(atPath: url.appendingPathComponent(m).path) {
            return displayPath(url.path)
        }
        let parent = url.deletingLastPathComponent()
        if parent == url { break }
        url = parent
        depth += 1
        if url.path == "/" || url.path == home { break }
    }
    return displayPath(cwd)
}

// MARK: - lsof parsing

// lsof 的 -F 机器可读输出会把非 ASCII 字节转义成 \xHH（中文路径因此变成乱码串），
// 这里还原成真正的 UTF-8 文本。
private func hexVal(_ b: UInt8) -> Int? {
    switch b {
    case 0x30...0x39: return Int(b - 0x30)
    case 0x61...0x66: return Int(b - 0x61 + 10)
    case 0x41...0x46: return Int(b - 0x41 + 10)
    default: return nil
    }
}

func unescapeLsof(_ s: String) -> String {
    let raw = Array(s.utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(raw.count)
    var i = 0
    while i < raw.count {
        if raw[i] == 0x5C, i + 1 < raw.count {
            switch raw[i + 1] {
            case 0x5C: bytes.append(0x5C); i += 2; continue          // \\
            case 0x6E: bytes.append(0x0A); i += 2; continue          // \n
            case 0x72: bytes.append(0x0D); i += 2; continue          // \r
            case 0x74: bytes.append(0x09); i += 2; continue          // \t
            case 0x78:                                                // \xHH
                if i + 3 < raw.count,
                   let hi = hexVal(raw[i + 2]), let lo = hexVal(raw[i + 3]) {
                    bytes.append(UInt8(hi << 4 | lo)); i += 4; continue
                }
            default: break
            }
        }
        bytes.append(raw[i]); i += 1
    }
    return String(decoding: bytes, as: UTF8.self)
}

// Walks lsof -F output, tracking current pid, collecting `n` (name) values per pid.
func parseLsofNames(_ text: String) -> [Int: [String]] {
    var result: [Int: [String]] = [:]
    var currentPid: Int?
    for raw in text.split(separator: "\n") {
        let line = String(raw)
        guard let first = line.first else { continue }
        let rest = String(line.dropFirst())
        if first == "p" {
            currentPid = Int(rest)
        } else if first == "n", let pid = currentPid {
            result[pid, default: []].append(unescapeLsof(rest))
        }
    }
    return result
}

struct FdInfo {
    let type: String    // IPv4 / IPv6
    let name: String    // e.g. *:3000 / 127.0.0.1:6379 / [::1]:8080
}

// lsof -Ftn 输出里每个 fd 依次是 f / t / n 三行，按 fd 归组 type+name。
func parseLsofFds(_ text: String) -> [Int: [FdInfo]] {
    var result: [Int: [FdInfo]] = [:]
    var currentPid: Int?
    var currentType = ""
    for raw in text.split(separator: "\n") {
        let line = String(raw)
        guard let first = line.first else { continue }
        let rest = String(line.dropFirst())
        switch first {
        case "p":
            currentPid = Int(rest); currentType = ""
        case "f":
            currentType = ""
        case "t":
            currentType = rest
        case "n":
            if let pid = currentPid {
                result[pid, default: []].append(FdInfo(type: currentType, name: unescapeLsof(rest)))
            }
        default: break
        }
    }
    return result
}

func extractPort(_ addr: String) -> String? {
    guard let idx = addr.lastIndex(of: ":") else { return nil }
    let port = String(addr[addr.index(after: idx)...])
    return port.isEmpty ? nil : port
}

func extractAddr(_ name: String) -> String {
    guard let idx = name.lastIndex(of: ":") else { return name }
    return String(name[..<idx])
}

// MARK: - Gathering

struct RawProc {
    let pid: Int
    let ppid: Int
    let cpu: Double
    let mem: Double
    let uid: Int
    let elapsed: String
    let command: String
}

func gatherProcs() -> [ProcInfo] {
    let myUid = Int(getuid())
    let myPid = Int(ProcessInfo.processInfo.processIdentifier)

    // 第一遍：拉全量进程表，只做「当前用户 + 非噪音」的粗筛，
    // 不再要求命中开发工具白名单——是否有监听端口留到第二遍判断。
    let psOut = shell("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,pmem=,uid=,etime=,command="])
    var rows: [RawProc] = []
    for raw in psOut.split(separator: "\n") {
        let line = String(raw)
        let parts = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard parts.count == 7,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]),
              let cpu = Double(parts[2]),
              let mem = Double(parts[3]),
              let uid = Int(parts[4]) else { continue }
        let elapsed = String(parts[5])
        let command = String(parts[6]).trimmingCharacters(in: .whitespaces)
        if uid != myUid || pid == myPid { continue }
        if isExcluded(command) { continue }
        rows.append(RawProc(pid: pid, ppid: ppid, cpu: cpu, mem: mem, uid: uid,
                            elapsed: elapsed, command: command))
    }

    // 第二遍：一次性取全机 TCP LISTEN 端口表（不限 pid），带协议族与绑定地址，
    // 这样「编译好的独立二进制」这种不匹配任何解释器前缀的监听进程也能被发现。
    let portText = shell("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Ftn"])
    let listenerMap = parseLsofFds(portText).mapValues { fds -> [Listener] in
        var seen = Set<String>()
        var out: [Listener] = []
        for fd in fds {
            guard fd.type == "IPv4" || fd.type == "IPv6",
                  let port = extractPort(fd.name) else { continue }
            let l = Listener(port: port,
                             ip: fd.type == "IPv6" ? "v6" : "v4",
                             addr: extractAddr(fd.name))
            if seen.insert(l.label).inserted { out.append(l) }
        }
        return out.sorted { (Int($0.port) ?? 0) < (Int($1.port) ?? 0) }
    }

    // 候选 = 命中开发工具白名单的进程 ∪ 正在监听 TCP 端口的进程
    let candidates = rows.filter { classify($0.command) != nil || !(listenerMap[$0.pid] ?? []).isEmpty }
    guard !candidates.isEmpty else { return [] }

    // 进程树折叠：沿 ppid 在候选集内向上爬到根，同根进程合并成一行。
    let byPid = Dictionary(uniqueKeysWithValues: candidates.map { ($0.pid, $0) })
    func rootPid(of pid: Int) -> Int {
        var cur = pid
        while let proc = byPid[cur], let parent = byPid[proc.ppid] { cur = parent.pid }
        return cur
    }
    var groups: [Int: [RawProc]] = [:]
    for c in candidates { groups[rootPid(of: c.pid), default: []].append(c) }

    let pidList = candidates.map { String($0.pid) }.joined(separator: ",")
    let cwdText = shell("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pidList])
    let cwdMap = parseLsofNames(cwdText).mapValues { $0.first ?? "" }

    var procs: [ProcInfo] = []
    for (root, members) in groups {
        guard let rootProc = byPid[root] else { continue }
        let sorted = members.sorted { $0.pid < $1.pid }
        let cls = classify(rootProc.command)
        let cwd = sorted.lazy.compactMap { cwdMap[$0.pid] }.first { !$0.isEmpty }
        var listeners: [Listener] = []
        var seen = Set<String>()
        for m in sorted {
            for l in listenerMap[m.pid] ?? [] where seen.insert(l.label).inserted {
                listeners.append(l)
            }
        }
        listeners.sort { (Int($0.port) ?? 0) < (Int($1.port) ?? 0) }
        procs.append(ProcInfo(
            pid: root, ppid: rootProc.ppid,
            cpu: sorted.reduce(0) { $0 + $1.cpu },
            mem: sorted.reduce(0) { $0 + $1.mem },
            family: cls?.family ?? otherFamily,
            exeBase: cls?.base ?? exeBaseName(rootProc.command),
            command: rootProc.command,
            elapsed: rootProc.elapsed,
            cwd: cwd,
            listeners: listeners,
            members: sorted.filter { $0.pid != root }.map { Member(pid: $0.pid, command: $0.command) },
            project: projectRoot(from: cwd)
        ))
    }
    return procs.sorted { $0.pid < $1.pid }
}

// MARK: - Store

private enum PrefKey {
    static let includeOthers = "pv.includeOthers"
    static let onlyWithPorts = "pv.onlyWithPorts"
    static let autoRefresh = "pv.autoRefresh"
}

final class Store: ObservableObject {
    @Published var procs: [ProcInfo] = []
    @Published var ghosts: [ProcInfo] = []
    @Published var addedPids: Set<Int> = []
    @Published var loading = false
    @Published var lastRefresh: Date? = nil
    @Published var query = ""
    @Published var onlyWithPorts: Bool = UserDefaults.standard.bool(forKey: PrefKey.onlyWithPorts) {
        didSet { UserDefaults.standard.set(onlyWithPorts, forKey: PrefKey.onlyWithPorts) }
    }
    @Published var includeOthers: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: PrefKey.includeOthers) == nil ? true : d.bool(forKey: PrefKey.includeOthers)
    }() {
        didSet { UserDefaults.standard.set(includeOthers, forKey: PrefKey.includeOthers) }
    }
    @Published var autoRefresh: Bool = UserDefaults.standard.bool(forKey: PrefKey.autoRefresh) {
        didSet {
            UserDefaults.standard.set(autoRefresh, forKey: PrefKey.autoRefresh)
            autoRefresh ? startTimer() : stopTimer()
        }
    }
    private var timer: Timer?
    private var knownPids: Set<Int> = []

    init() {
        // 持久化的 autoRefresh 不经过 didSet，启动时需手动起定时器
        if autoRefresh { startTimer() }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let list = gatherProcs()
            await MainActor.run { self.apply(list) }
        }
    }

    private func apply(_ list: [ProcInfo]) {
        let newPids = Set(list.map { $0.pid })
        var newGhosts = ghosts.filter { g in
            guard let d = g.diedAt else { return false }
            return Date().timeIntervalSince(d) < 6
        }
        if !knownPids.isEmpty {
            let added = newPids.subtracting(knownPids)
            if !added.isEmpty {
                addedPids.formUnion(added)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.addedPids.subtract(added)
                }
            }
            let removed = knownPids.subtracting(newPids)
            if !removed.isEmpty {
                for g in procs where removed.contains(g.pid) {
                    var ghost = g
                    ghost.isGhost = true
                    ghost.diedAt = Date()
                    newGhosts.append(ghost)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
                    guard let self else { return }
                    let now = Date()
                    self.ghosts.removeAll { g in (g.diedAt.map { now.timeIntervalSince($0) } ?? 0) > 6 }
                }
            }
        }
        knownPids = newPids
        ghosts = newGhosts
        procs = list
        loading = false
        lastRefresh = Date()
    }

    func kill(_ p: ProcInfo, signal: Int) {
        _ = shell("/bin/kill", ["-\(signal)", "\(p.pid)"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.refresh() }
    }

    /// 在原 cwd 用原命令重新拉起（经 /bin/sh -c，保留 shell 语义）。
    func restart(_ p: ProcInfo) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", p.command]
        if let cwd = p.cwd, FileManager.default.fileExists(atPath: cwd) {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        do { try proc.run() } catch { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.refresh() }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    var filtered: [ProcInfo] {
        var list = procs + ghosts
        if onlyWithPorts { list = list.filter { !$0.listeners.isEmpty } }
        if !includeOthers { list = list.filter { $0.family != otherFamily } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.command.lowercased().contains(q) ||
                String($0.pid).contains(q) ||
                $0.project.lowercased().contains(q) ||
                $0.members.contains(where: { $0.command.lowercased().contains(q) }) ||
                $0.uniquePorts.contains(where: { $0.contains(q) })
            }
        }
        return list
    }

    var grouped: [(project: String, items: [ProcInfo])] {
        let dict = Dictionary(grouping: filtered) { $0.project }
        return dict.map { (project: $0.key, items: $0.value.sorted { $0.pid < $1.pid }) }
            .sorted { $0.project < $1.project }
    }
}

// MARK: - Colors

func familyColor(_ f: String) -> Color {
    switch f {
    case "node": return .green
    case "python": return .blue
    case "java": return .orange
    case "go": return .cyan
    case "ruby": return .red
    case "rust": return .purple
    case "other": return .gray
    default: return .gray
    }
}

// MARK: - Views

struct KillAction: Identifiable {
    let id = UUID()
    let proc: ProcInfo
    let signal: Int
    var label: String { signal == 9 ? "强制结束 (kill -9)" : "正常结束 (kill -15)" }
}

struct ProcRow: View {
    let proc: ProcInfo
    let isAdded: Bool
    let onKill: (Int) -> Void
    let onRestart: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(proc.family)
                    .font(.caption2).bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(familyColor(proc.family))
                    .cornerRadius(5)
                    .frame(width: 58, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(proc.command)
                            .font(.system(.body, design: .monospaced))
                            .strikethrough(proc.isGhost)
                            .lineLimit(1).truncationMode(.middle)
                        if proc.isGhost {
                            Text("已退出")
                                .font(.caption2).bold()
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .cornerRadius(4)
                        }
                        if !proc.members.isEmpty {
                            Text("+\(proc.members.count)")
                                .font(.caption2).bold()
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .foregroundColor(.secondary)
                                .cornerRadius(4)
                                .help(proc.members.map { "\($0.pid)  \($0.command)" }.joined(separator: "\n"))
                        }
                        Spacer()
                        if !proc.portBadges.isEmpty {
                            ForEach(proc.portBadges, id: \.self) { b in
                                Text(b)
                                    .font(.caption2).bold()
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(4)
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        Text("PID \(proc.pid)").font(.caption).foregroundColor(.secondary)
                        Text(String(format: "CPU %.1f%%", proc.cpu)).font(.caption).foregroundColor(.secondary)
                        Text(String(format: "MEM %.1f%%", proc.mem)).font(.caption).foregroundColor(.secondary)
                        Text("运行 \(formatElapsed(proc.elapsed))").font(.caption).foregroundColor(.secondary)
                        if let cwd = proc.cwd {
                            Text(displayPath(cwd)).font(.caption).foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }

                if !proc.isGhost {
                    Menu {
                        Button("正常结束 (TERM)") { onKill(15) }
                        Button("强制结束 (KILL -9)", role: .destructive) { onKill(9) }
                        Button("重新启动") { onRestart() }
                        Divider()
                        ForEach(proc.uniquePorts, id: \.self) { pt in
                            Button("在浏览器打开 :\(pt)") {
                                if let url = URL(string: "http://127.0.0.1:\(pt)") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Divider()
                        Button("复制命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(proc.command, forType: .string)
                        }
                        if let cwd = proc.cwd {
                            Button("在访达中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                }
            }
            .padding(.vertical, 4)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    detailLine("命令", proc.command)
                    if let cwd = proc.cwd { detailLine("cwd", cwd) }
                    if !proc.listeners.isEmpty {
                        ForEach(proc.listeners, id: \.self) { l in
                            detailLine("监听", l.label)
                        }
                    }
                    ForEach(proc.members) { m in
                        detailLine("子进程", "\(m.pid)  \(m.command)")
                    }
                    Text("点击行收起")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.leading, 68)
                .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 2)
        .background(rowBackground)
        .cornerRadius(6)
        .contextMenu {
            if !proc.isGhost {
                Button("正常结束 (TERM)") { onKill(15) }
                Button("强制结束 (KILL -9)", role: .destructive) { onKill(9) }
                Button("重新启动") { onRestart() }
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if proc.isGhost {
            Color.red.opacity(0.08)
        } else if isAdded {
            Color.green.opacity(0.15)
        } else {
            Color.clear
        }
    }

    private func detailLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption2).foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ContentView: View {
    @StateObject private var store = Store()
    @State private var pendingKill: KillAction?

    var body: some View {
        VStack(spacing: 0) {
            List {
                if store.grouped.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "tray").font(.system(size: 34)).foregroundColor(.secondary)
                            Text(store.loading ? "正在扫描…" : "没有发现开发进程或监听端口")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 60)
                } else {
                    ForEach(store.grouped, id: \.project) { group in
                        Section {
                            ForEach(group.items) { proc in
                                ProcRow(proc: proc,
                                        isAdded: store.addedPids.contains(proc.pid),
                                        onKill: { sig in pendingKill = KillAction(proc: proc, signal: sig) },
                                        onRestart: { store.restart(proc) })
                            }
                        } header: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.accentColor)
                                Text(group.project).font(.headline)
                                Text("(\(group.items.count))").foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 14) {
                Text("共 \(store.filtered.count) 个进程 · \(store.grouped.count) 个项目")
                    .font(.caption).foregroundColor(.secondary)
                if let d = store.lastRefresh {
                    Text("更新于 \(timeString(d))").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("含其他监听进程", isOn: $store.includeOthers).toggleStyle(.switch).font(.caption)
                Toggle("仅显示监听端口", isOn: $store.onlyWithPorts).toggleStyle(.switch).font(.caption)
                Toggle("自动刷新 5s", isOn: $store.autoRefresh).toggleStyle(.switch).font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.loading)
            }
            ToolbarItem(placement: .principal) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("搜索命令 / PID / 端口 / 项目", text: $store.query)
                        .textFieldStyle(.plain)
                        .frame(width: 280)
                }
            }
        }
        .confirmationDialog(
            "确认结束进程？",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible
        ) {
            if let pk = pendingKill {
                Button(pk.label, role: .destructive) {
                    store.kill(pk.proc, signal: pk.signal)
                    pendingKill = nil
                }
                Button("取消", role: .cancel) { pendingKill = nil }
            }
        } message: {
            if let pk = pendingKill {
                Text("PID \(pk.proc.pid)\n\(pk.proc.command)")
            }
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ProcessViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup("进程查看器") {
            ContentView()
        }
    }
}
