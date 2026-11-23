import AppKit
import Combine
import CryptoKit
import Foundation

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    static func version(_ value: String) -> [Int]? {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let a = version(candidate), let b = version(installed) else { return false }
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : 0, right = i < b.count ? b[i] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// The repository's names: rexamp was renamed rexnotch, and GitHub serves
    /// release assets under the current name.
    static let repositoryPaths = ["/chrisdmacrae/rexnotch/", "/chrisdmacrae/rexamp/"]

    func asset(named name: String) throws -> URL {
        guard let url = assets.first(where: { $0.name == name })?.browser_download_url,
              url.scheme == "https", url.host == "github.com",
              Self.repositoryPaths.contains(where: { url.path.hasPrefix($0 + "releases/download/") }) else {
            throw UpdateError("The release is missing a trusted \(name) asset.")
        }
        return url
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Uses the same universal app and SHA-256 manifest as the release installer.
enum ReleaseInstaller {
    static let assetName = "RexNotch_macos_universal.zip"

    static func verify(archive: Data, manifest: String) throws {
        let hashes = manifest.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == assetName || fields[1] == "*" + assetName else { return nil }
            return String(fields[0]).lowercased()
        }
        let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard hashes.count == 1, hashes[0] == actual else { throw UpdateError("The downloaded update failed its SHA-256 checksum. Nothing was installed.") }
    }

    static func stage(archive: Data, manifest: String, version: String, destination: URL) throws -> URL {
        try verify(archive: archive, manifest: manifest)
        let fm = FileManager.default
        guard destination.pathExtension == "app", fm.isWritableFile(atPath: destination.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: destination.path), !destination.path.hasPrefix("/Volumes/") else {
            throw UpdateError("Move RexNotch to a writable Applications folder before updating.")
        }
        // Stage on the destination volume so renaming the bundles is atomic.
        let work = destination.deletingLastPathComponent().appendingPathComponent(".rexnotch-update-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        do {
            let zip = work.appendingPathComponent("release.zip")
            try archive.write(to: zip)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let app = work.appendingPathComponent("RexNotch.app")
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.chrisdmacrae.rexnotch",
                  let actualVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  GitHubRelease.version(actualVersion) == GitHubRelease.version(version),
                  fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/RexNotch").path),
                  fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/amp-rex-hud").path) else {
                throw UpdateError("The update is not the expected RexNotch app and version.")
            }
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            return work
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    static func run(_ command: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("Update verification failed (\((command as NSString).lastPathComponent)): \(detail). Nothing was installed.") }
    }

    /// The helper outlives this process, waits for it to exit, then swaps and
    /// relaunches the app. It restores the old bundle if replacement/open fails.
    static func replacementProcess(work: URL, destination: URL, report: URL, parentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                                   launcher: String = "/usr/bin/open") -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
        pid="$1"; work="$2"; target="$3"; report="$4"; launcher="$5"
        count=0
        while kill -0 "$pid" 2>/dev/null; do
            count=$((count + 1))
            if [ "$count" -ge 60 ]; then
                printf '%s' 'Update cancelled because RexNotch did not exit.' > "$report"
                rm -rf "$work"
                exit 1
            fi
            sleep 1
        done
        if ! mv "$target" "$work/Previous.app"; then
            printf '%s' 'Could not replace RexNotch. The original app is unchanged.' > "$report"
            rm -rf "$work"
            exit 1
        fi
        if mv "$work/RexNotch.app" "$target" && "$launcher" -n "$target"; then
            rm -rf "$work"
        else
            if [ -e "$target" ]; then mv "$target" "$work/Failed.app"; fi
            if mv "$work/Previous.app" "$target"; then
                printf '%s' 'The update could not be launched. The previous RexNotch was restored.' > "$report"
                "$launcher" -n "$target"
                rm -rf "$work"
            else
                printf 'Restore the previous app from %s/Previous.app.' "$work" > "$report"
            fi
            exit 1
        fi
        """, "rexnotch-update", String(parentPID), work.path, destination.path, report.path, launcher]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var status = "Not checked yet"
    @Published private(set) var lastChecked: Date?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var preferenceSubscription: AnyCancellable?
    private let session: URLSession
    private let bundleURL: URL
    private let installedVersion: String
    private let report: URL

    init(session: URLSession = .shared, bundleURL: URL = Bundle.main.bundleURL,
         installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.session = session
        self.bundleURL = bundleURL
        self.installedVersion = installedVersion
        report = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RexNotch/update-error.txt")
    }

    func start(settings: Settings) {
        var skipStartupCheck = false
        if let error = try? String(contentsOf: report, encoding: .utf8) {
            status = error
            skipStartupCheck = true // Don't immediately reinstall a release that just failed to launch.
            try? FileManager.default.removeItem(at: report)
        }
        preferenceSubscription = settings.$values.map(\.automaticUpdates).removeDuplicates().sink { [weak self] enabled in
            defer { skipStartupCheck = false }
            self?.timer?.invalidate()
            self?.timer = nil
            if enabled {
                if !skipStartupCheck { self?.check() }
                self?.timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.check() }
                }
            } else {
                self?.task?.cancel()
            }
        }
    }

    func stop() { timer?.invalidate(); task?.cancel() }

    func check() {
        guard !active else { return }
        guard bundleURL.pathExtension == "app", GitHubRelease.version(installedVersion) != nil else {
            status = "Updates require a versioned RexNotch.app bundle."
            return
        }
        active = true
        status = "Checking for updates…"
        task = Task {
            var staged: URL?
            defer {
                if let staged { try? FileManager.default.removeItem(at: staged) }
                active = false
                task = nil
            }
            do {
                let metadata = try await fetch(URL(string: "https://api.github.com/repos/chrisdmacrae/rexamp/releases/latest")!)
                let release = try JSONDecoder().decode(GitHubRelease.self, from: metadata)
                lastChecked = Date()
                guard !release.draft, !release.prerelease, GitHubRelease.isNewer(release.tag_name, than: installedVersion) else {
                    status = "RexNotch is up to date (\(installedVersion))."
                    return
                }
                let archiveURL = try release.asset(named: ReleaseInstaller.assetName)
                let checksumsURL = try release.asset(named: "checksums.txt")
                status = "Downloading \(release.tag_name)…"
                let manifest = try await fetch(checksumsURL)
                let archive = try await fetch(archiveURL)
                try Task.checkCancellation()
                status = "Verifying \(release.tag_name)…"
                let destination = bundleURL
                let work = try await Task.detached {
                    try ReleaseInstaller.stage(archive: archive, manifest: String(decoding: manifest, as: UTF8.self),
                                               version: release.tag_name, destination: destination)
                }.value
                staged = work
                try Task.checkCancellation()
                status = "Installing \(release.tag_name)…"
                try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
                let helper = ReleaseInstaller.replacementProcess(work: work, destination: bundleURL, report: report)
                try helper.run()
                staged = nil // The helper now owns staging and cleanup.
                NSApp.terminate(nil)
            } catch is CancellationError {
                status = "Update cancelled."
            } catch {
                status = "Update failed: \(error.localizedDescription)"
            }
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("RexNotch/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateError(code == 404 ? "No published release is available yet." : "GitHub returned HTTP \(code). Try again later.")
        }
        return data
    }
}
