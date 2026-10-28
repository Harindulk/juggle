import Foundation

// Self-check for Sources/Logic.swift. build.sh runs it before every build; any failed assert stops the build.

// Processes: main + named profile, a duplicate, Claude in ~/Applications, and lines that must not count.
let main = "/U/Claude", work = "/U/Claude-Work"
let ps = """
  53243 /Applications/Claude.app/Contents/MacOS/Claude
  19604 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/U/Claude-Work/
  19700 /Users/me/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/U/Claude-Work
    777 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/U/Claude-My Space --some-flag
  19607 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu-process --user-data-dir=/U/Claude-Work
  19702 /U/Claude-Work/claude-code/2.1.309/x/claude.app/Contents/MacOS/claude --output-format stream-json
  19703 /Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- /U/Claude/claude-code/claude.app/Contents/MacOS/claude
  19704 /bin/zsh -c open /Applications/Claude.app/Contents/MacOS/Claude
  19705 /Applications/Claude.app/Contents/MacOS/Claude Helper
"""
// Known limit: `grep /Applications/Claude.app/Contents/MacOS/Claude` also parses as Main here; the app drops such pids
// by checking each one's bundle identifier.
let r = runningProfiles(ps: ps, main: main)
assert(r == [main: [53243], work: [19604, 19700], "/U/Claude-My Space": [777]], "\(r)")

// Update reopen.
let t = Date()
let lost: Set = [main, work]
assert(updateStep(lost: lost, running: [main], juggleLaunched: false, secondsSinceUpdate: 5, quitForUpdate: true) == .reopen([work]))
assert(updateStep(lost: lost, running: [main], juggleLaunched: false, secondsSinceUpdate: 5, quitForUpdate: false) == .reopen([work]))
assert(updateStep(lost: lost, running: [main, work], juggleLaunched: false, secondsSinceUpdate: 5, quitForUpdate: false) == .reopen([]))
assert(updateStep(lost: lost, running: [main], juggleLaunched: true, secondsSinceUpdate: 5, quitForUpdate: true) == .done)  // user reopened one
assert(updateStep(lost: lost, running: [], juggleLaunched: false, secondsSinceUpdate: 31, quitForUpdate: true) == .reopen([main, work]))
assert(updateStep(lost: lost, running: [], juggleLaunched: false, secondsSinceUpdate: 20, quitForUpdate: true) == .wait)
assert(updateStep(lost: lost, running: [], juggleLaunched: false, secondsSinceUpdate: 60, quitForUpdate: false) == .wait)
assert(updateStep(lost: lost, running: [], juggleLaunched: false, secondsSinceUpdate: 200, quitForUpdate: false) == .done)

assert(defaultName("/U/Claude-Work") == "Work" && defaultName("/tmp/test") == "test" && defaultName("/U/Claude-") == "Claude-")
assert(chatsText(1) == "1 chat" && chatsText(22) == "22 chats")

assert(folderName(for: "Client Work 2") == "Claude-ClientWork2")
assert(folderName(for: "  ✨ ") == nil)
assert(folderName(for: "Café") == "Claude-Caf")

// Emails: the V8-serialized account object as Claude caches it.
let uuid = "1b2c3d4e-0000-4abc-8def-123456789abc"
func v8(_ s: String) -> [UInt8] { [0x22, UInt8(s.utf8.count)] + Array(s.utf8) }
let blob = Data([0x6F] + v8("uuid") + v8(uuid) + v8("email_address") + v8("me@example.com") + v8("full_name") + v8("Me"))
let orgFirst = Data(v8("organization_uuid") + v8("99999999-0000-4abc-8def-123456789abc") + Array(blob))
assert(emailsInBlob(blob) == [uuid: "me@example.com"], "\(emailsInBlob(blob))")
assert(emailsInBlob(orgFirst) == [uuid: "me@example.com"])
assert(emailsInBlob(Data(v8("email_address") + v8("me@example.com"))).isEmpty)  // no uuid nearby: not trusted
_ = emailsInBlob(Data(blob.prefix(blob.count - 20)))  // truncated blob must not crash

// Chats: what's stranded where, and where copies go.
func chat(_ p: String, _ a: String, _ id: String) -> Chat {
    Chat(profile: p, account: a, file: "\(p)/claude-code-sessions/\(a)/org/\(id).json", title: id, lastActivity: t, archived: false)
}
let chats = [chat(main, "A", "local_1"), chat(main, "B", "local_2"), chat(work, "B", "local_3"), chat("/U/Claude-X", "B", "local_2")]
let stranded = strandedChats(dest: work, account: "B", chats: chats)
assert(stranded.map(\.id) == ["local_2.json"], "\(stranded.map(\.id))")
assert(copyTarget(stranded[0], dest: work) == "/U/Claude-Work/claude-code-sessions/B/org/local_2.json")
assert(strandedChats(dest: main, account: "A", chats: chats).isEmpty)

// Chat files on disk: titles, archived flag, missing fields, junk files.
let tmp = NSTemporaryDirectory() + "juggle-selfcheck-\(getpid())"
let org = tmp + "/claude-code-sessions/acct/org"
try! FileManager.default.createDirectory(atPath: org, withIntermediateDirectories: true)
try! #"{"title":"Hello","lastActivityAt":1700000000000,"isArchived":true}"#.write(toFile: org + "/local_a.json", atomically: true, encoding: .utf8)
try! #"{"title":""}"#.write(toFile: org + "/local_b.json", atomically: true, encoding: .utf8)
try! "not json".write(toFile: org + "/local_c.json", atomically: true, encoding: .utf8)
try! "{}".write(toFile: org + "/deleted_d.json", atomically: true, encoding: .utf8)
let cache = ChatCache()
let loaded = loadChats(tmp, cache: cache).sorted { $0.id < $1.id }
// Cache: an unchanged file is served from memory (a planted title proves it), a touched file is read again.
let fileA = org + "/local_a.json"
cache.byFile[fileA] = (cache.byFile[fileA]!.modified, Chat(profile: tmp, account: "acct", file: fileA, title: "cached", lastActivity: t, archived: false))
assert(loadChats(tmp, cache: cache).contains { $0.title == "cached" })
try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: fileA)
assert(loadChats(tmp, cache: cache).contains { $0.title == "Hello" })
assert(loaded.map(\.title) == ["Hello", "Untitled"], "\(loaded.map(\.title))")
assert(loaded[0].archived && loaded[0].account == "acct" && loaded[0].lastActivity == Date(timeIntervalSince1970: 1_700_000_000))
try? FileManager.default.removeItem(atPath: tmp)

print("Self-check passed")
