import Foundation

// Every account is the official Claude.app run with its own --user-data-dir (Chromium's profile flag).
// The main account is the plain launch with no flag, which Electron keeps in "Application Support/Claude".
let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").path
let mainProfile = supportDir + "/Claude"
let profilePrefix = "Claude-"

// MARK: Processes

/// Profile folder -> pids of the Claude main processes using it, from `ps -xo pid=,command=`
/// (-x without -a: only this user's processes, or another user's Claude would count as our Main).
/// More than one pid means the same profile is open twice, which Claude itself doesn't prevent.
func runningProfiles(ps: String, main: String = mainProfile) -> [String: [Int32]] {
    var out: [String: [Int32]] = [:]
    for line in ps.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { continue }
        let cmd = t[t.index(after: sp)...]
        // The main binary, wherever Claude.app lives. Helpers ("Claude Helper.app") and the Claude Code CLI ("claude.app/.../claude") don't match.
        guard cmd.hasPrefix("/"), let exe = cmd.range(of: "/Claude.app/Contents/MacOS/Claude"),
              !cmd[..<exe.lowerBound].contains(" -"),
              exe.upperBound == cmd.endIndex || cmd[exe.upperBound...].hasPrefix(" -") else { continue }
        var profile = main
        if let r = cmd.range(of: "--user-data-dir=") {
            var v = String(cmd[r.upperBound...])
            if let next = v.range(of: " --") { v = String(v[..<next.lowerBound]) }
            while v.count > 1 && v.hasSuffix("/") { v.removeLast() }
            profile = v
        }
        out[profile, default: []].append(pid)
    }
    return out
}

/// How Claude last quit in this profile, from config.json's lastQuitCleanup (nil if Claude didn't record it).
func lastQuit(_ profile: String) -> (at: Date, forUpdate: Bool)? {
    guard let q = jsonObject(profile + "/config.json")?["lastQuitCleanup"] as? [String: Any],
          let ms = q["quit_epoch_ms"] as? Double, let forUpdate = q["for_update"] as? Bool else { return nil }
    return (Date(timeIntervalSince1970: ms / 1000), forUpdate)
}

enum UpdateStep: Equatable { case wait, done, reopen([String]) }

/// After Claude's version changed: what to do with the accounts that quit around then (`lost`).
/// - juggleLaunched: one came back because Juggle opened it (the user's choice), not the updater.
/// - quitForUpdate: Claude marked one of those quits as for an update.
func updateStep(lost: Set<String>, running: Set<String>, juggleLaunched: Bool,
                secondsSinceUpdate: TimeInterval, quitForUpdate: Bool) -> UpdateStep {
    if !running.isEmpty { return juggleLaunched ? .done : .reopen(lost.subtracting(running).sorted()) }
    // Nothing came back. Give the updater's own relaunch time to land first, so we never start a second copy.
    if quitForUpdate && secondsSinceUpdate > 30 { return .reopen(lost.sorted()) }
    return secondsSinceUpdate > 180 ? .done : .wait
}

// MARK: Profiles

/// "Client Work" -> "Claude-ClientWork".
func folderName(for name: String) -> String? {
    let slug = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    return slug.isEmpty ? nil : profilePrefix + slug
}

func defaultName(_ path: String) -> String {
    let folder = (path as NSString).lastPathComponent
    if path == mainProfile { return "Main" }
    return folder.hasPrefix(profilePrefix) && folder.count > profilePrefix.count ? String(folder.dropFirst(profilePrefix.count)) : folder
}

func chatsText(_ n: Int) -> String { "\(n) chat\(n == 1 ? "" : "s")" }

/// Main plus every "Claude-*" folder that Claude has used (has a config.json) or that we created (`known`).
func profileFolders(in dir: String = supportDir, known: Set<String>) -> [String] {
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
    let others = items.filter { $0.hasPrefix(profilePrefix) }.sorted().map { dir + "/" + $0 }.filter { path in
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            && (known.contains(path) || fm.fileExists(atPath: path + "/config.json"))
    }
    return [mainProfile] + others
}

/// Read straight from disk: Bundle caches Info.plist and would miss an update.
func appVersion(_ appPath: String) -> String? {
    NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")?["CFBundleVersion"] as? String
}

func jsonObject(_ path: String) -> [String: Any]? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func signedInAccount(_ profile: String) -> String? {
    jsonObject(profile + "/config.json")?["lastKnownAccountUuid"] as? String
}

// MARK: Emails
// Claude keeps no plain-text record of the signed-in email. claude.ai's query cache (V8-serialized, in the
// profile's IndexedDB blobs) holds the account object as ... "uuid" "<36 chars>" ... "email_address" "<email>".
// Best effort: if the format changes we just show no email.

func emailsInBlob(_ d: Data) -> [String: String] {
    let key = Data([0x22, 0x0D] + Array("email_address".utf8))  // V8 one-byte string tag, length 13
    let uuidKey = Data([0x22, 0x04] + Array("uuid".utf8) + [0x22, 0x24])  // the key "uuid" (not "..._uuid"), then a 36-char string
    var out: [String: String] = [:]
    var from = d.startIndex
    while let r = d.range(of: key, in: from..<d.endIndex) {
        from = r.upperBound
        let v = r.upperBound
        guard v + 2 < d.endIndex, d[v] == 0x22 else { continue }
        let len = Int(d[v + 1])
        guard len > 3, len < 128, v + 2 + len <= d.endIndex else { continue }
        let email = String(decoding: d[(v + 2)..<(v + 2 + len)], as: UTF8.self)
        guard email.contains("@"), !email.contains(" "),
              let u = d.range(of: uuidKey, options: .backwards, in: max(d.startIndex, r.lowerBound - 200)..<r.lowerBound),
              u.upperBound + 36 <= r.lowerBound else { continue }
        out[String(decoding: d[u.upperBound..<(u.upperBound + 36)], as: UTF8.self)] = email
    }
    return out
}

/// Account uuid -> email for every account cached in this profile.
func cachedEmails(_ profile: String) -> [String: String] {
    let root = profile + "/IndexedDB/https_claude.ai_0.indexeddb.blob"
    guard let files = FileManager.default.enumerator(atPath: root) else { return [:] }
    var out: [String: String] = [:]
    for case let rel as String in files {
        let path = root + "/" + rel
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size < 50_000_000,
              let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
        out.merge(emailsInBlob(d)) { _, new in new }
    }
    return out
}

// MARK: Chats
// Each profile keeps chat metadata in claude-code-sessions/<accountUuid>/<orgUuid>/local_*.json and only lists
// the signed-in account's folder, so chats of another sign-in, or in another profile, look "missing".

struct Chat: Sendable {
    let profile: String, account: String, file: String, title: String, lastActivity: Date, archived: Bool
    var id: String { (file as NSString).lastPathComponent }
}

/// Parsed chats by file, reused while the file's modification date is unchanged. Only touched by one load at a time.
final class ChatCache: @unchecked Sendable {
    var byFile: [String: (modified: Date, chat: Chat)] = [:]
}

func loadChats(_ profile: String, cache: ChatCache? = nil) -> [Chat] {
    let root = profile + "/claude-code-sessions"
    guard let files = FileManager.default.enumerator(atPath: root) else { return [] }
    var out: [Chat] = []
    for case let rel as String in files where (rel as NSString).lastPathComponent.hasPrefix("local_") && rel.hasSuffix(".json") {
        let path = root + "/" + rel
        let modified = files.fileAttributes?[.modificationDate] as? Date ?? .distantPast
        if let hit = cache?.byFile[path], hit.modified == modified { out.append(hit.chat); continue }
        guard let j = jsonObject(path) else { continue }
        let ms = (j["lastActivityAt"] as? Double) ?? (j["createdAt"] as? Double) ?? 0
        let title = (j["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let chat = Chat(profile: profile, account: String(rel.prefix { $0 != "/" }), file: path, title: title,
                        lastActivity: Date(timeIntervalSince1970: ms / 1000), archived: (j["isArchived"] as? Bool) ?? false)
        cache?.byFile[path] = (modified, chat)
        out.append(chat)
    }
    return out
}

/// Chats of `account` stored in other profiles that `dest` doesn't have yet, one per session.
func strandedChats(dest: String, account: String, chats: [Chat]) -> [Chat] {
    let have = Set(chats.filter { $0.profile == dest }.map(\.id))
    var seen = Set<String>()
    return chats.filter { $0.account == account && $0.profile != dest && !have.contains($0.id) && seen.insert($0.id).inserted }
}

/// Where a stranded chat file goes inside `dest` (same account/org subfolders).
func copyTarget(_ chat: Chat, dest: String) -> String {
    let rel = chat.file.components(separatedBy: "/claude-code-sessions/").last!
    return dest + "/claude-code-sessions/" + rel
}
