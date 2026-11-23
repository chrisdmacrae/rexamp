import AppKit
import CryptoKit
import XCTest
@testable import RexNotch

final class UpdaterTests: XCTestCase {
    func testVersionsNeverDowngradeOrInstallPrereleaseTags() {
        XCTAssertTrue(GitHubRelease.isNewer("v0.10.0", than: "0.9.9"))
        XCTAssertTrue(GitHubRelease.isNewer("v1.0.1", than: "1"))
        XCTAssertFalse(GitHubRelease.isNewer("v0.1.0", than: "0.1"))
        XCTAssertFalse(GitHubRelease.isNewer("v1.9", than: "1.10"))
        XCTAssertFalse(GitHubRelease.isNewer("v2.0-beta.1", than: "1.0"))
        XCTAssertFalse(GitHubRelease.isNewer("v2.0", than: "development"))
    }

    func testChecksumRejectsCorruptionMissingAndDuplicateEntries() throws {
        let archive = Data("abc".utf8)
        // Published SHA-256 test vector, independent of the implementation.
        let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let manifest = "\(hash)  RexNotch_macos_universal.zip\n"
        XCTAssertNoThrow(try ReleaseInstaller.verify(archive: archive, manifest: manifest))
        XCTAssertThrowsError(try ReleaseInstaller.verify(archive: Data("abd".utf8), manifest: manifest))
        XCTAssertThrowsError(try ReleaseInstaller.verify(archive: archive, manifest: "\(hash)  other.zip"))
        XCTAssertThrowsError(try ReleaseInstaller.verify(archive: archive, manifest: manifest + manifest))
    }

    func testReleaseAssetMustComeFromThisRepository() throws {
        let release = GitHubRelease(tag_name: "v1.0", draft: false, prerelease: false, assets: [
            .init(name: ReleaseInstaller.assetName, browser_download_url: URL(string: "https://github.com/other/repo/releases/download/v1/app.zip")!),
        ])
        XCTAssertThrowsError(try release.asset(named: ReleaseInstaller.assetName))
        XCTAssertThrowsError(try release.asset(named: "checksums.txt"))
    }

    func testReleaseAssetFromRenamedRepository() throws {
        for repo in ["rexnotch", "rexamp"] {
            let release = GitHubRelease(tag_name: "v1.0", draft: false, prerelease: false, assets: [
                .init(name: ReleaseInstaller.assetName, browser_download_url: URL(string: "https://github.com/chrisdmacrae/\(repo)/releases/download/v1/app.zip")!),
            ])
            XCTAssertNoThrow(try release.asset(named: ReleaseInstaller.assetName), repo)
        }
        let lookalike = GitHubRelease(tag_name: "v1.0", draft: false, prerelease: false, assets: [
            .init(name: ReleaseInstaller.assetName, browser_download_url: URL(string: "https://github.com/chrisdmacrae/rexnotch-fork/releases/download/v1/app.zip")!),
        ])
        XCTAssertThrowsError(try lookalike.asset(named: ReleaseInstaller.assetName))
    }

    func testVerifiedReplacementAndRollbackWithPathsContainingSpaces() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RexNotch update test " + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("Installed RexNotch.app")
        try fm.createDirectory(at: destination.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("Contents/marker"))
        let fixture = root.appendingPathComponent("fixture/RexNotch.app")
        let macOS = fixture.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        for name in ["RexNotch", "rex-hud"] {
            try fm.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent(name).path)
        }
        let plist: [String: Any] = ["CFBundleIdentifier": "com.chrisdmacrae.rexnotch", "CFBundleExecutable": "RexNotch",
                                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.2.3"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: fixture.appendingPathComponent("Contents/Info.plist"))
        try Data("new".utf8).write(to: fixture.appendingPathComponent("Contents/marker"))
        try ReleaseInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", fixture.path])
        let zip = root.appendingPathComponent("release.zip")
        try ReleaseInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", fixture.path, zip.path])
        let archive = try Data(contentsOf: zip)
        let hash = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let manifest = "\(hash)  \(ReleaseInstaller.assetName)"
        let report = root.appendingPathComponent("failure.txt")

        XCTAssertThrowsError(try ReleaseInstaller.stage(archive: archive, manifest: manifest, version: "2.0", destination: destination))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Contents/marker")), "old")

        let rollback = try ReleaseInstaller.stage(archive: archive, manifest: manifest, version: "v1.2.3", destination: destination)
        let failed = ReleaseInstaller.replacementProcess(work: rollback, destination: destination, report: report, parentPID: Int32.max, launcher: "/usr/bin/false")
        try failed.run()
        failed.waitUntilExit()
        XCTAssertNotEqual(failed.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Contents/marker")), "old")
        XCTAssertTrue(try String(contentsOf: report).contains("restored"))
        XCTAssertFalse(fm.fileExists(atPath: rollback.path))

        let staged = try ReleaseInstaller.stage(archive: archive, manifest: manifest, version: "v1.2.3", destination: destination)
        let success = ReleaseInstaller.replacementProcess(work: staged, destination: destination, report: report, parentPID: Int32.max, launcher: "/usr/bin/true")
        try success.run()
        success.waitUntilExit()
        XCTAssertEqual(success.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Contents/marker")), "new")
        XCTAssertFalse(fm.fileExists(atPath: staged.path))

        // A matching archive checksum must not bypass an invalid app signature.
        try Data("tampered".utf8).write(to: fixture.appendingPathComponent("Contents/marker"))
        try fm.removeItem(at: zip)
        try ReleaseInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", fixture.path, zip.path])
        let tampered = try Data(contentsOf: zip)
        let tamperedHash = SHA256.hash(data: tampered).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try ReleaseInstaller.stage(archive: tampered, manifest: "\(tamperedHash)  \(ReleaseInstaller.assetName)", version: "1.2.3", destination: destination))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Contents/marker")), "new")
    }
}
