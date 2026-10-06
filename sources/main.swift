import SwiftUI
import AppKit

// MARK: - Model

struct ProcInfo: Identifiable, Hashable {
    var id: Int { pid }
    let pid: Int
    let ppid: Int
    let cpu: Double
    let mem: Double
    let family: String      // node / python / java / go ...
    let exeBase: String     // e.g. python3.13
    let command: String
    var cwd: String?
    var ports: [String]
    var project: String
}

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

func classify(_ command: String) -> (family: String, base: String)? {
    let argv0 = command.split(separator: " ").first.map(String.init) ?? ""
    let base = (argv0 as NSString).lastPathComponent
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
            result[pid, default: []].append(rest)
        }
    }
    return result
}

func extractPort(_ addr: String) -> String? {
    guard let idx = addr.lastIndex(of: ":") else { return nil }
    let port = String(addr[addr.index(after: idx)...])
    return port.isEmpty ? nil : port
}

// MARK: - Gathering

struct RawProc {
    let pid: Int
    let ppid: Int
    let cpu: Double
    let mem: Double
    let command: String
}

func gatherProcs() -> [ProcInfo] {
    let psOut = shell("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,pmem=,command="])
    var candidates: [RawProc] = []
    for raw in psOut.split(separator: "\n") {
        let line = String(raw)
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count == 5,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]),
              let cpu = Double(parts[2]),
              let mem = Double(parts[3]) else { continue }
        let command = String(parts[4])
        if isExcluded(command) { continue }
        if classify(command) == nil { continue }
        candidates.append(RawProc(pid: pid, ppid: ppid, cpu: cpu, mem: mem, command: command))
    }
    guard !candidates.isEmpty else { return [] }

    let pidList = candidates.map { String($0.pid) }.joined(separator: ",")
    let cwdText = shell("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pidList])
    let portText = shell("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pidList, "-Fn"])

    let cwdMap = parseLsofNames(cwdText).mapValues { $0.first ?? "" }
    let portMap = parseLsofNames(portText).mapValues { names in
        var seen = Set<String>()
        var ordered: [String] = []
        for n in names {
            if let port = extractPort(n), !seen.contains(port) {
                seen.insert(port); ordered.append(port)
            }
        }
        return ordered.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    var procs: [ProcInfo] = []
    for c in candidates {
        guard let cls = classify(c.command) else { continue }
        let cwd = cwdMap[c.pid]
        procs.append(ProcInfo(
            pid: c.pid, ppid: c.ppid, cpu: c.cpu, mem: c.mem,
            family: cls.family, exeBase: cls.base, command: c.command,
            cwd: (cwd?.isEmpty == false) ? cwd : nil,
            ports: portMap[c.pid] ?? [],
            project: projectRoot(from: (cwd?.isEmpty == false) ? cwd : nil)
        ))
    }
    return procs
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var procs: [ProcInfo] = []
    @Published var loading = false
    @Published var lastRefresh: Date? = nil
    @Published var query = ""
    @Published var onlyWithPorts = false
    @Published var autoRefresh = false {
        didSet { autoRefresh ? startTimer() : stopTimer() }
    }
    private var timer: Timer?

    init() { refresh() }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let list = gatherProcs()
            await MainActor.run {
                self.procs = list
                self.loading = false
                self.lastRefresh = Date()
            }
        }
    }

    func kill(_ p: ProcInfo, signal: Int) {
        _ = shell("/bin/kill", ["-\(signal)", "\(p.pid)"])
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
        var list = procs
        if onlyWithPorts { list = list.filter { !$0.ports.isEmpty } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.command.lowercased().contains(q) ||
                String($0.pid).contains(q) ||
                $0.project.lowercased().contains(q) ||
                $0.ports.contains(where: { $0.contains(q) })
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
    let onKill: (Int) -> Void

    var body: some View {
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
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if !proc.ports.isEmpty {
                        ForEach(proc.ports, id: \.self) { pt in
                            Text(":\(pt)")
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
                    if let cwd = proc.cwd {
                        Text(displayPath(cwd)).font(.caption).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
            }

            Menu {
                Button("正常结束 (TERM)") { onKill(15) }
                Button("强制结束 (KILL -9)", role: .destructive) { onKill(9) }
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
        .padding(.vertical, 4)
        .contextMenu {
            Button("正常结束 (TERM)") { onKill(15) }
            Button("强制结束 (KILL -9)", role: .destructive) { onKill(9) }
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
                            Text(store.loading ? "正在扫描…" : "没有匹配的开发进程")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 60)
                } else {
                    ForEach(store.grouped, id: \.project) { group in
                        Section {
                            ForEach(group.items) { proc in
                                ProcRow(proc: proc) { sig in
                                    pendingKill = KillAction(proc: proc, signal: sig)
                                }
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
