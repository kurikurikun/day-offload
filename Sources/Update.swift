// Update check: GitHub Releases, on launch and once a day. Public API, no
// login, fails silently when offline. "Update now" downloads the release,
// installs it only if it's signed by our Apple team, swaps it into place and
// relaunches. Same approach as Peripheral Speed.

import Foundation
import Security

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latest: (version: String, url: String)?
    @Published var updating = false
    @Published var updateError: String?

    private var timer: Timer?
    nonisolated static let releasesAPI = "https://api.github.com/repos/kurikurikun/day-offload/releases/latest"
    nonisolated static let downloadURL = "https://github.com/kurikurikun/day-offload/releases/latest/download/DayOffload.zip"
    nonisolated static let teamID = "PNDN4CQY5T"
    nonisolated static let appName = "Day Offload.app"

    func start() {
        check()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        guard let url = URL(string: Self.releasesAPI) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let html = obj["html_url"] as? String else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(version, than: AppInfo.version) else { return }
            Task { @MainActor in self?.latest = (version, html) }
        }.resume()
    }

    /// Download, verify, swap, relaunch. Any failure leaves the current app as it is.
    func installUpdate() {
        guard !updating else { return }
        updating = true
        updateError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = Self.performUpdate()
            Task { @MainActor in
                self?.updating = false
                self?.updateError = error   // on success the app has already quit
            }
        }
    }

    nonisolated static func performUpdate() -> String? {
        let currentPath = Bundle.main.bundlePath
        guard currentPath.hasSuffix(appName) else { return "Not running from an installed app — update from the website." }

        guard let url = URL(string: downloadURL) else { return "Bad update address." }
        let sem = DispatchSemaphore(value: 0)
        var zipData: Data?
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { zipData = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 180)
        guard let zipData, zipData.count > 100_000 else { return "Couldn't download the update — check your connection." }

        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doupdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zipPath = work.appendingPathComponent("update.zip")
        do { try zipData.write(to: zipPath) } catch { return "Couldn't save the update." }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", zipPath.path, work.path]
        try? unzip.run()
        unzip.waitUntilExit()
        let newApp = work.appendingPathComponent(appName)
        guard FileManager.default.fileExists(atPath: newApp.path) else { return "The update package looked wrong — not installed." }

        // Valid signature AND our Developer ID team, or we refuse.
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return "Couldn't check the update's signature." }
        var requirement: SecRequirement?
        let req = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"" as CFString
        guard SecRequirementCreateWithString(req, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { return "The update failed its signature check — not installed." }

        let staged = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("donew-\(UUID().uuidString).app")
        do { try FileManager.default.moveItem(at: newApp, to: staged) } catch { return "Couldn't stage the update." }

        // A detached shell swaps the app after we quit (a running app can't
        // replace itself in /Applications), then relaunches it.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf \(shellQuote(currentPath))
        /bin/mv \(shellQuote(staged.path)) \(shellQuote(currentPath))
        /usr/bin/xattr -dr com.apple.quarantine \(shellQuote(currentPath)) 2>/dev/null
        /usr/bin/open -n \(shellQuote(currentPath))
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run() } catch { return "Couldn't start the update helper." }
        DispatchQueue.main.async { exit(0) }
        return nil
    }

    nonisolated static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
