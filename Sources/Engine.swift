// Day Offload engine — scan, copy and compare. Runs as a child process of the
// app (`DayOffload --engine <command> …`) and reports progress as JSON lines on
// stdout, so the window stays responsive and Cancel can simply stop it.
//
// The card is only ever read. Nothing on it is changed or deleted.
//
//   --engine scan    --source /Volumes/CARD [--day-start-hour 4]
//   --engine copy    --source /Volumes/CARD --from 2026-10-15 [--to 2026-10-17] --dest A [--dest B] [--label A001]
//   --engine compare --shoot /Volumes/RAID/Project --office /Volumes/OFFICE/Project [--reread] [--report out.txt]

import Foundation
import CryptoKit

enum Engine {
    static let chunk = 16 << 20
    static let manifestName = "_offload_manifest.csv"
    static let manifestFields = ["path", "size", "mtime", "md5", "xxh3_128", "verified_at", "source"]
    static let skipNames: Set<String> = ["System Volume Information", "$RECYCLE.BIN", "Thumbs.db"]

    // MARK: - Entry point

    static func main(_ argv: [String]) -> Int32 {
        var a = Args(argv)
        do {
            switch a.command {
            case "scan": return try scan(&a)
            case "copy": return try copy(&a)
            case "compare": return try compare(&a)
            default:
                emit(["type": "error", "message": "Unknown command \(a.command)"]); return 9
            }
        } catch {
            emit(["type": "error", "message": "\(error)"]); return 9
        }
    }

    struct Args {
        var command = ""
        var values: [String: [String]] = [:]
        var flags: Set<String> = []
        init(_ argv: [String]) {
            var it = argv.makeIterator()
            command = it.next() ?? ""
            while let k = it.next() {
                guard k.hasPrefix("--") else { continue }
                let key = String(k.dropFirst(2))
                if ["reread", "dry-run"].contains(key) { flags.insert(key); continue }
                if let v = it.next() { values[key, default: []].append(v) }
            }
        }
        func one(_ k: String) -> String? { values[k]?.first }
        func all(_ k: String) -> [String] { values[k] ?? [] }
        func int(_ k: String, _ d: Int) -> Int { one(k).flatMap(Int.init) ?? d }
    }

    // MARK: - Output

    static let outLock = NSLock()
    static func emit(_ event: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]) else { return }
        outLock.lock(); defer { outLock.unlock() }
        FileHandle.standardOutput.write(d)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    final class Progress {
        let total: Int64
        var done: Int64 = 0
        let t0 = Date()
        var last = Date.distantPast
        let lock = NSLock()
        init(_ total: Int64) { self.total = max(total, 1) }
        func add(_ n: Int, _ phase: String, _ name: String) {
            lock.lock(); defer { lock.unlock() }
            done += Int64(n)
            let now = Date()
            guard now.timeIntervalSince(last) > 0.25 else { return }
            last = now
            let rate = Double(done) / max(now.timeIntervalSince(t0), 0.001)
            var e: [String: Any] = ["type": "progress", "phase": phase, "file": name, "done": done,
                                    "total": total, "mbps": (rate / 1e5).rounded() / 10]
            if rate > 0 { e["eta"] = Int(Double(total - done) / rate) }
            emit(e)
        }
    }

    // MARK: - Files

    struct FileInfo { let size: Int64; let mtime: Double; let birth: Double }

    static func info(_ path: String) -> FileInfo? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let b = Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) / 1e9
        return FileInfo(size: Int64(st.st_size), mtime: m, birth: b)
    }

    static func isDir(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func join(_ a: String, _ b: String) -> String {
        a.hasSuffix("/") ? a + b : a + "/" + b
    }

    static func ignorableFile(_ name: String) -> Bool {
        name.hasPrefix(".") || skipNames.contains(name)
    }

    /// Depth-first walk in sorted order, skipping hidden things; calls `file` with (path, name).
    static func walk(_ root: String, skipDir: (String, String) -> Bool = { _, _ in false },
                     _ file: (String, String) -> Void) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        var dirs: [String] = []
        for n in names.sorted() {
            let p = join(root, n)
            if isSymlink(p) && isDir((try? FileManager.default.destinationOfSymbolicLink(atPath: p)).map {
                $0.hasPrefix("/") ? $0 : join(root, $0) } ?? "") { continue }  // like os.walk: don't follow linked folders
            if isDir(p) {
                if !n.hasPrefix(".") && !skipNames.contains(n) && !skipDir(p, n) { dirs.append(p) }
            } else {
                file(p, n)
            }
        }
        for d in dirs { walk(d, skipDir: skipDir, file) }
    }

    static func rel(_ path: String, _ root: String) -> String {
        let r = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(r) ? String(path.dropFirst(r.count)) : path
    }

    // MARK: - Card scan

    struct Item { let rel: String; let size: Int64; let mtime: Double; let day: String }

    static func stem(_ name: String) -> String { String(name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func shootDay(_ t: Double, _ startHour: Int) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: t - Double(startHour) * 3600))
    }

    /// Every real file on the card with its shoot day. Files sharing a name stem
    /// (A001.braw, Proxy/A001.mp4, Proxy/A001.sidecar) take the clip's earliest time.
    static func indexCard(_ source: String, _ startHour: Int) -> [Item] {
        var files: [(String, FileInfo)] = []
        walk(source) { p, n in
            guard !ignorableFile(n), let i = info(p) else { return }
            files.append((rel(p, source), i))
        }
        var earliest: [String: Double] = [:]
        for (r, i) in files {
            let k = stem((r as NSString).lastPathComponent)
            earliest[k] = min(earliest[k] ?? .infinity, min(i.mtime, i.birth))
        }
        return files.map { r, i in
            Item(rel: r, size: i.size, mtime: i.mtime,
                 day: shootDay(earliest[stem((r as NSString).lastPathComponent)]!, startHour))
        }
    }

    static func cardLabel(_ source: String) -> String {
        let n = (source as NSString).standardizingPath
        let last = (n as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? "CARD" : last
    }

    static func scan(_ a: inout Args) throws -> Int32 {
        guard let source = a.one("source") else { throw EngineError("Missing --source") }
        let items = indexCard(source, a.int("day-start-hour", 4))
        var days: [String: (Int, Int64)] = [:]
        for it in items {
            let d = days[it.day] ?? (0, 0)
            days[it.day] = (d.0 + 1, d.1 + it.size)
        }
        emit(["type": "scan", "source": source, "label": cardLabel(source),
              "days": days.keys.sorted().map { ["day": $0, "files": days[$0]!.0, "bytes": days[$0]!.1] }])
        return 0
    }

    // MARK: - CSV (RFC 4180, as Python's csv module and Stow write it)

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        var chars = Array(text.unicodeScalars)[...]
        while let c = chars.popFirst() {
            if inQuotes {
                if c == "\"" {
                    if chars.first == "\"" { field.unicodeScalars.append("\""); chars.removeFirst() } else { inQuotes = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"" { inQuotes = true
            } else if c == "," { row.append(field); field = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r", chars.first == "\n" { chars.removeFirst() }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.unicodeScalars.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func readCSV(_ path: String) -> [[String: String]] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let rows = parseCSV(text)
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { r in
            var d: [String: String] = [:]
            for (i, k) in header.enumerated() where i < r.count { d[k] = r[i] }
            return d
        }
    }

    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func csvLine(_ fields: [String]) -> String { fields.map(csvField).joined(separator: ",") + "\r\n" }

    static func loadManifest(_ path: String) -> [String: [String: String]] {
        var done: [String: [String: String]] = [:]
        for r in readCSV(path) { if let p = r["path"] { done[p] = r } }
        return done
    }

    /// Append rows; older manifests without the xxh3_128 column are rewritten first.
    static func writeManifest(_ path: String, _ rows: [[String: String]]) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            let header = parseCSV(String(data: fm.contents(atPath: path) ?? Data(), encoding: .utf8) ?? "").first ?? []
            if header != manifestFields {
                let old = Array(loadManifest(path).values)
                let text = csvLine(manifestFields) + old.map { r in csvLine(manifestFields.map { r[$0] ?? "" }) }.joined()
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        var text = fm.fileExists(atPath: path) ? "" : csvLine(manifestFields)
        for r in rows { text += csvLine(manifestFields.map { r[$0] ?? "" }) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try h.close()
        } else {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Hashing and copying

    /// xxHash3-128 of a file, read from the disk itself (page cache bypassed).
    static func hashFile(_ path: String, _ prog: Progress? = nil, _ name: String = "", phase: String = "verify") throws -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw EngineError("Can't open \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var h = XXH3_128()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, chunk)
            if n < 0 { throw EngineError("Read error on \(path): \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            h.update(UnsafeRawBufferPointer(start: buf, count: n))
            prog?.add(n, phase, name)
        }
        return h.hexDigest
    }

    /// Read src once and write it to every destination (.partial, then renamed).
    /// Returns MD5 and xxHash3-128 of what was read from the card.
    static func copyOne(_ src: String, _ dests: [String], _ prog: Progress, _ name: String) throws -> (md5: String, xxh: String) {
        let fd = open(src, O_RDONLY)
        guard fd >= 0 else { throw EngineError("Can't open \(src): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let parts = dests.map { $0 + ".partial" }
        var outs: [Int32] = []
        defer { for o in outs { close(o) } }
        for p in parts {
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let o = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard o >= 0 else { throw EngineError("Can't write \(p): \(String(cString: strerror(errno)))") }
            outs.append(o)
        }
        var md5 = Insecure.MD5()
        var xxh = XXH3_128()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, chunk)
            if n < 0 { throw EngineError("Read error on \(src): \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            let bytes = UnsafeRawBufferPointer(start: buf, count: n)
            var failure: String?
            let fl = NSLock()
            DispatchQueue.concurrentPerform(iterations: outs.count + 1) { i in
                if i == outs.count {
                    md5.update(bufferPointer: bytes); xxh.update(bytes)
                    return
                }
                var off = 0
                while off < n {
                    let w = write(outs[i], buf + off, n - off)
                    if w <= 0 {
                        fl.lock(); failure = "Write error on \(parts[i]): \(String(cString: strerror(errno)))"; fl.unlock()
                        return
                    }
                    off += w
                }
            }
            if let failure {
                for p in parts { unlink(p) }
                throw EngineError(failure)
            }
            prog.add(n, "copy", name)
        }
        for o in outs { _ = fcntl(o, F_FULLFSYNC); }
        var st = stat()
        _ = stat(src, &st)
        var times = [st.st_atimespec, st.st_mtimespec]
        for (p, d) in zip(parts, dests) {
            _ = utimensat(AT_FDCWD, p, &times, 0)
            guard rename(p, d) == 0 else { throw EngineError("Can't finish \(d): \(String(cString: strerror(errno)))") }
        }
        let md5hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        return (md5hex, xxh.hexDigest)
    }

    static func freeSpace(_ path: String) -> Int64 {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return 0 }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }

    static let isoNow: () -> String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - Copy

    static func copy(_ a: inout Args) throws -> Int32 {
        guard let source = a.one("source"), let lo = a.one("from") else { throw EngineError("Missing --source or --from") }
        let dests = a.all("dest")
        guard !dests.isEmpty else { throw EngineError("Missing --dest") }
        let hi = a.one("to") ?? lo
        let label = a.one("label") ?? cardLabel(source)
        let items = indexCard(source, a.int("day-start-hour", 4)).filter { lo <= $0.day && $0.day <= hi }
        let span = lo == hi ? lo : "\(lo) to \(hi)"
        if items.isEmpty {
            emit(["type": "error", "message": "No files on \(label) from \(span)."]); return 2
        }

        // Each shoot day gets its own folder: <dest>/<day>/<card>/<path on card>
        func root(_ dest: String, _ day: String) -> String { join(join(dest, day), label) }
        var manifests: [String: [String: [String: String]]] = [:]
        func manifest(_ r: String) -> [String: [String: String]] {
            if let m = manifests[r] { return m }
            let m = loadManifest(join(r, manifestName)); manifests[r] = m; return m
        }

        // Copy to a destination unless it already verified this file at the same size and time.
        var todo: [(Item, [String])] = []
        for it in items {
            var need: [String] = []
            for d in dests {
                let r = root(d, it.day)
                let row = manifest(r)[it.rel]
                let target = join(r, it.rel)
                let ok = row.map { Int64($0["size"] ?? "") == it.size && abs((Double($0["mtime"] ?? "") ?? 0) - it.mtime) < 2 } ?? false
                    && info(target)?.size == it.size
                if !ok { need.append(r) }
            }
            if !need.isEmpty { todo.append((it, need)) }
        }
        let skipped = items.count - todo.count
        let total = todo.reduce(Int64(0)) { $0 + $1.0.size }
        let allRoots = Set(dests.flatMap { d in items.map { root(d, $0.day) } }).sorted()

        for d in dests {
            let prefix = d.hasSuffix("/") ? d : d + "/"
            let needed = todo.reduce(Int64(0)) { s, t in s + Int64(t.1.filter { $0.hasPrefix(prefix) }.count) * t.0.size }
            let free = freeSpace(d)
            if needed > free {
                emit(["type": "error", "message": String(format: "Not enough space on %@: need %.1f GB, %.1f GB free.",
                                                         d, Double(needed) / 1e9, Double(free) / 1e9)])
                return 3
            }
        }

        emit(["type": "plan", "label": label, "span": span, "files": items.count, "to_copy": todo.count,
              "already_done": skipped, "bytes": total, "dests": allRoots])
        if a.flags.contains("dry-run") || todo.isEmpty {
            emit(["type": "done", "copied": 0, "skipped": skipped, "failed": 0, "bytes": 0, "dests": allRoots,
                  "dry_run": a.flags.contains("dry-run")])
            return 0
        }

        // Copy everything, then verify everything: the card is read once, and
        // the verify reads only hit the destination drives.
        let prog = Progress(total)
        var hashes: [String: (md5: String, xxh: String)] = [:]
        var failed: [(String, String)] = []
        for (it, need) in todo {
            do {
                hashes[it.rel] = try copyOne(join(source, it.rel), need.map { join($0, it.rel) }, prog, it.rel)
            } catch {
                failed.append((it.rel, "copy failed: \(error)"))
                emit(["type": "file_error", "file": it.rel, "message": "\(error)"])
            }
        }

        let vprog = Progress(todo.reduce(Int64(0)) { s, t in s + (hashes[t.0.rel] != nil ? t.0.size * Int64(t.1.count) : 0) })
        let lock = NSLock()
        var verified: [String: [Item]] = [:]
        DispatchQueue.concurrentPerform(iterations: dests.count) { di in
            let prefix = dests[di].hasSuffix("/") ? dests[di] : dests[di] + "/"
            for (it, need) in todo {
                guard let want = hashes[it.rel]?.xxh else { continue }
                for r in need where r.hasPrefix(prefix) {
                    let got = (try? hashFile(join(r, it.rel), vprog, it.rel)) ?? "error"
                    lock.lock()
                    if got == want {
                        verified[r, default: []].append(it)
                    } else {
                        failed.append((it.rel, "checksum mismatch on \(r)"))
                        emit(["type": "file_error", "file": it.rel, "message": "Checksum mismatch on \(r)"])
                    }
                    lock.unlock()
                }
            }
        }

        let now = isoNow()
        for (r, its) in verified {
            try writeManifest(join(r, manifestName), its.map { it in
                ["path": it.rel, "size": String(it.size), "mtime": String(it.mtime),
                 "md5": hashes[it.rel]!.md5, "xxh3_128": hashes[it.rel]!.xxh, "verified_at": now, "source": source]
            })
        }

        let bad = Set(failed.map(\.0))
        emit(["type": "done", "copied": todo.count - bad.count, "skipped": skipped, "failed": bad.count,
              "errors": Array(failed.map(\.1).prefix(20)), "bytes": total, "dests": allRoots, "dry_run": false])
        return failed.isEmpty ? 0 : 1
    }

    // MARK: - Compare

    static let cachePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Day Offload/xxh3-cache.json").path

    /// Remembers checksums by path + size + modified time, so running Compare
    /// again only reads files that are new or changed.
    final class HashCache {
        var d: [String: String]
        var dirty = 0
        let lock = NSLock()
        init() {
            d = (FileManager.default.contents(atPath: Engine.cachePath)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) ?? [:]
        }
        static func key(_ path: String) -> String? {
            guard let i = Engine.info(path) else { return nil }
            return "\(path)|\(i.size)|\(Int(i.mtime))"
        }
        func get(_ path: String) -> String? { HashCache.key(path).flatMap { k in lock.withLock { d[k] } } }
        func put(_ path: String, _ v: String) {
            guard let k = HashCache.key(path) else { return }
            lock.withLock { d[k] = v; dirty += 1 }
            if dirty >= 25 { save() }  // save as we go, so a cancelled run keeps its work
        }
        func save() {
            lock.lock(); defer { lock.unlock() }
            guard dirty > 0, let data = try? JSONSerialization.data(withJSONObject: d) else { return }
            try? FileManager.default.createDirectory(atPath: (Engine.cachePath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: Engine.cachePath), options: .atomic)
            dirty = 0
        }
    }

    struct OfficeRow { let size: Int64; let xxh: String; let path: String }

    final class ShootFile {
        let path: String, name: String, size: Int64, root: String
        let recordXXH: String?, day: String?
        var stow: [(card: String, rel: String, row: OfficeRow)] = []
        var loose: [String] = []
        var mine: String?
        var status = ""
        var card: String?, relOnCard: String?, officeCopy: String?, checkedBy = "", officeGroup: String?
        init(path: String, name: String, size: Int64, root: String, recordXXH: String?, day: String?) {
            self.path = path; self.name = name; self.size = size; self.root = root
            self.recordXXH = recordXXH; self.day = day
        }
    }

    /// Every Day Offload card folder under root: (card, day, folder).
    static func findDayOffloads(_ root: String) -> [(String, String, String)] {
        var out: [(String, String, String)] = []
        func visit(_ d: String) {
            if FileManager.default.fileExists(atPath: join(d, manifestName)) {
                let n = d as NSString
                out.append((n.lastPathComponent, (n.deletingLastPathComponent as NSString).lastPathComponent, d))
                return
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: d) else { return }
            for n in names.sorted() where !n.hasPrefix(".") && n != "_verification" {
                let p = join(d, n)
                if isDir(p) { visit(p) }
            }
        }
        visit(root)
        return out
    }

    /// Every Stow card backup under root: (card, folder, checksums.csv).
    static func findStowCards(_ root: String) -> [(String, String, String)] {
        var out: [(String, String, String)] = []
        func visit(_ d: String) {
            let csv = join(join(d, "_verification"), "checksums.csv")
            if FileManager.default.fileExists(atPath: csv) {
                out.append(((d as NSString).lastPathComponent, d, csv)); return
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: d) else { return }
            for n in names.sorted() where !n.hasPrefix(".") {
                let p = join(d, n)
                if isDir(p) { visit(p) }
            }
        }
        visit(root)
        return out
    }

    static func ignorableRel(_ r: String) -> Bool {
        ignorableFile((r as NSString).lastPathComponent) || r.hasPrefix("_verification/")
    }

    static func walkFiles(_ root: String, skip: Set<String> = []) -> [(String, String, Int64)] {
        var out: [(String, String, Int64)] = []
        walk(root, skipDir: { p, n in n == "_verification" || skip.contains(p) }) { p, n in
            guard !ignorableFile(n), n != manifestName, !n.hasSuffix(".partial"), let i = info(p) else { return }
            out.append((p, n, i.size))
        }
        return out
    }

    static func compare(_ a: inout Args) throws -> Int32 {
        guard let officeRoot = a.one("office") else { throw EngineError("Missing --office") }
        let shootRoots = a.all("shoot")
        guard !shootRoots.isEmpty else { throw EngineError("Missing --shoot") }
        let reread = a.flags.contains("reread")
        let cache = HashCache()

        // Office side: Stow records, then every other file on the office backup.
        var office: [String: [String: OfficeRow]] = [:]
        var officeDirs: [String: String] = [:]
        var stowByName: [String: [(String, String, OfficeRow)]] = [:]  // "name|size"
        for (card, d, csvPath) in findStowCards(officeRoot) {
            var rows: [String: OfficeRow] = [:]
            for r in readCSV(csvPath) {
                guard let f = r["file"], !ignorableRel(f), let size = Int64(r["size_bytes"] ?? "") else { continue }
                let row = OfficeRow(size: size, xxh: (r["xxh3_128"] ?? "").lowercased(), path: join(d, f))
                rows[f] = row
                stowByName["\((f as NSString).lastPathComponent)|\(size)", default: []].append((card, f, row))
            }
            let key = office[card] == nil ? card : "\(card) (\(d))"
            office[key] = rows; officeDirs[key] = d
        }
        let stowPaths = Set(office.values.flatMap { $0.values.map(\.path) })
        var looseByName: [String: [String]] = [:]
        var namesSeen = Set<String>()
        for (p, f, size) in walkFiles(officeRoot) {
            namesSeen.insert(f)
            if !stowPaths.contains(p) { looseByName["\(f)|\(size)", default: []].append(p) }
        }
        if office.isEmpty && looseByName.isEmpty {
            emit(["type": "error", "message": "No files found in the office backup folder."]); return 2
        }

        // Shoot side: every real file, plus any checksum Day Offload saved for it.
        var records: [String: (String, String)] = [:]
        for root in shootRoots {
            for (_, day, d) in findDayOffloads(root) {
                for (r, row) in loadManifest(join(d, manifestName)) {
                    records[join(d, r)] = ((row["xxh3_128"] ?? "").lowercased(), day)
                }
            }
        }
        var shoot: [ShootFile] = []
        for root in shootRoots {
            for (p, f, size) in walkFiles(root, skip: [officeRoot]) {
                let rec = records[p]
                shoot.append(ShootFile(path: p, name: f, size: size, root: root,
                                       recordXXH: (rec?.0.isEmpty ?? true) ? nil : rec?.0, day: rec?.1))
            }
        }
        if shoot.isEmpty {
            emit(["type": "error", "message": "No files found in the shoot folder."]); return 2
        }

        // Work out what has to be read from disk (anything not saved or remembered).
        var reads: [String: Int64] = [:]
        var readOrder: [String] = []
        for e in shoot {
            e.stow = stowByName["\(e.name)|\(e.size)"] ?? []
            e.loose = e.stow.isEmpty ? (looseByName["\(e.name)|\(e.size)"] ?? []) : []
            e.mine = reread ? nil : (e.recordXXH ?? cache.get(e.path))
            if (!e.stow.isEmpty || !e.loose.isEmpty) && e.mine == nil, reads[e.path] == nil {
                reads[e.path] = e.size; readOrder.append(e.path)
            }
            for p in e.loose where cache.get(p) == nil && reads[p] == nil {
                reads[p] = e.size; readOrder.append(p)
            }
        }
        let readBytes = reads.values.reduce(0, +)
        let prog = Progress(readBytes)
        emit(["type": "compare_plan", "shoot_files": shoot.count, "office_cards": office.count,
              "to_read": readOrder.count, "bytes": readBytes])

        let shootPrefixes = shootRoots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func xxh(_ path: String, _ name: String) throws -> String {
            let isShoot = shootPrefixes.contains { path.hasPrefix($0) }
            if let v = cache.get(path), !(reread && isShoot) { return v }
            let v = try hashFile(path, prog, name, phase: "reading")
            cache.put(path, v)
            return v
        }
        func shootCardDir(_ path: String, _ r: String) -> String {
            path.hasSuffix("/" + r) ? String(path.dropLast(r.count + 1)) : (path as NSString).deletingLastPathComponent
        }
        func groupOf(_ officePath: String) -> String {
            let d = (officePath as NSString).deletingLastPathComponent
            return (d as NSString).lastPathComponent.lowercased() == "proxy" ? (d as NSString).deletingLastPathComponent : d
        }

        defer { cache.save() }
        for e in shoot {
            if e.stow.isEmpty && e.loose.isEmpty {
                e.status = namesSeen.contains(e.name) ? "different" : "missing"
                continue
            }
            var mine = e.mine
            if mine == nil {
                do { mine = try xxh(e.path, e.name) } catch { e.status = "unreadable" }
            }
            var hit = false
            if !e.stow.isEmpty {
                let match = mine.flatMap { m in e.stow.first { $0.row.xxh == m } }
                let c = match ?? e.stow[0]
                hit = match != nil
                e.card = c.card; e.relOnCard = c.rel; e.officeCopy = c.row.path; e.checkedBy = "stow"
            } else {
                var found: String?
                for p in e.loose {
                    if let m = mine, let theirs = try? xxh(p, e.name), theirs == m { found = p; break }
                }
                let p = found ?? e.loose[0]
                hit = found != nil
                let g = groupOf(p)
                e.card = rel(g, officeRoot); e.relOnCard = rel(p, g); e.officeCopy = p
                e.checkedBy = "read"; e.officeGroup = g
            }
            if e.status != "unreadable" { e.status = hit ? "match" : "different" }
        }

        // Summary per office card / folder.
        var cards: [[String: Any]] = []
        for card in Set(shoot.compactMap(\.card)).sorted() {
            let es = shoot.filter { $0.card == card }
            func count(_ s: String) -> Int { es.filter { $0.status == s }.count }
            let isStow = es[0].checkedBy == "stow"
            var only: [String] = [], odir = es[0].officeGroup ?? ""
            if isStow {
                let matched = Set(es.filter { $0.status == "match" }.compactMap(\.relOnCard))
                only = Set(office[card]!.keys).subtracting(matched).sorted()
                odir = officeDirs[card]!
            }
            cards.append(["card": card, "office_card": card, "office_dir": odir, "stow": isStow,
                          "shoot_dirs": Set(es.map { shootCardDir($0.path, $0.relOnCard ?? "") }).sorted(),
                          "days": Set(es.compactMap(\.day)).sorted(),
                          "files": es.count, "match": count("match"), "different": count("different"),
                          "missing": 0, "unreadable": count("unreadable"), "in_office": true,
                          "only_in_office": only.count, "only_in_office_examples": Array(only.prefix(5))])
        }

        // Shoot files with no copy in the office backup at all, by folder.
        var groups: [String: [ShootFile]] = [:]
        for e in shoot where e.status == "missing" {
            groups[(e.path as NSString).deletingLastPathComponent, default: []].append(e)
        }
        func inProxy(_ d: String) -> Bool { (d as NSString).lastPathComponent.lowercased() == "proxy" }
        let notInOffice: [[String: Any]] = groups.keys.sorted()
            .sorted { !inProxy($0) && inProxy($1) }  // real gaps first, proxy folders after
            .map { d in
                let es = groups[d]!
                return ["dir": d, "count": es.count, "bytes": es.reduce(Int64(0)) { $0 + $1.size },
                        "examples": es.prefix(5).map(\.name), "proxy": inProxy(d),
                        "files": es.prefix(500).map { ["name": $0.name, "size": $0.size, "path": $0.path] }]
            }

        let problems: [[String: Any]] = shoot.filter { $0.status != "match" }.map { e in
            var p: [String: Any] = ["card": e.card ?? "", "day": e.day ?? "", "file": rel(e.path, e.root),
                                    "status": e.status, "shoot_copy": e.path,
                                    "proxy": e.status == "missing" && inProxy((e.path as NSString).deletingLastPathComponent)]
            p["office_copy"] = e.officeCopy ?? NSNull()
            return p
        }
        let real = problems.filter { !($0["proxy"] as! Bool) }
        let proxyOnly = problems.filter { $0["proxy"] as! Bool }
        let total = shoot.count, matched = shoot.filter { $0.status == "match" }.count
        let ok = problems.isEmpty

        if let report = a.one("report") {
            try writeReport(report, shootRoots, officeRoot, ok, total, matched, real.count, proxyOnly.count,
                            cards, notInOffice, problems)
        }

        emit(["type": "compare_done", "ok": ok, "total": total, "matched": matched, "cards": cards,
              "not_in_office": notInOffice, "problems": Array(real.prefix(300)) + Array(proxyOnly.prefix(100)),
              "problem_count": real.count, "proxy_only": proxyOnly.count, "report": a.one("report") ?? NSNull()])
        return ok ? 0 : 1
    }

    static func writeReport(_ path: String, _ shoot: [String], _ office: String, _ ok: Bool, _ total: Int,
                            _ matched: Int, _ realCount: Int, _ proxyCount: Int, _ cards: [[String: Any]],
                            _ notInOffice: [[String: Any]], _ problems: [[String: Any]]) throws {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        var t = "Day Offload vs office backup — \(f.string(from: Date()))\n"
        t += "Shoot folder: \(shoot.joined(separator: ", "))\nOffice backup: \(office)\n\n"
        t += ok ? "RESULT: ALL \(total) SHOOT FILES IDENTICAL\n\n"
                : "RESULT: \(matched) of \(total) shoot files identical — \(realCount) problem(s) + \(proxyCount) proxy file(s) only on the shoot drive\n\n"
        for c in cards {
            let stow = c["stow"] as! Bool
            t += "\(c["card"]!)  (\(stow ? "Stow checksums" : "no Stow checksums — both copies read"))\n"
            t += "   office copy: \(c["office_dir"]!)\n"
            for sd in c["shoot_dirs"] as! [String] { t += "   shoot copy:  \(sd)\n" }
            t += "   \(c["match"]!)/\(c["files"]!) identical · \(c["different"]!) different · \(c["unreadable"]!) unreadable\n"
            if stow { t += "   \(c["only_in_office"]!) files on the office copy not found on the shoot drive\n" }
            t += "\n"
        }
        if !notInOffice.isEmpty {
            t += "ON THE SHOOT DRIVE BUT NOT IN THE OFFICE BACKUP\n"
            for g in notInOffice {
                let proxy = g["proxy"] as! Bool
                t += "   \(g["count"]!) file(s) in \(g["dir"]!)\(proxy ? "  (proxy folder — probably made on the computer, not on the card)" : "")\n"
                if !proxy {
                    for file in g["files"] as! [[String: Any]] {
                        t += String(format: "      %@  (%.0f MB)\n", file["name"] as! String, Double(file["size"] as! Int64) / 1e6)
                    }
                }
            }
            t += "\n"
        }
        if !problems.isEmpty {
            t += "PROBLEMS\n"
            for p in problems {
                let status = (p["status"] as! String).padding(toLength: 11, withPad: " ", startingAt: 0)
                t += "   \(status) \(p["shoot_copy"]!)\((p["proxy"] as! Bool) ? "  (proxy)" : "")\n"
                if let o = p["office_copy"] as? String { t += "               office: \(o)\n" }
            }
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try t.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

struct EngineError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
