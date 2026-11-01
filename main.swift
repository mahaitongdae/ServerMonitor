import Cocoa
import ServiceManagement

// ===== 配置 =====
// 读取顺序：~/.config/servermonitor/hosts.conf，其次 app 包内的 hosts.conf（build.sh 从仓库根目录拷入）
// 格式：每行一个 ssh host（可用 ~/.ssh/config 里的别名），# 为注释，`interval = 秒` 设置刷新间隔
let CONFIG_PATHS = [NSHomeDirectory() + "/.config/servermonitor/hosts.conf",
                    Bundle.main.path(forResource: "hosts", ofType: "conf")].compactMap { $0 }

func loadConfig() -> (hosts: [String], interval: TimeInterval, settings: [String: String]) {
    var hosts: [String] = [], interval: TimeInterval = 10, settings: [String: String] = [:]
    guard let text = CONFIG_PATHS.lazy.compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) }).first else { return (hosts, interval, settings) }
    for raw in text.split(separator: "\n") {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { continue }
        let kv = line.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
        if kv.count == 2 {
            if kv[0] == "interval" { interval = max(2, TimeInterval(kv[1]) ?? 10) } else { settings[kv[0]] = kv[1] }
        } else { hosts.append(line) }
    }
    return (hosts, interval, settings)
}
let (HOSTS, INTERVAL, SETTINGS) = loadConfig()

// 在远端执行的命令：一次 ssh 拿到 CPU / 内存 / 磁盘 / GPU / GPU 进程归属
let REMOTE = """
echo @CPU; vmstat 1 2 | tail -1 | awk '{print 100-$15}'
echo @MEM; free -m | awk 'NR==2{print $2, $3}'
echo @DISK; df -BG / | tail -1 | awk '{print $2, $3, $4, $5}'
echo @GPU; nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,uuid --format=csv,noheader,nounits
echo @APPS; nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader,nounits | while IFS=', ' read -r u p m; do echo "$u $(ps -o user= -p $p 2>/dev/null || echo '?') $m"; done
"""

struct GPU {
    var idx = 0, name = "", util = 0, memUsed = 0, memTotal = 0, temp = 0, uuid = ""
    var users: [String: Int] = [:]   // user -> MiB
}

struct Stat {
    var cpu = 0, memTotal = 0, memUsed = 0
    var diskSize = 0, diskUsed = 0, diskFree = 0, diskPct = 0
    var gpus: [GPU] = []
    var error: String?
    var avgGPU: Int { gpus.isEmpty ? 0 : gpus.map(\.util).reduce(0, +) / gpus.count }
}

func num(_ s: String) -> Int { Int(s.trimmingCharacters(in: .whitespaces).filter { $0.isNumber || $0 == "-" }) ?? 0 }

func parse(_ text: String) -> Stat {
    var s = Stat(), sec = ""
    var apps: [(String, String, Int)] = []
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("@") { sec = line; continue }
        let f = line.split(separator: " ").map(String.init)
        switch sec {
        case "@CPU": s.cpu = num(line)
        case "@MEM": if f.count >= 2 { s.memTotal = num(f[0]); s.memUsed = num(f[1]) }
        case "@DISK": if f.count >= 4 { s.diskSize = num(f[0]); s.diskUsed = num(f[1]); s.diskFree = num(f[2]); s.diskPct = num(f[3]) }
        case "@GPU":
            let c = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if c.count >= 7 {
                let name = c[1].replacingOccurrences(of: "NVIDIA ", with: "").replacingOccurrences(of: "GeForce ", with: "")
                s.gpus.append(GPU(idx: num(c[0]), name: name, util: num(c[2]), memUsed: num(c[3]),
                                  memTotal: num(c[4]), temp: num(c[5]), uuid: c[6]))
            }
        case "@APPS": if f.count >= 3 { apps.append((f[0], f[1], num(f[2]))) }
        default: break
        }
    }
    for (uuid, user, mem) in apps {
        if let i = s.gpus.firstIndex(where: { $0.uuid == uuid }) { s.gpus[i].users[user, default: 0] += mem }
    }
    return s
}

func fetch(_ host: String, done: @escaping (Stat) -> Void) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", host, REMOTE]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
    p.terminationHandler = { pr in
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var s = parse(o)
        if pr.terminationStatus != 0 && s.gpus.isEmpty {
            s.error = e.split(separator: "\n").last.map(String.init) ?? "ssh exit \(pr.terminationStatus)"
        }
        done(s)
    }
    do { try p.run() } catch { var s = Stat(); s.error = error.localizedDescription; done(s); return }
    DispatchQueue.global().asyncAfter(deadline: .now() + 25) { if p.isRunning { p.terminate() } }
}

// ===== iTerm2 hotkey window =====
typealias Hotkey = (profile: String, code: CGKeyCode, flags: UInt64)

/// 从 iTerm2 偏好里找带 hotkey 的 profile（可用 iterm_profile = xxx 指定）
func itermHotkey() -> Hotkey? {
    guard let list = UserDefaults(suiteName: "com.googlecode.iterm2")?.array(forKey: "New Bookmarks") as? [[String: Any]] else { return nil }
    let hk = list.filter { ($0["Has Hotkey"] as? Bool) == true }
    let want = SETTINGS["iterm_profile"]
    guard let b = hk.first(where: { want != nil && $0["Name"] as? String == want }) ?? hk.first,
          let name = b["Name"] as? String, let code = b["HotKey Key Code"] as? Int else { return nil }
    return (name, CGKeyCode(code), UInt64(b["HotKey Modifier Flags"] as? Int ?? 0))
}

func asQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

/// 在 hotkey window 里新开 tab 执行 ssh；返回 "ok" / "hidden"
/// 注意：iTerm2 的 `windows` 列表里不包含 hotkey window，且对它的引用存进变量后会失效，
/// 只能每次都通过 `current window` 访问（隐藏状态下 current window 通常仍是它）。
func itermScript(host: String, profile: String) -> String { """
tell application "iTerm2"
  set isHK to false
  try
    set isHK to is hotkey window of current window
  end try
  if not isHK then
    try
      create hotkey window with profile \(asQuote(profile))
    on error
      return "hidden"
    end try
    delay 0.3
    tell current window
      reveal hotkey window
      tell current session to write text \(asQuote("ssh " + host))
    end tell
    return "ok"
  end if
  tell current window
    create tab with profile \(asQuote(profile))
    reveal hotkey window
    tell current session to write text \(asQuote("ssh " + host))
  end tell
  return "ok"
end tell
"""
}

func runAppleScript(_ src: String) -> (String?, String?) {
    var err: NSDictionary?
    let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let e = err { return (nil, e[NSAppleScript.errorMessage] as? String ?? "\(e)") }
    return (r?.stringValue, nil)
}

// 修饰键 flag -> 对应的物理键（左侧），模拟真实按键：先按修饰键，再按主键
let MODIFIER_KEYS: [(UInt64, CGKeyCode)] = [(1 << 17, 56), (1 << 18, 59), (1 << 19, 58), (1 << 20, 55)] // shift ctrl option cmd

func pressKey(_ code: CGKeyCode, _ flags: UInt64) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let mask = flags & 0xFF0000
    let mods = MODIFIER_KEYS.filter { mask & $0.0 != 0 }
    func post(_ key: CGKeyCode, _ down: Bool, _ f: UInt64) {
        let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
        e?.flags = CGEventFlags(rawValue: f)
        e?.post(tap: .cghidEventTap)
        usleep(15_000)
    }
    for m in mods { post(m.1, true, mask) }
    post(code, true, mask)
    post(code, false, mask)
    for m in mods.reversed() { post(m.1, false, 0) }
}

let LOG = NSHomeDirectory() + "/Library/Logs/ServerMonitor.log"
func log(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: LOG) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: LOG, atomically: true, encoding: .utf8) }
}

func alert(_ text: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert(); a.messageText = "ServerMonitor"; a.informativeText = text; a.runModal()
}

// ===== UI =====
let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

func color(_ pct: Int) -> NSColor { pct >= 85 ? .systemRed : pct >= 50 ? .systemOrange : .systemGreen }
func bar(_ pct: Int, _ w: Int = 10) -> String {
    let n = max(0, min(w, Int((Double(pct) / 100 * Double(w)).rounded())))
    return String(repeating: "█", count: n) + String(repeating: "░", count: w - n)
}
func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
func gib(_ mib: Int) -> String { String(format: "%.1f", Double(mib) / 1024) }

final class Line {
    let a = NSMutableAttributedString()
    @discardableResult func t(_ s: String, _ c: NSColor = .labelColor, bold: Bool = false) -> Line {
        a.append(NSAttributedString(string: s, attributes: [.font: bold ? monoBold : mono, .foregroundColor: c])); return self
    }
}

class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var stats: [String: Stat] = [:]
    var inFlight = Set<String>()
    var menuOpen = false
    var updated: Date?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Servers")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        updateTitle(); rebuild()
        refresh()
        let t = Timer(timeInterval: INTERVAL, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
    }

    @objc func refresh() {
        for h in HOSTS where !inFlight.contains(h) {
            inFlight.insert(h)
            fetch(h) { s in
                DispatchQueue.main.async {
                    self.inFlight.remove(h); self.stats[h] = s; self.updated = Date()
                    self.updateTitle()
                    if self.menuOpen { self.rebuild() }
                }
            }
        }
    }

    // 菜单栏标题：每台机器的平均 GPU 利用率
    func updateTitle() {
        let a = NSMutableAttributedString()
        let f = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for (i, h) in HOSTS.enumerated() {
            if i > 0 { a.append(NSAttributedString(string: " ", attributes: [.font: f])) }
            let txt: String, c: NSColor
            if let s = stats[h] {
                if s.error != nil { txt = "×"; c = .systemRed } else { txt = "\(s.avgGPU)%"; c = s.avgGPU >= 85 ? .systemRed : .labelColor }
            } else { txt = "…"; c = .secondaryLabelColor }
            a.append(NSAttributedString(string: txt, attributes: [.font: f, .foregroundColor: c]))
        }
        item.button?.attributedTitle = a
    }

    func add(_ l: Line, _ menu: NSMenu, ssh host: String? = nil) {
        let mi = NSMenuItem(title: "", action: host == nil ? #selector(noop) : #selector(sshTo(_:)), keyEquivalent: "")
        mi.target = self; mi.attributedTitle = l.a; mi.representedObject = host
        if host != nil { mi.toolTip = "Open ssh \(host!) in iTerm2 hotkey window" }
        menu.addItem(mi)
    }

    @objc func sshTo(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        guard let hk = itermHotkey() else { alert("No iTerm2 profile with a hotkey window found."); return }
        // menu 关闭后再执行，避免和菜单动画冲突
        DispatchQueue.main.async { self.openSSH(host, hk, triedHotkey: false) }
    }

    func openSSH(_ host: String, _ hk: Hotkey, triedHotkey: Bool, attempt: Int = 0) {
        let (r, err) = runAppleScript(itermScript(host: host, profile: hk.profile))
        log("ssh \(host) profile=\(hk.profile) key=\(hk.code) flags=\(hk.flags) triedHotkey=\(triedHotkey) attempt=\(attempt) -> \(r ?? "nil") err=\(err ?? "-")")
        if let err { alert("iTerm2 AppleScript failed:\n\(err)\n\nAllow ServerMonitor to control iTerm2 in System Settings → Privacy & Security → Automation."); return }
        if r == "ok" { return }
        if triedHotkey {
            // 动画期间窗口可能还没进 AppleScript 的 windows 列表，轮询最多 ~3 秒
            if attempt < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.openSSH(host, hk, triedHotkey: true, attempt: attempt + 1) }; return }
            alert("Could not reveal the iTerm2 hotkey window. See ~/Library/Logs/ServerMonitor.log"); return
        }
        // hotkey window 被隐藏：模拟按下它的快捷键让它出来，再开 tab（需要辅助功能权限）
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            alert("The hotkey window is hidden. To reveal it, ServerMonitor needs Accessibility permission (System Settings → Privacy & Security → Accessibility). Enable it, then click again.")
            return
        }
        log("AX trusted, pressing hotkey")
        pressKey(hk.code, hk.flags)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.openSSH(host, hk, triedHotkey: true) }
    }
    @objc func noop() {}

    func rebuild() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()
        if HOSTS.isEmpty {
            add(Line().t("No hosts configured. Create ~/.config/servermonitor/hosts.conf", .systemRed), menu)
            menu.addItem(.separator())
        }
        for h in HOSTS {
            let head = Line().t(h, bold: true)
            let hint = "   ↗ ssh"
            guard let s = stats[h] else { add(head.t("   loading…", .secondaryLabelColor).t(hint, .tertiaryLabelColor), menu, ssh: h); menu.addItem(.separator()); continue }
            if let e = s.error { add(head.t("   ✕ " + e, .systemRed).t(hint, .tertiaryLabelColor), menu, ssh: h); menu.addItem(.separator()); continue }
            add(head.t("   GPU avg \(s.avgGPU)%", color(s.avgGPU)).t(hint, .tertiaryLabelColor), menu, ssh: h)

            let memPct = s.memTotal > 0 ? s.memUsed * 100 / s.memTotal : 0
            add(Line().t("  CPU  ").t(bar(s.cpu), color(s.cpu)).t(lpad("\(s.cpu)%", 5))
                .t("    MEM  ").t(bar(memPct), color(memPct)).t(" \(gib(s.memUsed))/\(gib(s.memTotal))G"), menu)
            add(Line().t("  DISK ").t(bar(s.diskPct), color(s.diskPct)).t(lpad("\(s.diskPct)%", 5))
                .t("    /  \(s.diskUsed)G used, \(s.diskFree)G free", s.diskPct >= 90 ? .systemRed : .labelColor), menu)
            for g in s.gpus {
                let mp = g.memTotal > 0 ? g.memUsed * 100 / g.memTotal : 0
                let users = g.users.sorted { $0.value > $1.value }.map { "\($0.key) \(gib($0.value))G" }.joined(separator: ", ")
                add(Line().t("  GPU\(g.idx) ").t(bar(g.util), color(g.util)).t(lpad("\(g.util)%", 5))
                    .t("    VRAM ").t(bar(mp), color(mp)).t(" " + lpad("\(gib(g.memUsed))/\(gib(g.memTotal))G", 11))
                    .t(lpad("\(g.temp)°C", 6), g.temp >= 80 ? .systemRed : .secondaryLabelColor)
                    .t(users.isEmpty ? "" : "   " + users, .secondaryLabelColor), menu)
            }
            if let name = s.gpus.first?.name { add(Line().t("  \(s.gpus.count)× \(name)", .tertiaryLabelColor), menu) }
            menu.addItem(.separator())
        }
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        let up = NSMenuItem(title: "Updated " + (updated.map { df.string(from: $0) } ?? "—") + "  (every \(Int(INTERVAL))s)", action: nil, keyEquivalent: "")
        up.isEnabled = false; menu.addItem(up)
        let r = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r"); r.target = self; menu.addItem(r)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: ""); login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }

    func menuWillOpen(_ m: NSMenu) { menuOpen = true; rebuild(); refresh() }
    func menuDidClose(_ m: NSMenu) { menuOpen = false }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
