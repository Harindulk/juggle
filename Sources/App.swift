import SwiftUI
import ServiceManagement

let claudeBundleID = "com.anthropic.claudefordesktop"
let repoURL = URL(string: "https://github.com/Harindulk/juggle")!
let coffeeURL = URL(string: "https://buymeacoffee.com/harindulk")!
/// JUGGLE_DEMO=1: made-up accounts and chats for screenshots. Opens, quits and copies nothing.
/// JUGGLE_DEMO=menu: the same, with the menu bar menu opened instead of the Chats window.
let demoMode = ["1", "menu"].contains(ProcessInfo.processInfo.environment["JUGGLE_DEMO"])
let demoMenu = ProcessInfo.processInfo.environment["JUGGLE_DEMO"] == "menu"

struct Profile: Identifiable, Equatable {
    let path: String, name: String, pids: [Int32], account: String?, email: String?
    var id: String { path }
    var running: Bool { !pids.isEmpty }
    var isMain: Bool { path == mainProfile }
    var title: String { email.map { "\(name)  ·  \($0)" } ?? name }
}

/// What we remember between launches. Emails are kept so an account's chats stay labelled after it signs out.
struct Store: Codable {
    var names: [String: String] = [:]
    var emails: [String: String] = [:]
}

@MainActor final class Hub: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var chats: [Chat] = []
    @Published private(set) var claudeApp: String?
    @Published private(set) var pausedForSignIn: [String] = []  // accounts we quit so a new one could sign in alone
    @Published var reopenAfterUpdate = UserDefaults.standard.object(forKey: "reopenAfterUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reopenAfterUpdate, forKey: "reopenAfterUpdate") }
    }

    private let storeFile = supportDir + "/Juggle/state.json"
    private(set) var store = Store()
    private var launching: [String: Date] = [:]   // started by Juggle, not running yet
    private var launchedAt: [String: Date] = [:]  // last time Juggle started each account
    private var prevRunning: [String: Set<Int32>] = [:]
    private var quitAt: [String: Date] = [:]      // last time each account quit or restarted
    private var version: String?
    private var pendingUpdate: (at: Date, forUpdate: Bool)?
    private var emailScanned: [String: String] = [:]  // profile -> account its cache was last scanned for
    private var polling = false
    private var loading = false
    private var lastLoad = Date.distantPast
    private let chatCache = ChatCache()

    init() {
        if demoMode { loadDemo(); return }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: storeFile)), let s = try? JSONDecoder().decode(Store.self, from: d) { store = s }
        claudeApp = findClaudeApp()
        version = claudeApp.flatMap(appVersion)
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common)  // keeps polling while the menu or an alert is open
    }

    /// Polls `ps` and the profile folders off the main thread, then applies the result here.
    func refresh() {
        guard !polling, !demoMode else { return }
        polling = true
        let known = Set(store.names.keys)
        Task.detached(priority: .utility) {
            let app = findClaudeApp()
            let running = runningProfiles(ps: run("/bin/ps", "-xo", "pid=,command="))
            let paths = profileFolders(known: known)
            let all = paths + running.keys.filter { !paths.contains($0) }.sorted()
            let accounts = Dictionary(uniqueKeysWithValues: all.map { ($0, signedInAccount($0)) })
            let version = app.flatMap(appVersion)
            await MainActor.run { [weak self] in self?.apply(app, version, running, all, accounts) }
        }
    }

    private func apply(_ app: String?, _ newVersion: String?, _ rawRunning: [String: [Int32]], _ all: [String], _ accounts: [String: String?]) {
        polling = false
        if app != claudeApp { claudeApp = app }
        let running = verified(rawRunning)
        let now = Date()
        for p in running.keys { launching[p] = nil }
        watchUpdates(running: running, newVersion: newVersion, now: now)

        let next = all.map { path -> Profile in
            let account = accounts[path] ?? nil
            return Profile(path: path, name: store.names[path] ?? defaultName(path), pids: running[path]?.sorted() ?? [],
                           account: account, email: account.flatMap { store.emails[$0] })
        }
        if next != profiles { profiles = next }
        if now.timeIntervalSince(lastLoad) > 30 { reloadChats() }
    }

    /// Claude's updater quits every account and relaunches at most one; reopen the rest.
    /// Watches pids rather than "nothing running", because the updater can relaunch Claude between two polls.
    private func watchUpdates(running: [String: [Int32]], newVersion: String?, now: Date) {
        for (path, pids) in prevRunning where !Set(running[path] ?? []).isSuperset(of: pids) { quitAt[path] = now }
        prevRunning = running.mapValues(Set.init)
        if let v = newVersion, v != version {
            if let old = version { pendingUpdate = (now, false); log("Claude updated \(old) -> \(v)") }
            version = v
        }
        guard var u = pendingUpdate else { return }
        let since = now.timeIntervalSince(u.at)
        let lost = Set(quitAt.filter { abs($0.value.timeIntervalSince(u.at)) < 120 }.keys)
        guard !lost.isEmpty else { if since > 120 { pendingUpdate = nil }; return }
        // Claude records each quit in config.json until that account next starts; one marked for_update confirms it.
        if !u.forUpdate {
            u.forUpdate = lost.filter { running[$0] == nil }.compactMap(lastQuit).contains { $0.forUpdate && abs($0.at.timeIntervalSince(u.at)) < 300 }
            pendingUpdate = u
        }
        let juggleLaunched = lost.contains { running[$0] != nil && (launchedAt[$0] ?? .distantPast) > (quitAt[$0] ?? .distantPast) }
        switch updateStep(lost: lost, running: Set(running.keys), juggleLaunched: juggleLaunched,
                          secondsSinceUpdate: since, quitForUpdate: u.forUpdate) {
        case .wait: return
        case .done:
            pendingUpdate = nil
            log("Update: nothing to reopen (lost \(lost.map(defaultName).sorted()), recorded for update: \(u.forUpdate))")
        case .reopen(let paths):
            pendingUpdate = nil
            log("Update: reopening \(paths.map(defaultName)) (enabled: \(reopenAfterUpdate), recorded for update: \(u.forUpdate))")
            if reopenAfterUpdate { paths.forEach(launch) }
        }
    }

    /// Keeps only pids that really are Claude, not e.g. `grep /Applications/Claude.app/Contents/MacOS/Claude`.
    private func verified(_ running: [String: [Int32]]) -> [String: [Int32]] {
        running.compactMapValues { pids in
            let ok = pids.filter { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == claudeBundleID }
            return ok.isEmpty ? nil : ok
        }
    }

    /// Fresh from `ps`, for decisions that must not use the last poll (launching, removing, copying).
    private func runningNow() -> [String: [Int32]] {
        if demoMode { return Dictionary(uniqueKeysWithValues: profiles.filter(\.running).map { ($0.path, $0.pids) }) }
        return verified(runningProfiles(ps: run("/bin/ps", "-xo", "pid=,command="))) }

    /// Chats, and emails we don't know yet, come from files that can add up to megabytes, so they load off the main thread.
    func reloadChats() {
        guard !loading, !demoMode else { return }
        loading = true
        lastLoad = Date()
        let paths = profiles.map(\.path)
        // Each profile's cache once per launch, and again when it signs in to another account.
        let needEmail = profiles.filter { $0.account != nil && emailScanned[$0.path] != $0.account }.map(\.path)
        for p in profiles where needEmail.contains(p.path) { emailScanned[p.path] = p.account }
        let cache = chatCache
        Task.detached(priority: .utility) {
            let chats = paths.flatMap { loadChats($0, cache: cache) }.sorted { $0.lastActivity > $1.lastActivity }
            let emails = needEmail.reduce(into: [String: String]()) { all, p in all.merge(cachedEmails(p)) { _, new in new } }
            await MainActor.run { [weak self] in self?.loaded(chats, emails) }
        }
    }

    private func loaded(_ chats: [Chat], _ emails: [String: String]) {
        loading = false
        self.chats = chats
        let merged = store.emails.merging(emails) { _, new in new }
        if merged != store.emails { store.emails = merged; save(); refresh() }
    }

    private func save() {
        try? FileManager.default.createDirectory(atPath: (storeFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? JSONEncoder().encode(store).write(to: URL(fileURLWithPath: storeFile), options: .atomic)
    }

    func displayName(_ profile: String) -> String { profiles.first { $0.path == profile }?.name ?? defaultName(profile) }

    // MARK: Opening and quitting

    func open(_ p: Profile) {
        guard let pid = runningNow()[p.path]?.first, let app = NSRunningApplication(processIdentifier: pid) else { return launch(p.path) }
        NSApp.yieldActivation(to: app)
        app.activate()
        // Activating doesn't bring back a window the user closed; the Dock's "reopen" event does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if !hasWindowOnScreen(pid) { sendReopen(pid) } }
    }

    func openAll() {
        let running = runningNow()
        profiles.filter { running[$0.path] == nil }.forEach { launch($0.path, running: running) }
    }

    private func quit(_ path: String, running: [String: [Int32]]) {
        running[path]?.forEach { NSRunningApplication(processIdentifier: $0)?.terminate() }
    }

    func quit(_ p: Profile) { quit(p.path, running: runningNow()) }

    /// Keeps the copy that started first and quits the rest.
    func quitExtraCopies(_ p: Profile) {
        let apps = (runningNow()[p.path] ?? []).compactMap { NSRunningApplication(processIdentifier: $0) }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        apps.dropFirst().forEach { $0.terminate() }
    }

    private func launch(_ path: String) { launch(path, running: runningNow()) }

    private func launch(_ path: String, running: [String: [Int32]]) {
        guard let app = claudeApp, !demoMode else { return claudeMissing() }
        // Claude doesn't stop a second copy opening on the same profile, and two copies can clobber each other's data.
        if running[path] != nil { return }
        if let t = launching[path], Date().timeIntervalSince(t) < 20 { return }  // still starting up
        launching[path] = Date()
        launchedAt[path] = Date()
        var args = ["-n", "-a", app]  // -n: without it, `open` just focuses whichever Claude is already running
        if path != mainProfile { args += ["--args", "--user-data-dir=\(path)"] }
        run("/usr/bin/open", args)
    }

    private func claudeMissing() {
        if demoMode { return }
        let a = NSAlert()
        a.messageText = "Claude isn't installed"
        a.informativeText = "Juggle opens your accounts in the Claude desktop app. Install it, then try again."
        a.addButton(withTitle: "Download Claude")
        a.addButton(withTitle: "Cancel")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!) }
    }

    // MARK: Managing accounts

    func addAccount() {
        guard claudeApp != nil else { return claudeMissing() }
        guard let raw = prompt("Add a Claude account", "Give it a name you'll recognise, like \"Client Work\". Each account gets its own Claude window and sign-in.", ok: "Add") else { return }
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let fm = FileManager.default
        let path: String
        if let folder = folderName(for: name) {
            path = supportDir + "/" + folder
            // fileExists also catches "work" vs "Work": the disk is case-insensitive, so both are the same folder.
            if fm.fileExists(atPath: path) { return alert("\"\(name)\" is taken", "A folder called \(folder) already exists. Pick a different name.") }
        } else {  // no A-Z/0-9 in the name (e.g. "Работа"): the menu shows the name, the folder gets a number
            path = (2...).lazy.map { supportDir + "/\(profilePrefix)Account\($0)" }.first { !fm.fileExists(atPath: $0) }!
        }
        do { try fm.createDirectory(atPath: path, withIntermediateDirectories: false) }
        catch { return alert("Couldn't create the account folder", error.localizedDescription) }
        store.names[path] = name
        save()

        let running = runningNow()
        var alone = false
        if !running.isEmpty {
            let a = NSAlert()
            a.messageText = "Sign in to \"\(name)\""
            a.informativeText = "When you sign in through the browser, the link back to Claude can land in an account that's already open. Quitting the other accounts while you sign in avoids that. Chats running in them stop until you reopen them."
            a.addButton(withTitle: "Open Alongside")
            a.addButton(withTitle: "Quit Others While I Sign In")
            NSApp.activate()
            alone = a.runModal() == .alertSecondButtonReturn
        }
        guard alone else { launch(path); return refresh() }
        let others = runningNow()
        pausedForSignIn = Array(others.keys)
        others.keys.forEach { quit($0, running: others) }
        Task {  // wait for them to exit, so the sign-in link has only one place to go
            for _ in 0..<40 where !runningNow().isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            launch(path)
            refresh()
        }
    }

    func finishSignIn() {
        let running = runningNow()
        pausedForSignIn.forEach { launch($0, running: running) }
        pausedForSignIn = []
        refresh()
    }

    func rename(_ p: Profile) {
        guard let name = prompt("Rename \"\(p.name)\"", "This only changes the name Juggle shows.", value: p.name, ok: "Rename")?
            .trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        store.names[p.path] = name
        save()
        refresh()
    }

    func remove(_ p: Profile) {
        // Only folders Juggle manages: never the main profile or some other folder an instance was started with.
        guard !p.isMain, (p.path as NSString).deletingLastPathComponent == supportDir,
              (p.path as NSString).lastPathComponent.hasPrefix(profilePrefix) else { return }
        if runningNow()[p.path] != nil { return alert("Quit \"\(p.name)\" first", "Juggle only removes accounts that aren't open.") }
        let count = chats.filter { $0.profile == p.path }.count
        let a = NSAlert()
        a.messageText = "Remove \"\(p.name)\"?"
        a.informativeText = "Its folder goes to the Trash with everything in it: sign-in, settings and the list of its \(chatsText(count)). You can put it back from the Trash. To keep its chats in another account, use Bring Chats first."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if runningNow()[p.path] != nil { return alert("\"\(p.name)\" is open now", "Nothing was removed. Quit it and try again.") }
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p.path), resultingItemURL: nil) }
        catch { return alert("Couldn't move \"\(p.name)\" to the Trash", error.localizedDescription) }
        store.names[p.path] = nil
        save()
        refresh()
    }

    // MARK: Chats

    /// Accounts signed in somewhere whose chats also sit in other profiles.
    var stranded: [(profile: Profile, chats: [Chat])] {
        profiles.compactMap { p in
            guard let a = p.account else { return nil }
            let s = strandedChats(dest: p.path, account: a, chats: chats)
            return s.isEmpty ? nil : (p, s)
        }
    }

    /// One entry per chat: the copy Claude can show, if there is one.
    var uniqueChats: [Chat] {
        let visible = Set(chats.filter { !isOtherSignIn($0) }.map(\.id))
        var seen = Set<String>()
        return chats.filter { c in (!isOtherSignIn(c) || !visible.contains(c.id)) && seen.insert(c.id).inserted }
    }

    /// Chats whose account isn't signed in to any profile: account uuid -> chats.
    var orphaned: [(account: String, chats: [Chat])] {
        let signedIn = Set(profiles.compactMap(\.account))
        return Dictionary(grouping: uniqueChats.filter { !signedIn.contains($0.account) }, by: \.account)
            .map { ($0.key, $0.value) }.sorted { $0.chats.count > $1.chats.count }
    }

    func accountLabel(_ uuid: String) -> String { store.emails[uuid] ?? "account \(uuid.prefix(8))…" }

    func isOtherSignIn(_ c: Chat) -> Bool { profiles.first { $0.path == c.profile }?.account != c.account }

    func reveal(_ c: Chat) {
        guard let p = profiles.first(where: { $0.path == c.profile }) else {
            return alert("\"\(c.title)\" was in an account that's gone", "Its folder was removed. If you moved it to the Trash, put it back and Juggle will find it again.")
        }
        guard isOtherSignIn(c) else {
            open(p)
            if c.archived { alert("\"\(c.title)\" is archived", "It's in \"\(p.name)\". Show archived chats in Claude's sidebar to find it.") }
            return
        }
        if let home = profiles.first(where: { $0.account == c.account }) {
            alert("\"\(c.title)\" is stored in \"\(p.name)\"",
                  "It belongs to \(accountLabel(c.account)), which is signed in to \"\(home.name)\". Use Bring Chats to copy it there.")
        } else {
            alert("\"\(c.title)\" belongs to a sign-in that isn't open",
                  "It was made in \"\(p.name)\" while \(accountLabel(c.account)) was signed in. Add an account, sign in as \(accountLabel(c.account)), then use Bring Chats to copy its chats over.")
        }
    }

    func bringChats(to p: Profile, _ list: [Chat]) {
        let wasRunning = runningNow()[p.path] != nil
        let a = NSAlert()
        a.messageText = "Copy \(chatsText(list.count)) into \"\(p.name)\"?"
        a.informativeText = "They're copied, not moved: the originals stay where they are."
            + (wasRunning ? " \"\(p.name)\" quits and reopens so it picks them up." : "")
        a.addButton(withTitle: "Copy Chats")
        a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            // Copy only once it has quit, or it may write its in-memory chat list over ours.
            for _ in 0..<60 {
                let running = runningNow()
                guard running[p.path] != nil else { break }
                quit(p.path, running: running)
                try? await Task.sleep(for: .milliseconds(500))
            }
            if runningNow()[p.path] != nil { return alert("\"\(p.name)\" didn't quit", "Nothing was copied. Quit it yourself and try again.") }
            var failed = 0
            for c in list {
                let dest = copyTarget(c, dest: p.path)
                do {
                    try FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: dest) { try FileManager.default.copyItem(atPath: c.file, toPath: dest) }
                } catch { failed += 1 }
            }
            if wasRunning { launch(p.path) }
            lastLoad = .distantPast
            refresh()
            if failed > 0 { alert("\(failed) of \(list.count) chats couldn't be copied", "The rest are in \"\(p.name)\" now.") }
        }
    }

    private func loadDemo() {
        if demoMenu { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { clickStatusItem() } }
        claudeApp = "/Applications/Claude.app"
        let main = mainProfile, work = supportDir + "/Claude-Work", client = supportDir + "/Claude-Client"
        store.emails = ["main": "sam@example.com", "work": "sam@acme.example", "client": "sam@studio.example", "old": "sam@oldjob.example"]
        store.names = [client: "Client Studio"]
        profiles = [(main, "main", [101]), (work, "work", [102]), (client, "client", [])].map { p, a, pids in
            Profile(path: p, name: store.names[p] ?? defaultName(p), pids: pids, account: a, email: store.emails[a])
        }
        let now = Date()
        chats = [
            (work, "work", "Fix flaky checkout tests", 0.2, false), (main, "main", "Plan a weekend trip to Kandy", 1, false),
            (work, "work", "Migrate billing to the new API", 3, false), (client, "client", "Landing page copy, round two", 5, false),
            (main, "old", "Portfolio site redesign", 26, false), (work, "work", "Review the Q4 roadmap doc", 30, false),
            (main, "main", "Learn SwiftUI menus", 50, true), (main, "old", "Interview prep notes", 70, false),
            (client, "client", "Logo feedback summary", 96, false), (main, "old", "Resume rewrite", 140, false),
        ].enumerated().map { i, c in
            Chat(profile: c.0, account: c.1, file: "\(c.0)/claude-code-sessions/\(c.1)/org/local_demo\(i).json", title: c.2,
                 lastActivity: now - c.3 * 3600, archived: c.4)
        }
    }

    // MARK: Start at login

    var startAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setStartAtLogin(_ on: Bool) {
        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
        catch { alert("Couldn't change Start at Login", error.localizedDescription) }
        objectWillChange.send()
    }
}

// MARK: System helpers

/// Opens our own menu bar menu, for demo screenshots.
@MainActor func clickStatusItem() {
    func find(_ v: NSView) -> NSButton? { (v as? NSButton) ?? v.subviews.lazy.compactMap(find).first }
    for w in NSApp.windows where w.className.contains("StatusBar") { if let b = w.contentView.flatMap(find) { b.performClick(nil); return } }
}

/// Update events only, so the auto-reopen can be checked after a real Claude update.
func log(_ line: String) {
    let file = supportDir + "/Juggle/juggle.log"
    try? FileManager.default.createDirectory(atPath: supportDir + "/Juggle", withIntermediateDirectories: true)
    let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    if let h = FileHandle(forWritingAtPath: file) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
    else { try? entry.write(toFile: file, atomically: true, encoding: .utf8) }
}

func findClaudeApp() -> String? {
    let fm = FileManager.default
    for p in ["/Applications/Claude.app", NSHomeDirectory() + "/Applications/Claude.app"] where fm.fileExists(atPath: p) { return p }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID)?.path
}

@discardableResult func run(_ tool: String, _ args: String...) -> String { run(tool, args) }
@discardableResult func run(_ tool: String, _ args: [String]) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: out, as: UTF8.self)
}

func hasWindowOnScreen(_ pid: Int32) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
}

/// The Apple Event the Dock sends on click ('aevt'/'rapp'), aimed at one instance. macOS asks once for permission.
func sendReopen(_ pid: Int32) {
    DispatchQueue.global().async {
        let ev = NSAppleEventDescriptor(eventClass: 0x6165_7674, eventID: 0x7261_7070,
                                        targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                        returnID: -1, transactionID: 0)
        _ = try? ev.sendEvent(options: [.noReply], timeout: 5)
    }
}

@MainActor func prompt(_ title: String, _ info: String, value: String = "", ok: String) -> String? {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = info
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = value
    a.accessoryView = field
    a.addButton(withTitle: ok)
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = field
    NSApp.activate()
    return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

@MainActor func alert(_ title: String, _ info: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = info
    NSApp.activate()
    a.runModal()
}

let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

/// The app icon's three balls on their orbit, drawn as a template so it follows the menu bar's colour.
let menuBarIcon: NSImage = {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.set()
        let ring = NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 10, height: 10))
        ring.lineWidth = 1.2
        ring.stroke()
        for deg in [90.0, 210.0, 330.0] {
            let c = NSPoint(x: 9 + 5 * cos(deg * .pi / 180), y: 9 + 5 * sin(deg * .pi / 180))
            NSBezierPath(ovalIn: NSRect(x: c.x - 2.7, y: c.y - 2.7, width: 5.4, height: 5.4)).fill()
        }
        return true
    }
    img.isTemplate = true
    return img
}()

// MARK: Views

struct MenuContent: View {
    @ObservedObject var hub: Hub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if hub.claudeApp == nil {
            Text("Claude desktop app not found")
            Button("Download Claude…") { NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!) }
            Divider()
        }
        Section("Accounts") {
            ForEach(hub.profiles) { p in
                // Text dots, not SF Symbols: menu bar menus don't draw a Label's image.
                Button((p.running ? "●  " : "○  ") + p.title) { hub.open(p) }
            }
        }
        ForEach(hub.profiles.filter { $0.pids.count > 1 }) { p in
            Button("⚠︎ \(p.name) is open twice: Quit the Extra Copy") { hub.quitExtraCopies(p) }
        }
        Button("Open All Accounts") { hub.openAll() }.disabled(hub.claudeApp == nil || hub.profiles.allSatisfy(\.running))
        Button("Add Account…") { hub.addAccount() }
        if !hub.pausedForSignIn.isEmpty {
            Button("Done Signing In: Reopen Other Accounts") { hub.finishSignIn() }
        }
        Menu("Manage Accounts") {
            Menu("Quit") { ForEach(hub.profiles.filter(\.running)) { p in Button(p.name) { hub.quit(p) } } }
                .disabled(!hub.profiles.contains(where: \.running))
            Menu("Rename") { ForEach(hub.profiles) { p in Button(p.name) { hub.rename(p) } } }
            let removable = hub.profiles.filter { !$0.isMain && $0.path.hasPrefix(supportDir + "/" + profilePrefix) }
            Menu("Remove") { ForEach(removable) { p in Button(p.name) { hub.remove(p) } } }
                .disabled(removable.isEmpty)
            Divider()
            Button("Show Account Folders in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: supportDir)) }
        }

        Divider()
        let hidden = hub.uniqueChats.filter(hub.isOtherSignIn).count
        Button(hidden == 0 ? "Chats…" : "Chats… (\(hidden) hidden)") {
            openWindow(id: "chats")
            NSApp.activate()
        }.keyboardShortcut("f")
        Menu("Recent Chats") {
            ForEach(hub.uniqueChats.prefix(15), id: \.file) { c in
                Button("\(c.title)  —  \(hub.displayName(c.profile))") { hub.reveal(c) }
            }
        }.disabled(hub.chats.isEmpty)
        ForEach(hub.stranded, id: \.profile.id) { s in
            Button("Bring \(chatsText(s.chats.count).capitalized) to \(s.profile.name)…") { hub.bringChats(to: s.profile, s.chats) }
        }

        Divider()
        Toggle("Reopen Accounts After Claude Updates", isOn: $hub.reopenAfterUpdate)
        Toggle("Start Juggle at Login", isOn: Binding(get: { hub.startAtLogin }, set: { hub.setStartAtLogin($0) }))
        Divider()
        Button("About Juggle") { NSApp.orderFrontStandardAboutPanel(); NSApp.activate() }
        Button("Juggle on GitHub") { NSWorkspace.shared.open(repoURL) }
        Button("Buy Me a Coffee…") { NSWorkspace.shared.open(coffeeURL) }
        Button("Quit Juggle") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// The window's search and account filter. (A class, not @State: that macro needs Xcode, and Juggle builds with just the Command Line Tools.)
final class ChatsFilter: ObservableObject {
    @Published var query = ""
    @Published var scope = "all"
}

struct ChatsView: View {
    @ObservedObject var hub: Hub
    @StateObject private var filter = ChatsFilter()
    private var query: String { filter.query }
    private var scope: String { filter.scope }

    private var shown: [Chat] {
        hub.uniqueChats.filter { c in
            (scope == "all" || (scope == "hidden" ? hub.isOtherSignIn(c) : c.profile == scope))
                && (query.isEmpty || c.title.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(hub.stranded, id: \.profile.id) { s in
                Banner(text: "\(chatsText(s.chats.count)) of \(s.profile.email ?? s.profile.name) \(s.chats.count == 1 ? "is" : "are") stored in other account folders, so \(s.profile.name) can't show \(s.chats.count == 1 ? "it" : "them").",
                       button: "Bring Them to \(s.profile.name)…") { hub.bringChats(to: s.profile, s.chats) }
            }
            ForEach(hub.orphaned, id: \.account) { o in
                Banner(text: "\(chatsText(o.chats.count)) \(o.chats.count == 1 ? "belongs" : "belong") to \(hub.accountLabel(o.account)), which isn't signed in to any account. Add an account and sign in with it to see \(o.chats.count == 1 ? "it" : "them") again.",
                       button: "Add Account…") { hub.addAccount() }
            }
            if shown.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No chats" : "No chats match \"\(query)\"", systemImage: "bubble.left.and.bubble.right")
            } else {
                List(shown, id: \.file) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).lineLimit(1)
                            Text(detail(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(hub.isOtherSignIn(c) ? "Why Hidden?" : "Open") { hub.reveal(c) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .searchable(text: $filter.query, placement: .toolbar, prompt: "Search chat titles")
        .toolbar {
            Picker("Account", selection: $filter.scope) {
                Text("All Accounts").tag("all")
                ForEach(hub.profiles) { p in Text(p.name).tag(p.path) }
                Text("Hidden Chats").tag("hidden")
            }
        }
        .navigationTitle("Chats")
        .onAppear { hub.reloadChats() }
    }

    private func detail(_ c: Chat) -> String {
        var parts = [hub.displayName(c.profile), relative.localizedString(for: c.lastActivity, relativeTo: Date())]
        if hub.isOtherSignIn(c) { parts.append("hidden: other sign-in (\(hub.accountLabel(c.account)))") }
        else if c.archived { parts.append("archived") }
        return parts.joined(separator: "  ·  ")
    }
}

struct Banner: View {
    let text: String, button: String, action: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action)
        }
        .padding(10)
        .background(.orange.opacity(0.1))
        Divider()
    }
}

@main struct JuggleApp: App {
    @StateObject private var hub: Hub
    init() {
        let h = Hub()  // built here, not lazily, so the update watcher runs before the menu is ever opened
        _hub = StateObject(wrappedValue: h)
    }
    var body: some Scene {
        MenuBarExtra { MenuContent(hub: hub) } label: { Image(nsImage: menuBarIcon) }
        Window("Chats", id: "chats") { ChatsView(hub: hub) }
            .defaultSize(width: 680, height: 520)
            .defaultLaunchBehavior(demoMode && !demoMenu ? .presented : .suppressed)
    }
}
