// Day Offload — SwiftUI front end for offload.py (bundled in Resources).
// Build: ./build.sh

import SwiftUI
import AppKit

struct DaySummary: Identifiable, Hashable {
    let day: String, files: Int, bytes: Int64
    var id: String { day }
}

func fileCount(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }

let isoDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

func prettyDay(_ iso: String) -> String {
    guard let d = isoDay.date(from: iso) else { return iso }
    let o = DateFormatter(); o.setLocalizedDateFormatFromTemplate("MMMdEEE")
    return o.string(from: d)
}

enum AppInfo {
    /// Single source of truth for the version (make-app.sh reads it).
    static let version = "1.2"
    static let repo = "https://github.com/kurikurikun/day-offload"
}

// MARK: - Card detection

let cameraExtensions: Set<String> = ["braw", "mp4", "mov", "mxf", "r3d", "ari", "arx", "crm", "mts", "m2ts",
                                     "insv", "360", "lrv", "wav", "arw", "cr2", "cr3", "nef", "raf", "dng", "rw2"]
let cameraFolders: Set<String> = ["DCIM", "PRIVATE", "M4ROOT", "XDROOT", "CONTENTS", "CLIP", "AVCHD"]

/// The folder paths saved as backup destinations.
func savedDestinations() -> [String] { UserDefaults.standard.stringArray(forKey: "dests") ?? [] }

func volumeID(_ vol: URL) -> String? {
    (try? vol.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
}

/// Volumes that must never be treated as cards: every drive ever used as a
/// destination, plus any the user marked "Not a card".
func notCardVolumes() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: "notCardVolumes") ?? []) }

func markNotCard(_ vol: URL) {
    guard let id = volumeID(vol) else { return }
    var s = notCardVolumes(); s.insert(id)
    UserDefaults.standard.set(Array(s), forKey: "notCardVolumes")
}

func volumeOf(_ url: URL) -> URL? {
    (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
}

func isBackupDrive(_ vol: URL, dests: [String]) -> Bool {
    if dests.contains(where: { $0 == vol.path || $0.hasPrefix(vol.path + "/") }) { return true }
    if let id = volumeID(vol), notCardVolumes().contains(id) { return true }
    return false
}

/// A mounted volume counts as a camera card when:
///  - it isn't a known backup drive and holds no Day Offload / Stow backup records, and
///  - it has a camera folder (DCIM, PRIVATE…) at its top level, or camera media at the
///    top level or one folder down (e.g. Proxy/, A001R1AB/), or inside a RED .RDM folder.
func looksLikeCard(_ vol: URL, dests: [String] = savedDestinations()) -> Bool {
    guard vol.path.hasPrefix("/Volumes/"), !isBackupDrive(vol, dests: dests) else { return false }
    if let v = try? vol.resourceValues(forKeys: [.volumeIsRootFileSystemKey]), v.volumeIsRootFileSystem == true { return false }
    guard let e = FileManager.default.enumerator(at: vol, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
    var cardSigns = false, seen = 0
    let deadline = Date().addingTimeInterval(3)
    for case let url as URL in e {
        seen += 1
        if seen > 5000 || Date() > deadline { break }
        let name = url.lastPathComponent
        // Backup records anywhere near the top mean this is a backup drive, not a card.
        if name == "_offload_manifest.csv" || name == "_verification" { return false }
        let level = e.level  // 1 = top level of the volume
        if level == 1 && cameraFolders.contains(name.uppercased()) { cardSigns = true }
        if cameraExtensions.contains(url.pathExtension.lowercased()) {
            let inRED = url.pathComponents.contains { $0.uppercased().hasSuffix(".RDM") }
            if level <= 2 || inRED { cardSigns = true }
        }
        if level >= 5 { e.skipDescendants() }
    }
    return cardSigns
}

// MARK: - Open on card insert (launchd helper)

let watcherLabel = "co.move-ment.dayoffload.cardwatch"
var watcherPlist: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(watcherLabel).plist")
}

/// Runs headless from launchd every time any drive mounts. Opens the app only
/// when it isn't already running and a camera card is connected.
func mountCheck() {
    let me = Bundle.main.bundleIdentifier ?? "co.move-ment.dayoffload"
    let pid = ProcessInfo.processInfo.processIdentifier
    if NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0.processIdentifier != pid }) { return }
    let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
    let dests = savedDestinations()
    guard vols.contains(where: { looksLikeCard($0, dests: dests) }) else { return }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [Bundle.main.bundlePath, "--args", "--check-cards"]
    try? open.run()
    open.waitUntilExit()
}

func setWatcher(_ on: Bool) {
    let uid = String(getuid())
    func launchctl(_ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
    launchctl(["bootout", "gui/\(uid)/\(watcherLabel)"])
    try? FileManager.default.removeItem(at: watcherPlist)
    guard on, let exe = Bundle.main.executablePath else { return }
    let plist: [String: Any] = [
        "Label": watcherLabel,
        "ProgramArguments": [exe, "--mount-check"],
        "StartOnMount": true,
        "ProcessType": "Interactive",
    ]
    try? FileManager.default.createDirectory(at: watcherPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
    (plist as NSDictionary).write(to: watcherPlist, atomically: true)
    launchctl(["bootstrap", "gui/\(uid)", watcherPlist.path])
}

/// Splits the engine's output into lines. The pipe handler runs on a
/// background queue, so the pending bytes are kept behind a lock.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func add(_ chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var out: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            out.append(data.subdata(in: data.startIndex..<nl))
            data.removeSubrange(data.startIndex...nl)
        }
        return out
    }
}

enum Mode: String { case offload, compare }

struct CompareCard: Identifiable {
    var id: String { card }
    let card: String, days: [String], files: Int, match: Int, different: Int, missing: Int,
        unreadable: Int, inOffice: Bool, onlyInOffice: Int
    var officeCard: String? = nil, officeDir: String? = nil, shootDirs: [String] = []
    var stow = true
    var ok: Bool { inOffice && match == files }
}

struct MissingGroup: Identifiable {
    var id: String { dir }
    let dir: String, count: Int, bytes: Int64
    var proxy = false
    var files: [(name: String, size: Int64, path: String)] = []
}

struct CompareProblem: Identifiable {
    let id = UUID()
    let card: String, day: String, file: String, status: String
    var shootCopy: String? = nil, officeCopy: String? = nil
    var proxy = false
}

/// Show a file in Finder; if it doesn't exist, open the nearest folder that does.
func revealInFinder(_ path: String) {
    var url = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url]); return
    }
    while url.path != "/" && !FileManager.default.fileExists(atPath: url.path) { url.deleteLastPathComponent() }
    NSWorkspace.shared.open(url)
}

struct CardResult: Identifiable {
    let id = UUID()
    let card: String, ok: Bool, text: String
    /// Grey note (nothing to do), not a success or a failure.
    var info = false
}

@MainActor
final class Model: ObservableObject {
    let defaults = UserDefaults.standard

    @Published var volumes: [URL] = []
    @Published var source: URL?
    @Published var days: [DaySummary] = []
    @Published var selectedDays: Set<String> = []
    @Published var dayStartHour: Int { didSet { defaults.set(dayStartHour, forKey: "dayStartHour"); scan() } }
    @Published var label = ""
    @Published var dests: [URL] {
        didSet {
            defaults.set(dests.map(\.path), forKey: "dests")
            for d in dests { if let v = volumeOf(d) { markNotCard(v) } }
        }
    }

    // Shoot range: when on, a newly inserted card is scanned, the days in this
    // range are picked, and the offload sheet pops up.
    @Published var autoOn: Bool { didSet { defaults.set(autoOn, forKey: "autoOn"); applyRange() } }
    /// Today mode (default): whatever day it is when a card goes in. Off = the From/To range below.
    @Published var useToday: Bool {
        didSet { defaults.set(useToday, forKey: "useToday"); if useToday { syncToday() }; applyRange() }
    }
    @Published var rangeFrom: Date { didSet { defaults.set(rangeFrom, forKey: "rangeFrom"); rangeEdited(); applyRange() } }
    @Published var rangeTo: Date { didSet { defaults.set(rangeTo, forKey: "rangeTo"); rangeEdited(); applyRange() } }
    private var syncing = false

    /// Today mode: put today's shoot day in the From / To boxes.
    func syncToday() {
        guard useToday, let d = isoDay.date(from: todayShootDay) else { return }
        syncing = true
        if isoDay.string(from: rangeFrom) != todayShootDay { rangeFrom = d }
        if isoDay.string(from: rangeTo) != todayShootDay { rangeTo = d }
        syncing = false
    }

    /// Changing a date by hand means "use this range", not today.
    private func rangeEdited() {
        guard !syncing, useToday else { return }
        if isoDay.string(from: rangeFrom) != todayShootDay || isoDay.string(from: rangeTo) != todayShootDay { useToday = false }
    }
    /// The card that just went in — shown as a note at the top of the main window.
    @Published var arrived: String?
    /// Today mode found nothing from today, so the pop-up offers this (the card's latest day) instead.
    @Published var todayFallbackDay: String?
    // Compare: day-by-day shoot copies vs. the whole-card Stow backup made at the office.
    @Published var mode: Mode = .offload
    @Published var shootDirs: [URL] = (UserDefaults.standard.stringArray(forKey: "shootDirs") ?? []).map { URL(fileURLWithPath: $0) } {
        didSet { defaults.set(shootDirs.map(\.path), forKey: "shootDirs") }
    }
    @Published var officeDir: URL? = UserDefaults.standard.string(forKey: "officeDir").map { URL(fileURLWithPath: $0) } {
        didSet { defaults.set(officeDir?.path, forKey: "officeDir") }
    }
    @Published var reread = false
    @Published var comparing = false
    @Published var compareCards: [CompareCard] = []
    @Published var compareProblems: [CompareProblem] = []
    @Published var notInOffice: [MissingGroup] = []
    @Published var compareSummary: (ok: Bool, text: String)?
    @Published var reportPath: String?

    @Published var openOnCard = FileManager.default.fileExists(atPath: watcherPlist.path) {
        didSet { if openOnCard != oldValue { setWatcher(openOnCard) } }
    }
    /// "Only while the app is open": card pop-ups without the app launching itself.
    @Published var onlyWhileOpen = UserDefaults.standard.object(forKey: "onlyWhileOpen") as? Bool
        ?? (UserDefaults.standard.bool(forKey: "autoOn") && !FileManager.default.fileExists(atPath: watcherPlist.path)) {
        didSet { defaults.set(onlyWhileOpen, forKey: "onlyWhileOpen"); openOnCard = autoOn && !onlyWhileOpen }
    }

    /// The one "when a card goes in" switch: pick the dates, ask where to back up,
    /// and (unless "only while open") open the app when it's closed.
    var cardAssist: Bool {
        get { autoOn }
        set { autoOn = newValue; openOnCard = newValue && !onlyWhileOpen }
    }
    // Cards inserted while another card is being scanned, asked about or
    // offloaded wait here and are handled one after another, same date range.
    @Published var queue: [URL] = []
    @Published var history: [CardResult] = []
    var busy: Bool { running || scanning }

    @Published var scanning = false
    @Published var running = false
    @Published var progress = 0.0
    @Published var status = ""
    @Published var result: (ok: Bool, text: String)?
    @Published var lastRoots: [String] = []
    private var proc: Process?

    init() {
        dayStartHour = defaults.object(forKey: "dayStartHour") as? Int ?? 4
        dests = (defaults.stringArray(forKey: "dests") ?? []).map { URL(fileURLWithPath: $0) }
        autoOn = defaults.bool(forKey: "autoOn")
        useToday = defaults.object(forKey: "useToday") as? Bool ?? true
        rangeFrom = defaults.object(forKey: "rangeFrom") as? Date ?? Date()
        rangeTo = defaults.object(forKey: "rangeTo") as? Date ?? Date()
        refreshVolumes()
        for d in dests { if let v = volumeOf(d) { markNotCard(v) } }
        syncToday()
        if isDemo { loadDemo() }
    }

    /// `--demo` (hidden): made-up example data for README / website screenshots.
    let isDemo = CommandLine.arguments.contains("--demo")
    func loadDemo() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        days = [DaySummary(day: "2026-10-17", files: 214, bytes: 412_800_000_000),
                DaySummary(day: "2026-10-16", files: 188, bytes: 361_200_000_000),
                DaySummary(day: "2026-10-15", files: 96, bytes: 158_400_000_000),
                DaySummary(day: "2026-09-28", files: 12, bytes: 9_700_000_000)]
        source = URL(fileURLWithPath: "/Volumes/A001"); label = "A001"
        dests = [URL(fileURLWithPath: "/Volumes/SHOOT_SSD/2026_10_Documentary"),
                 URL(fileURLWithPath: "/Volumes/SHOOT_SSD_BU/2026_10_Documentary")]
        useToday = false
        rangeFrom = f.date(from: "2026-10-16")!; rangeTo = f.date(from: "2026-10-17")!
        autoOn = true
        selectedDays = ["2026-10-17", "2026-10-16"]
        history = [CardResult(card: "B002", ok: true, text: "Done. 388 files copied and checksum-verified on 2 drive(s).")]
        if CommandLine.arguments.contains("sheet") { arrived = "A001" }
        if CommandLine.arguments.contains("compare") {
            mode = .compare
            shootDirs = [URL(fileURLWithPath: "/Volumes/SHOOT_SSD/2026_10_Documentary")]
            officeDir = URL(fileURLWithPath: "/Volumes/OFFICE_RAID/2026_10_Documentary")
            compareCards = [
                CompareCard(card: "A001", days: [], files: 498, match: 498, different: 0, missing: 0, unreadable: 0,
                            inOffice: true, onlyInOffice: 12, shootDirs: ["/Volumes/SHOOT_SSD/2026_10_Documentary/2026-10-15/A001"]),
                CompareCard(card: "B002", days: [], files: 388, match: 388, different: 0, missing: 0, unreadable: 0,
                            inOffice: true, onlyInOffice: 0, shootDirs: ["/Volumes/SHOOT_SSD/2026_10_Documentary/2026-10-16/B002"]),
                CompareCard(card: "SOUND_01", days: [], files: 64, match: 64, different: 0, missing: 0, unreadable: 0,
                            inOffice: true, onlyInOffice: 3, shootDirs: ["/Volumes/SHOOT_SSD/2026_10_Documentary/2026-10-16/SOUND_01"]),
            ]
            notInOffice = [MissingGroup(dir: "/Volumes/SHOOT_SSD/2026_10_Documentary/2026-10-16/SOUND_01", count: 2,
                                        bytes: 691_000_000,
                                        files: [(name: "20261016_2306_0199.wav", size: 345_600_000, path: "/x/a"),
                                                (name: "20261016_2336_0200.wav", size: 345_600_000, path: "/x/b")]),
                           MissingGroup(dir: "/Volumes/SHOOT_SSD/2026_10_Documentary/2026-10-15/A001/Proxy", count: 96,
                                        bytes: 4_100_000_000, proxy: true)]
            compareSummary = (false, "950 of 1048 shoot files are identical. 2 file(s) need checking (listed below) — don't format these cards yet.")
            reportPath = nil
        }
    }

    var chosen: [DaySummary] { days.filter { selectedDays.contains($0.day) } }
    var chosenFiles: Int { chosen.map(\.files).reduce(0, +) }

    /// The exact folders this offload will write: <destination>/<shoot day>/<card name>/
    var plannedFolders: [String] {
        let card = label.isEmpty ? (source?.lastPathComponent ?? "CARD") : label
        return dests.flatMap { d in chosen.map(\.day).sorted().map { "\(d.path)/\($0)/\(card)/" } }
    }
    var chosenBytes: Int64 { chosen.map(\.bytes).reduce(0, +) }
    /// Today's shoot day: before the day-start hour (04:00) it's still yesterday's shoot.
    var todayShootDay: String {
        isoDay.string(from: Date().addingTimeInterval(-Double(dayStartHour) * 3600))
    }

    var rangeText: String {
        if useToday { return "Today · \(prettyDay(todayShootDay))" }
        let a = isoDay.string(from: rangeFrom), b = isoDay.string(from: rangeTo)
        return a == b ? prettyDay(a) : "\(prettyDay(min(a, b))) – \(prettyDay(max(a, b)))"
    }

    /// Tick exactly the card's days that fall inside the shoot dates.
    func applyRange() {
        guard autoOn, !running else { return }
        selectedDays = Set(days.map(\.day).filter(inRange))
    }

    func inRange(_ day: String) -> Bool {
        if useToday { return day == todayShootDay }
        let a = isoDay.string(from: rangeFrom), b = isoDay.string(from: rangeTo)
        return min(a, b) <= day && day <= max(a, b)
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey]
        let all = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = all.filter { url in
            (try? url.resourceValues(forKeys: Set(keys)))?.volumeIsRootFileSystem != true && url.path.hasPrefix("/Volumes/")
        }
    }

    func choose(_ url: URL?, auto: Bool = false) {
        syncToday()
        if !auto { arrived = nil }
        source = url
        label = url?.lastPathComponent ?? ""
        scan(auto: auto)
    }

    func cardMounted(_ url: URL) {
        refreshVolumes()
        // Ignore backup drives, disk images and anything that isn't a camera card.
        guard autoOn, !isDemo else { return }
        syncToday()
        let d = dests.map(\.path)
        Task {
            // Looking inside a drive can be slow; never do it on the main thread.
            let isCard = await Task.detached { looksLikeCard(url, dests: d) }.value
            guard isCard else { return }
            if busy {
                if url != source && !queue.contains(url) { queue.append(url) }
            } else {
                choose(url, auto: true)
            }
        }
    }

    func cardUnmounted(_ url: URL?) {
        refreshVolumes()
        if let url { queue.removeAll { $0 == url } }
    }

    /// Queue every inserted card (not the backup drives) and start on the first.
    func queueAllMounted() {
        syncToday()
        refreshVolumes()
        let vols = volumes, d = dests.map(\.path)
        Task {
            let cards = await Task.detached { vols.filter { looksLikeCard($0, dests: d) } }.value
            for v in cards where v != source && !queue.contains(v) { queue.append(v) }
            processNext()
        }
    }

    func processNext() {
        guard autoOn, !busy else { return }
        while let next = queue.first {
            queue.removeFirst()
            if FileManager.default.fileExists(atPath: next.path) { choose(next, auto: true); return }
        }
    }

    /// "Not a card": never offer this drive again.
    func notACard() {
        if let s = source { markNotCard(s) }
        source = nil; days = []; selectedDays = []; label = ""
        skip()
    }

    func skip() {
        arrived = nil
        processNext()
    }

    /// A card just went in: make sure the panels that matter are open, on the Offload tab.
    func announceArrival() {
        arrived = label
        mode = .offload
        for key in ["folded.Card", "folded.Back up to (copied to each)"] { defaults.set(false, forKey: key) }
    }

    func record() {
        if let r = result { history.insert(CardResult(card: label, ok: r.ok, text: r.text), at: 0) }
    }

    func run(_ args: [String], onEvent: @escaping ([String: Any]) -> Void, onExit: @escaping (Int32) -> Void) {
        let p = Process()
        // The engine is this same app binary in engine mode (see Engine.swift).
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["--engine"] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let lines = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            for line in lines.add(h.availableData) {
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    DispatchQueue.main.async { onEvent(obj) }
                }
            }
        }
        p.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { onExit(p.terminationStatus) }
        }
        do { try p.run(); proc = p } catch {
            result = (false, "Couldn't start the copy engine: \(error.localizedDescription)")
        }
    }

    func scan(auto: Bool = false) {
        guard let src = source else { days = []; return }
        scanning = true; days = []; result = nil; todayFallbackDay = nil
        run(["scan", "--source", src.path, "--day-start-hour", String(dayStartHour)], onEvent: { e in
            if e["type"] as? String == "scan", let list = e["days"] as? [[String: Any]] {
                self.days = list.map { DaySummary(day: $0["day"] as! String, files: $0["files"] as! Int,
                                                  bytes: ($0["bytes"] as! NSNumber).int64Value) }.reversed()
                if self.autoOn {
                    self.applyRange()
                } else {
                    self.selectedDays = Set(self.days.first.map { [$0.day] } ?? [])
                }
            } else if e["type"] as? String == "error" {
                self.result = (false, e["message"] as? String ?? "Scan failed")
            }
        }, onExit: { _ in
            self.scanning = false
            if auto {
                NSApp.activate(ignoringOtherApps: true)
                if self.selectedDays.isEmpty, self.useToday, let latest = self.days.map(\.day).max() {
                    // Offloading the morning after: no footage from today, so offer the card's latest day.
                    self.selectedDays = [latest]
                    self.todayFallbackDay = latest
                    self.announceArrival()
                } else if self.selectedDays.isEmpty {
                    self.history.insert(CardResult(card: self.label, ok: true,
                                                   text: "Nothing from \(self.rangeText) on this card.", info: true), at: 0)
                    self.processNext()
                } else {
                    self.announceArrival()
                }
            }
        })
    }

    func pickFolder(_ title: String) -> URL? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.canCreateDirectories = true; p.message = title
        return p.runModal() == .OK ? p.url : nil
    }

    func offload() {
        arrived = nil
        guard let src = source, let lo = selectedDays.min(), let hi = selectedDays.max(), !dests.isEmpty else { return }
        if dests.contains(where: { $0.path.hasPrefix(src.path + "/") || $0.path == src.path }) {
            result = (false, "A destination is on the card itself. Choose a different drive."); return
        }
        // Gaps inside lo...hi that the user unticked are still on the card,
        // so run one copy per contiguous block of ticked days.
        let all = days.map(\.day).sorted()
        var blocks: [(String, String)] = []
        var start: String?, prev: String?
        for d in all where d >= lo && d <= hi {
            if selectedDays.contains(d) {
                if start == nil { start = d }
                prev = d
            } else if let s = start, let p = prev {
                blocks.append((s, p)); start = nil
            }
        }
        if let s = start, let p = prev { blocks.append((s, p)) }

        running = true; progress = 0; result = nil; lastRoots = []
        var copied = 0, skipped = 0, failed = 0, errors: [String] = []
        let total = blocks.count

        func next(_ i: Int) {
            guard i < blocks.count else {
                running = false
                if failed > 0 {
                    result = (false, "\(failed) file(s) FAILED — do not format this card.\n" + errors.joined(separator: "\n"))
                } else if result == nil {
                    progress = 1
                    result = (true, "Done. \(copied) files copied and checksum-verified on \(dests.count) drive(s)"
                              + (skipped > 0 ? ", \(skipped) were already offloaded." : "."))
                }
                record()
                processNext()
                return
            }
            var args = ["copy", "--source", src.path, "--from", blocks[i].0, "--to", blocks[i].1,
                        "--day-start-hour", String(dayStartHour)]
            if !label.isEmpty { args += ["--label", label] }
            for d in dests { args += ["--dest", d.path] }
            run(args, onEvent: { e in
                switch e["type"] as? String {
                case "plan":
                    self.lastRoots += e["dests"] as? [String] ?? []
                    let n = e["to_copy"] as? Int ?? 0, done = e["already_done"] as? Int ?? 0
                    self.status = "Copying \(n) files" + (done > 0 ? " (\(done) already offloaded, skipping)" : "")
                case "progress":
                    let d = (e["done"] as? NSNumber)?.doubleValue ?? 0, t = (e["total"] as? NSNumber)?.doubleValue ?? 1
                    self.progress = (Double(i) + d / t) / Double(total)
                    let phase = (e["phase"] as? String) == "verify" ? "Verifying" : "Copying"
                    let eta = (e["eta"] as? Int).map { " · \($0 / 60)m \($0 % 60)s left" } ?? ""
                    self.status = "\(phase) \(e["file"] as? String ?? "") · \(e["mbps"] ?? 0) MB/s\(eta)"
                case "done":
                    copied += e["copied"] as? Int ?? 0
                    skipped += e["skipped"] as? Int ?? 0
                    failed += e["failed"] as? Int ?? 0
                    errors += e["errors"] as? [String] ?? []
                case "error":
                    self.result = (false, e["message"] as? String ?? "Error")
                default: break
                }
            }, onExit: { code in
                if code != 0 && self.result == nil && failed == 0 {
                    self.result = (false, "Offload stopped (code \(code)).")
                }
                if self.result?.ok == false && failed == 0 {
                    self.running = false; self.record(); self.processNext(); return
                }
                next(i + 1)
            })
        }
        next(0)
    }

    func cancel() { proc?.terminate() }

    func compare() {
        guard let office = officeDir, !shootDirs.isEmpty else { return }
        comparing = true; progress = 0; status = "Reading checksum lists…"
        compareCards = []; compareProblems = []; notInOffice = []; compareSummary = nil
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        let report = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Day Offload Reports/compare_\(f.string(from: Date())).txt").path
        var args = ["compare", "--office", office.path, "--report", report]
        for d in shootDirs { args += ["--shoot", d.path] }
        if reread { args.append("--reread") }
        run(args, onEvent: { e in
            switch e["type"] as? String {
            case "compare_plan":
                let n = e["to_read"] as? Int ?? 0, all = e["shoot_files"] as? Int ?? 0
                let b = (e["bytes"] as? NSNumber)?.int64Value ?? 0
                self.status = n > 0 ? "Checking \(all) shoot files — reading \(n) (\(gb(b))) from disk…" : "Comparing checksums…"
            case "progress":
                let d = (e["done"] as? NSNumber)?.doubleValue ?? 0, t = (e["total"] as? NSNumber)?.doubleValue ?? 1
                self.progress = d / t
                let eta = (e["eta"] as? Int).map { " · \($0 / 60)m \($0 % 60)s left" } ?? ""
                self.status = "Reading \(e["file"] as? String ?? "") · \(e["mbps"] ?? 0) MB/s\(eta)"
            case "compare_done":
                let cards = e["cards"] as? [[String: Any]] ?? []
                self.compareCards = cards.map {
                    CompareCard(card: $0["card"] as? String ?? "", days: $0["days"] as? [String] ?? [],
                                files: $0["files"] as? Int ?? 0, match: $0["match"] as? Int ?? 0,
                                different: $0["different"] as? Int ?? 0, missing: $0["missing"] as? Int ?? 0,
                                unreadable: $0["unreadable"] as? Int ?? 0, inOffice: $0["in_office"] as? Bool ?? false,
                                onlyInOffice: $0["only_in_office"] as? Int ?? 0,
                                officeCard: $0["office_card"] as? String, officeDir: $0["office_dir"] as? String,
                                shootDirs: $0["shoot_dirs"] as? [String] ?? [],
                                stow: $0["stow"] as? Bool ?? true)
                }
                self.compareProblems = (e["problems"] as? [[String: Any]] ?? []).map {
                    CompareProblem(card: $0["card"] as? String ?? "", day: $0["day"] as? String ?? "",
                                   file: $0["file"] as? String ?? "", status: $0["status"] as? String ?? "",
                                   shootCopy: $0["shoot_copy"] as? String, officeCopy: $0["office_copy"] as? String,
                                   proxy: $0["proxy"] as? Bool ?? false)
                }
                self.notInOffice = (e["not_in_office"] as? [[String: Any]] ?? []).map {
                    MissingGroup(dir: $0["dir"] as? String ?? "", count: $0["count"] as? Int ?? 0,
                                 bytes: ($0["bytes"] as? NSNumber)?.int64Value ?? 0,
                                 proxy: $0["proxy"] as? Bool ?? false,
                                 files: ($0["files"] as? [[String: Any]] ?? []).map {
                                     (name: $0["name"] as? String ?? "", size: ($0["size"] as? NSNumber)?.int64Value ?? 0,
                                      path: $0["path"] as? String ?? "")
                                 })
                }
                self.reportPath = e["report"] as? String
                let total = e["total"] as? Int ?? 0, matched = e["matched"] as? Int ?? 0
                let n = e["problem_count"] as? Int ?? 0, px = e["proxy_only"] as? Int ?? 0
                let pxNote = px > 0 ? " (\(px) proxy files exist only on the shoot drive — see below.)" : ""
                self.compareSummary = n == 0
                    ? (true, "All \(matched) footage files in the shoot folder are identical in the office backup." + pxNote)
                    : (false, "\(matched) of \(total) shoot files are identical. \(n) file(s) need checking (listed below) — don't format these cards yet.")
            case "error":
                self.compareSummary = (false, e["message"] as? String ?? "Compare failed")
            default: break
            }
        }, onExit: { _ in
            self.comparing = false
            if self.compareSummary == nil { self.compareSummary = (false, "Compare stopped.") }
        })
    }
}


// MARK: - Liquid Glass on macOS 26+, frosted material on macOS 14–15

extension View {
    @ViewBuilder func glassPanel(tint: Color?, cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            background {
                RoundedRectangle(cornerRadius: cornerRadius).fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill(tint ?? .clear))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.12)))
            }
        }
    }
    @ViewBuilder func glassCapsule(tint: Color?) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: .capsule)
        } else {
            background(Capsule().fill(.regularMaterial).overlay(Capsule().fill(tint ?? .clear)))
        }
    }
    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }
    @ViewBuilder func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}

struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 14) { content } } else { content }
    }
}

// MARK: - Views (Liquid Glass)

/// Soft colour wash behind the glass so the panels have something to refract.
struct Backdrop: View {
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.06, green: 0.08, blue: 0.14), Color(red: 0.10, green: 0.07, blue: 0.16)]
                                        : [Color(red: 0.90, green: 0.93, blue: 0.98), Color(red: 0.95, green: 0.92, blue: 0.97)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.cyan.opacity(dark ? 0.28 : 0.35)).frame(width: 420).blur(radius: 120).offset(x: -200, y: -260)
            Circle().fill(Color.purple.opacity(dark ? 0.30 : 0.25)).frame(width: 380).blur(radius: 120).offset(x: 230, y: 40)
            Circle().fill(Color.orange.opacity(dark ? 0.16 : 0.20)).frame(width: 320).blur(radius: 110).offset(x: -120, y: 380)
        }
        .ignoresSafeArea()
    }
}

/// One glass panel with an SF Symbol heading.
/// Chevron that turns to show whether a section is open.
struct FoldChevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
            .rotationEffect(.degrees(open ? 90 : 0))
    }
}

/// One glass panel with an SF Symbol heading. Click the heading to fold it up;
/// the open/closed state is remembered between launches.
struct Card<Content: View>: View {
    let title: String, symbol: String
    var tint: Color?
    var summary: String?
    @AppStorage var folded: Bool
    let content: Content

    init(title: String, symbol: String, tint: Color? = nil, summary: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.summary = summary
        self._folded = AppStorage(wrappedValue: false, "folded." + title)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { folded.toggle() } } label: {
                HStack {
                    Label(title, systemImage: symbol).font(.headline).symbolRenderingMode(.hierarchical)
                    if folded, let summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    FoldChevron(open: !folded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !folded { content }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(tint: tint, cornerRadius: 22)
    }
}

/// A foldable sub-section inside a panel (used in the Compare results).
struct Fold<Content: View>: View {
    let title: String, symbol: String
    var color: Color = .primary
    @AppStorage var open: Bool
    let content: Content

    init(_ title: String, symbol: String, key: String, color: Color = .primary, openByDefault: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.color = color
        self._open = AppStorage(wrappedValue: openByDefault, "open." + key)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack {
                    Label(title, systemImage: symbol).font(.subheadline.bold()).foregroundStyle(color)
                    Spacer()
                    FoldChevron(open: open)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content }
        }
    }
}

struct DestinationList: View {
    @ObservedObject var m: Model
    var body: some View {
        ForEach(m.dests, id: \.self) { d in
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                Text(d.path).lineLimit(1).truncationMode(.middle)
                if !m.isDemo && !FileManager.default.fileExists(atPath: d.path) {
                    Text("not connected").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button { m.dests.removeAll { $0 == d } } label: { Image(systemName: "xmark") }
                    .glassButton().buttonBorderShape(.circle).controlSize(.small)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12))
        }
        Button {
            if let u = m.pickFolder("Choose a project folder on a drive"), !m.dests.contains(u) { m.dests.append(u) }
        } label: { Label("Add destination", systemImage: "plus") }
            .glassButton()
    }
}

/// "Files go to" — every final folder, so it's clear where this offload lands.
struct PlannedFolders: View {
    @ObservedObject var m: Model
    var body: some View {
        let folders = m.plannedFolders
        if !folders.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Files go to").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(folders, id: \.self) { f in
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.caption2).foregroundStyle(.secondary)
                        Text(f).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                            .textSelection(.enabled).help(f)
                    }
                }
            }
        }
    }
}

struct CompareView: View {
    @ObservedObject var m: Model

    func folderRow(_ url: URL, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text(url.path).lineLimit(1).truncationMode(.middle)
            if !m.isDemo && !FileManager.default.fileExists(atPath: url.path) {
                Text("not connected").font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Button(action: remove) { Image(systemName: "xmark") }
                .glassButton().buttonBorderShape(.circle).controlSize(.small)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    var body: some View {
        Card(title: "Shoot copies (Day Offload)", symbol: "calendar.badge.checkmark",
             summary: m.shootDirs.map(\.lastPathComponent).joined(separator: ", ")) {
            Text("The project folder you offloaded to on the shoot — the one holding the date folders.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(m.shootDirs, id: \.self) { d in folderRow(d) { m.shootDirs.removeAll { $0 == d } } }
            HStack {
                Button { if let u = m.pickFolder("Choose the shoot offload folder"), !m.shootDirs.contains(u) { m.shootDirs.append(u) } }
                    label: { Label("Add folder", systemImage: "plus") }.glassButton()
                if m.shootDirs.isEmpty, !m.dests.isEmpty {
                    Button("Use my offload destinations") { m.shootDirs = m.dests }.glassButton()
                }
            }
        }

        Card(title: "Office backup (Stow)", symbol: "building.2", summary: m.officeDir?.lastPathComponent) {
            Text("The folder holding the card folders Stow made — each has a _verification folder inside.")
                .font(.caption).foregroundStyle(.secondary)
            if let o = m.officeDir { folderRow(o) { m.officeDir = nil } }
            Button { if let u = m.pickFolder("Choose the Stow backup folder") { m.officeDir = u } }
                label: { Label(m.officeDir == nil ? "Choose folder" : "Change folder", systemImage: "folder") }
                .glassButton()
        }

        Toggle(isOn: $m.reread) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Also re-read the shoot copies from disk")
                Text("Slower. Catches a shoot drive that has gone bad since the offload.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch).padding(.horizontal, 4)

        if m.comparing {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(Int(m.progress * 100))%").font(.title2.monospacedDigit().bold())
                    Spacer()
                    Button("Cancel", role: .cancel) { m.cancel() }.glassButton()
                }
                ProgressView(value: m.progress).tint(.accentColor)
                Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("Checksums are remembered — if this stops, running it again picks up where it left off.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .glassPanel(tint: .accentColor.opacity(0.15), cornerRadius: 22)
        } else {
            Button { m.compare() } label: {
                Label("Compare", systemImage: "checkmark.shield.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .glassProminentButton().controlSize(.extraLarge)
            .disabled(m.officeDir == nil || m.shootDirs.isEmpty)
        }

        if let r = m.compareSummary {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: r.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title2).foregroundStyle(r.ok ? .green : .red)
                    Text(r.text).font(.headline)
                    Spacer()
                    if let p = m.reportPath, FileManager.default.fileExists(atPath: p) {
                        Button("Open report") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }.glassButton()
                    }
                }
                let allOK = m.compareCards.allSatisfy(\.ok)
                Fold("Cards (\(m.compareCards.count))" + (allOK ? " — all identical" : ""),
                     symbol: allOK ? "checkmark.circle" : "rectangle.stack", key: "cmp.cards") {
                ForEach(m.compareCards) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(c.ok ? .green : .red)
                            Text(c.card).bold()
                            Text(c.days.map(prettyDay).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(c.inOffice ? "\(c.match)/\(c.files) identical" : "not in office backup")
                                    .monospacedDigit().foregroundStyle(c.ok ? Color.primary : Color.red)
                                if c.stow && c.onlyInOffice > 0 {
                                    Text("+\(c.onlyInOffice) on office copy only").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !c.stow {
                            Text("No Stow checksums here (copied another way) — both copies were read and compared.")
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                        }
                        if let oc = c.officeCard, oc != c.card {
                            Text("Named \(oc) in the office backup — matched by its files.")
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                        }
                        HStack(spacing: 6) {
                            ForEach(c.shootDirs, id: \.self) { d in
                                Button { revealInFinder(d) } label: { Label("Shoot copy", systemImage: "folder") }
                                    .help(d)
                            }
                            if let od = c.officeDir {
                                Button { revealInFinder(od) } label: { Label("Office copy", systemImage: "building.2") }
                                    .help(od)
                            }
                        }
                        .glassButton().controlSize(.small).padding(.leading, 24)
                    }
                }
                }
                let realMissing = m.notInOffice.filter { !$0.proxy }, proxyOnly = m.notInOffice.filter(\.proxy)
                if !realMissing.isEmpty {
                    Divider()
                    Label("On the shoot drive but not in the office backup", systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline.bold()).foregroundStyle(.red)
                    ForEach(realMissing) { g in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                                Text(g.dir).font(.caption.bold()).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text("\(g.count) file(s) · \(gb(g.bytes))").font(.caption).monospacedDigit()
                                Button { revealInFinder(g.dir) } label: { Image(systemName: "arrow.up.forward.app") }
                                    .buttonStyle(.borderless).help("Open this folder in Finder")
                            }
                            ForEach(g.files, id: \.path) { f in
                                HStack {
                                    Image(systemName: "doc").font(.caption2).foregroundStyle(.red)
                                    Text(f.name).font(.caption.monospaced()).textSelection(.enabled)
                                    Spacer()
                                    Text(String(format: "%.0f MB", Double(f.size) / 1e6)).font(.caption).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Button { revealInFinder(f.path) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless).help("Show this file in Finder")
                                }
                                .padding(.leading, 22)
                            }
                            if g.count > g.files.count {
                                Text("…and \(g.count - g.files.count) more — see the report").font(.caption2)
                                    .foregroundStyle(.secondary).padding(.leading, 22)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if !proxyOnly.isEmpty {
                    Divider()
                    Fold("Proxy folders only on the shoot drive (\(proxyOnly.count))", symbol: "info.circle",
                         key: "cmp.proxies", color: .secondary, openByDefault: false) {
                    Text("Usually proxies made on the computer during the shoot, so they were never on the card. Keep them if you need them.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(proxyOnly) { g in
                        HStack {
                            Text("\(g.count) file(s) · \(gb(g.bytes))").font(.caption).monospacedDigit()
                                .frame(width: 120, alignment: .leading)
                            Text(g.dir).font(.caption).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button { revealInFinder(g.dir) } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless).help(g.dir)
                        }
                    }
                    }
                }
                if m.compareProblems.contains(where: { !$0.proxy && $0.status != "missing" }) {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(m.compareProblems.filter { !$0.proxy && $0.status != "missing" }) { p in
                                HStack {
                                    Text(p.status == "missing" ? "missing" : p.status == "card_missing" ? "no card" : p.status)
                                        .font(.caption.bold()).foregroundStyle(.red).frame(width: 70, alignment: .leading)
                                    Text("\(p.card)/\(p.file)").font(.caption).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if let sc = p.shootCopy {
                                        Button { revealInFinder(sc) } label: { Image(systemName: "folder") }
                                            .help("Shoot copy: \(sc)")
                                    }
                                    if let oc = p.officeCopy {
                                        Button { revealInFinder(oc) } label: { Image(systemName: "building.2") }
                                            .help("Office copy (where it should be): \(oc)")
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }.frame(maxHeight: 140)
                }
            }
            .padding(14)
            .glassPanel(tint: (r.ok ? Color.green : Color.red).opacity(0.2), cornerRadius: 18)
        }
    }
}

/// Shown at the top when a card goes in: what's ready, and one-press Offload.
struct ArrivalNote: View {
    @ObservedObject var m: Model
    var destsMissing: Bool {
        !m.isDemo && (m.dests.isEmpty || m.dests.contains { !FileManager.default.fileExists(atPath: $0.path) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sdcard.fill").font(.system(size: 26)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(m.arrived ?? m.label) just went in").font(.headline)
                    Text(m.chosen.isEmpty ? "Tick the days to copy below."
                         : "\(fileCount(m.chosenFiles)) · \(gb(m.chosenBytes)) ready from "
                           + m.chosen.map(\.day).sorted().map(prettyDay).joined(separator: ", "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { m.skip() } label: { Image(systemName: "xmark") }
                    .glassButton().buttonBorderShape(.circle).controlSize(.small)
                    .help(m.queue.isEmpty ? "Dismiss" : "Skip this card and go to the next one")
            }
            if let d = m.todayFallbackDay {
                Label("Nothing from today — showing \(prettyDay(d))", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !m.queue.isEmpty {
                Label("Next: " + m.queue.map(\.lastPathComponent).joined(separator: ", "), systemImage: "tray.full")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if m.dests.isEmpty {
                Label("Add a backup drive below first.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if destsMissing {
                Label("A backup drive isn't connected.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("Card name").font(.callout).foregroundStyle(.secondary)
                TextField("A001", text: $m.label).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            PlannedFolders(m: m)
            HStack {
                Text("Check the card name and folders, then:").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { m.offload() } label: { Label("Offload", systemImage: "arrow.down.doc.fill") }
                    .glassProminentButton().controlSize(.large)
                    .disabled(m.chosen.isEmpty || destsMissing)
            }
        }
        .padding(16)
        .glassPanel(tint: .accentColor.opacity(0.18), cornerRadius: 22)
    }
}

struct ContentView: View {
    @StateObject var m = Model()

    var body: some View {
        VStack(spacing: 0) {
            // Pinned: the title and tabs never scroll away under the window buttons.
            VStack(alignment: .leading, spacing: 14) {
                header
                Picker("", selection: $m.mode) {
                    Label("Offload", systemImage: "arrow.down.doc").tag(Mode.offload)
                    Label("Compare with office backup", systemImage: "checkmark.shield").tag(Mode.compare)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)

        ScrollView {
        GlassGroup {
            VStack(alignment: .leading, spacing: 14) {

                if m.mode == .compare {
                    CompareView(m: m)
                } else {

                if m.arrived != nil { ArrivalNote(m: m) }

                Card(title: "Shoot dates", symbol: "calendar", summary: m.autoOn ? m.rangeText : "off") {
                    Toggle("When a card goes in, open Day Offload and ask where to back up", isOn: $m.cardAssist)
                        .toggleStyle(.switch)
                    Toggle("Only while the app is open", isOn: $m.onlyWhileOpen)
                        .toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
                        .disabled(!m.autoOn)
                        .help("Don't open Day Offload by itself — only ask when it's already open.")
                    HStack(spacing: 10) {
                        Picker("", selection: $m.useToday) {
                            Text("Today").tag(true)
                            Text("Date range").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        HStack(spacing: 6) {
                            Text("From")
                            DatePicker("From", selection: $m.rangeFrom, displayedComponents: .date).labelsHidden()
                            Text("to")
                            DatePicker("to", selection: $m.rangeTo, displayedComponents: .date).labelsHidden()
                        }
                        .fixedSize()
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Button { m.queueAllMounted() } label: { Label("Check all cards", systemImage: "sdcard.fill") }
                            .glassButton().disabled(!m.autoOn || m.busy)
                    }
                }

                Card(title: "Card", symbol: "sdcard", summary: m.source?.lastPathComponent) {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(get: { m.source }, set: { m.choose($0) })) {
                            Text("Choose a card…").tag(URL?.none)
                            ForEach(m.volumes, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                            if let s = m.source, !m.volumes.contains(s) { Text(s.path).tag(URL?.some(s)) }
                        }.labelsHidden().fixedSize()
                        Button("Folder…") { if let u = m.pickFolder("Choose the card or card folder") { m.choose(u) } }
                            .glassButton()
                        Button { m.refreshVolumes() } label: { Image(systemName: "arrow.clockwise") }
                            .glassButton().buttonBorderShape(.circle)
                        Spacer()
                        if m.source != nil && !m.running {
                            Button("Not a card") { m.notACard() }
                                .glassButton().controlSize(.small)
                                .help("This is a backup drive, not a camera card. Don't offer it again.")
                        }
                    }
                    daysList
                }

                Card(title: "Back up to (copied to each)", symbol: "externaldrive.badge.plus",
                     summary: m.dests.isEmpty ? "none set" : m.dests.map(\.lastPathComponent).joined(separator: ", ")) {
                    DestinationList(m: m)
                    HStack {
                        Text("Card name").foregroundStyle(.secondary)
                        TextField("A001", text: $m.label).textFieldStyle(.roundedBorder).frame(width: 150)
                        if m.plannedFolders.isEmpty {
                            Text("→ …/<date>/\(m.label.isEmpty ? "CARD" : m.label)/").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    PlannedFolders(m: m)
                }

                actionArea

                if !m.history.isEmpty {
                    Card(title: "Offloaded this session", symbol: "checklist") {
                        ForEach(m.history) { h in
                            HStack(alignment: .top) {
                                Image(systemName: h.info ? "info.circle.fill" : h.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(h.info ? Color.secondary : h.ok ? Color.green : Color.red)
                                Text(h.card).bold()
                                Text(h.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }

                Label("The card is only read — nothing on it is changed or deleted.", systemImage: "lock.fill")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 2)
        }
        }
        .scrollIndicators(.automatic)
        }
        .frame(width: 600)
        .frame(minHeight: 420, idealHeight: 820)
        .background(Backdrop())
        .task {
            // Opened by the card watcher (or with cards already in): go straight to them.
            if m.autoOn && !m.isDemo { m.queueAllMounted() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { n in
            if let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { m.cardMounted(url) }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { n in
            m.cardUnmounted(n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square.fill")
                .font(.system(size: 26)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Day Offload").font(.title.bold())
                HStack(spacing: 6) {
                    Text("Copy only the shoot days you choose").font(.callout).foregroundStyle(.secondary)
                    Link("v\(AppInfo.version)", destination: URL(string: AppInfo.repo)!)
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !m.queue.isEmpty {
                Label("\(m.queue.count) waiting", systemImage: "tray.full.fill")
                    .font(.callout).padding(.vertical, 6).padding(.horizontal, 12)
                    .glassCapsule(tint: .orange.opacity(0.3))
                    .help(m.queue.map(\.lastPathComponent).joined(separator: ", "))
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder var daysList: some View {
        Text(m.autoOn ? "Days with footage on this card. Days inside your shoot dates are ticked and will be copied."
                      : "Days with footage on this card. Tick the ones to copy.")
            .font(.caption).foregroundStyle(.secondary)
        if m.scanning {
            ProgressView().controlSize(.small)
        } else if m.days.isEmpty {
            Text(m.source == nil ? "Insert or pick a card." : "No clips found.").foregroundStyle(.secondary)
        } else {
            VStack(spacing: 6) {
                ForEach(m.days) { d in
                    let on = m.selectedDays.contains(d.day)
                    Button {
                        if on { m.selectedDays.remove(d.day) } else { m.selectedDays.insert(d.day) }
                    } label: {
                        HStack {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .font(.title3)
                            Text(prettyDay(d.day)).fontWeight(on ? .semibold : .regular)
                            Spacer()
                            Text("\(fileCount(d.files)) · \(gb(d.bytes))").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.vertical, 7).padding(.horizontal, 12)
                        .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
                        .contentShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .animation(.snappy, value: on)
                }
            }
        }
        Stepper("Day starts at \(String(format: "%02d:00", m.dayStartHour)) — earlier clips count as the previous day",
                value: $m.dayStartHour, in: 0...12).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder var actionArea: some View {
        if m.running {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(Int(m.progress * 100))%").font(.title2.monospacedDigit().bold())
                    Spacer()
                    Button("Cancel", role: .cancel) { m.cancel() }.glassButton()
                }
                ProgressView(value: m.progress).tint(.accentColor)
                Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(16)
            .glassPanel(tint: .accentColor.opacity(0.15), cornerRadius: 22)
        } else {
            Button { m.offload() } label: {
                Label(m.chosen.isEmpty ? "Offload" : "Offload \(fileCount(m.chosenFiles)) · \(gb(m.chosenBytes))",
                      systemImage: "arrow.down.doc.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .glassProminentButton().controlSize(.extraLarge)
            .disabled(m.chosen.isEmpty || m.dests.isEmpty)
        }

        if let r = m.result {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: r.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title3).foregroundStyle(r.ok ? .green : .red)
                Text(r.text).textSelection(.enabled)
                Spacer()
                if r.ok, let first = m.lastRoots.first {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: first)) }.glassButton()
                }
            }
            .padding(14)
            .glassPanel(tint: (r.ok ? Color.green : Color.red).opacity(0.25), cornerRadius: 18)
        }
    }
}

@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "--engine" {
            exit(Engine.main(Array(args.dropFirst(2))))
        } else if args.contains("--mount-check") {
            mountCheck()
        } else {
            DayOffloadApp.main()
        }
    }
}

struct DayOffloadApp: App {
    var body: some Scene {
        WindowGroup("Day Offload") { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
            .defaultSize(width: 600, height: 820)
    }
}
