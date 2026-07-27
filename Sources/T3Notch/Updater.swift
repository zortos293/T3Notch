import AppKit
import SwiftUI
import T3NotchCore

/// Self-update, shaped after T3 Code's desktop updater.
///
/// The states are the same ones T3 Code reports (`idle`, `checking`,
/// `up-to-date`, `available`, `downloading`, `downloaded`, `error`), and so is
/// the rhythm: one check a little after launch, then a poll on a timer. What
/// differs is the mechanics — electron-updater has Squirrel to hand the new
/// build to, whereas here the app downloads the release zip, unpacks it beside
/// itself, swaps the bundle, and relaunches.
///
/// Nothing is installed without being asked for: an update downloads on its own
/// only if the user turned that on, and the swap always waits for a click.
@MainActor
@Observable
final class Updater {
    enum Status: Equatable {
        /// No updating possible, with the reason: a build run straight from
        /// SwiftPM has no bundle to replace.
        case unsupported(String)
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(UpdateRelease)
        case downloading(UpdateRelease, fraction: Double)
        /// Unpacked and verified, sitting next to the current bundle.
        case readyToInstall(UpdateRelease, staged: URL)
        case installing(UpdateRelease)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var currentVersion: AppVersion?

    /// Whether there is something for the user to act on, which is what the menu
    /// bar badge reflects.
    var hasOffer: Bool {
        switch status {
        case .available, .readyToInstall: true
        default: false
        }
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    private let feed: GitHubUpdateFeed
    private let settings: SettingsStore
    private var poller: Task<Void, Never>?
    private var work: Task<Void, Never>?


    /// T3 Code waits 15 seconds before its first check so the window is up
    /// first; the same applies here, with a poll slow enough to stay well inside
    /// GitHub's 60-requests-an-hour allowance for callers without a token.
    private static let startupDelay: Duration = .seconds(15)
    private static let pollInterval: Duration = .seconds(6 * 60 * 60)

    init(settings: SettingsStore, feed: GitHubUpdateFeed = .t3notch) {
        self.settings = settings
        self.feed = feed
        currentVersion = Self.installedVersion()
        if Self.installedBundleURL == nil || currentVersion == nil {
            status = .unsupported("Updates need the packaged app; this build runs from SwiftPM.")
        }
    }

    var channel: UpdateChannel { settings.values.updateChannel }

    var canUpdate: Bool {
        if case .unsupported = status { return false }
        return true
    }

    /// Starts the launch check and the poll. Safe to call again; the old poller
    /// is replaced.
    func start() {
        poller?.cancel()
        guard canUpdate else { return }
        poller = Task { [weak self] in
            try? await Task.sleep(for: Self.startupDelay)
            while !Task.isCancelled {
                await self?.checkIfAutomatic()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    /// Re-reads the settings after a change, so turning automatic checks back on
    /// does not wait for the next launch.
    func applySettings() {
        if settings.values.automaticUpdates {
            if poller == nil { start() }
        } else {
            stop()
        }
        // A channel change can make an already-seen release irrelevant.
        if case let .available(release) = status,
            release.isPrerelease, !channel.allowsPrerelease
        {
            status = .idle
        }
    }

    private func checkIfAutomatic() async {
        guard settings.values.automaticUpdates else { return }
        // Never interrupt a download the user started.
        guard !isBusy, !isStaged else { return }
        await check(userInitiated: false)
    }

    private var isStaged: Bool {
        if case .readyToInstall = status { return true }
        return false
    }

    /// Asks GitHub what the newest release is and files it against this build.
    func check(userInitiated: Bool = true) async {
        guard canUpdate else { return }
        guard let currentVersion else {
            status = .unsupported("This build has no version to compare against.")
            return
        }
        guard !isBusy else { return }

        status = .checking
        do {
            let release = try await feed.newestRelease(channel: channel)
            guard let release, release.version > currentVersion else {
                status = .upToDate(checkedAt: .now)
                return
            }
            status = .available(release)
            if settings.values.automaticDownload {
                download(release)
            }
        } catch {
            status = .failed(error.localizedDescription)
            // A silent poll should not leave an error sitting in the panel for
            // six hours; the next poll will try again anyway.
            if !userInitiated {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, case .failed = status else { return }
                    status = .idle
                }
            }
        }
    }

    /// Downloads the release zip, unpacks it, and checks that what came out is
    /// really a newer T3Notch before offering to install it.
    func download(_ release: UpdateRelease) {
        guard canUpdate, !isBusy else { return }
        status = .downloading(release, fraction: 0)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let archive = try await self.fetchArchive(release)
                let staged = try await Self.unpack(archive, expecting: release)
                guard !Task.isCancelled else { return }
                self.status = .readyToInstall(release, staged: staged)
            } catch {
                // A cancelled URLSession throws a URLError rather than
                // CancellationError, so the task's own flag is what decides
                // whether this was the user pressing Cancel.
                self.status =
                    Task.isCancelled
                    ? .available(release)
                    : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    /// Puts the new bundle where the running one is and restarts into it.
    ///
    /// The swap is a single `replaceItemAt`, so a failure part-way through
    /// leaves the current app intact rather than half-overwritten.
    func install() {
        guard case let .readyToInstall(release, staged) = status else { return }
        guard let destination = Self.installedBundleURL else { return }
        status = .installing(release)

        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            try Self.relaunch(destination)
        } catch {
            status = .failed(Self.installFailure(error, destination: destination))
            return
        }
        NSApp.terminate(nil)
    }

    /// Where the release notes live, for the "What's new" link.
    var releasesPageURL: URL { feed.releasesPageURL }

    // MARK: - Download

    private func fetchArchive(_ release: UpdateRelease) async throws -> URL {
        var request = URLRequest(url: release.asset.url)
        request.timeoutInterval = 60
        request.setValue("T3Notch", forHTTPHeaderField: "User-Agent")

        // The size is already known from the release, so the bar does not depend
        // on the CDN sending a content length.
        let expected = Int64(release.asset.size)
        let progress = DownloadProgress { [weak self] written, hinted in
            let total = expected > 0 ? expected : hinted
            guard total > 0 else { return }
            self?.status = .downloading(
                release,
                fraction: min(Double(written) / Double(total), 0.99)
            )
        }

        let (temporary, response) = try await URLSession.shared.download(
            for: request,
            delegate: progress
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdaterError.message("Download failed with HTTP \(http.statusCode)")
        }

        // Off the system temp volume and onto the app's, which is where the
        // unpacked bundle has to end up for the swap to work.
        let archive = try Self.freshStagingDirectory()
            .appendingPathComponent(release.asset.name)
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: temporary, to: archive)

        status = .downloading(release, fraction: 1)
        return archive
    }

    /// Expands the zip and returns the app bundle, once it has been checked.
    private nonisolated static func unpack(
        _ archive: URL,
        expecting release: UpdateRelease
    ) async throws -> URL {
        let directory = archive.deletingLastPathComponent()
        let expanded = directory.appendingPathComponent("expanded", isDirectory: true)
        try? FileManager.default.removeItem(at: expanded)
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)

        // ditto, not NSFileCoordinator or Archive: it is what packaged the zip,
        // and it is the only unpacker that keeps the code signature intact.
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        try? FileManager.default.removeItem(at: archive)

        let contents = try FileManager.default.contentsOfDirectory(
            at: expanded,
            includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.message("The download did not contain an app.")
        }

        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard
            let info = NSDictionary(contentsOf: plist) as? [String: Any],
            let identifier = info["CFBundleIdentifier"] as? String
        else {
            throw UpdaterError.message("The downloaded app has no Info.plist.")
        }
        guard identifier == Bundle.main.bundleIdentifier else {
            throw UpdaterError.message("The download is a different app (\(identifier)).")
        }
        let shipped = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard let shipped, shipped == release.version else {
            let found = shipped.map(String.init(describing:)) ?? "nothing"
            throw UpdaterError.message(
                "The \(release.version) release contains \(found)."
            )
        }
        // GitHub does not set it on a programmatic download, but a release built
        // elsewhere might carry it, and a quarantined app cannot launch itself.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    // MARK: - Install

    /// Waits for this process to be gone before reopening, so the relaunch does
    /// not race the swap or bring up a second copy.
    private static func relaunch(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do
                /bin/sleep 0.2
            done
            /bin/sleep 0.3
            /usr/bin/open \(escape(app.path))
            """,
        ]
        try process.run()
    }

    private static func installFailure(_ error: Error, destination: URL) -> String {
        let error = error as NSError
        let deniedUnderneath = error.underlyingErrors.contains {
            let inner = $0 as NSError
            return inner.domain == NSPOSIXErrorDomain && inner.code == Int(EACCES)
        }
        if error.code == NSFileWriteNoPermissionError || deniedUnderneath {
            return "No permission to replace \(destination.lastPathComponent). "
                + "Move T3Notch to your Applications folder, or install the update by hand."
        }
        return "Could not install the update: \(error.localizedDescription)"
    }

    // MARK: - Locations

    /// The running app bundle, or nil when the executable is not in one.
    static var installedBundleURL: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return url
    }

    /// A directory on the same volume as the app, which `replaceItemAt` needs:
    /// a swap across volumes is a copy, and a copy can fail half-done.
    private static func freshStagingDirectory() throws -> URL {
        guard let bundle = installedBundleURL else {
            throw UpdaterError.message("Updates need the packaged app.")
        }
        return try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: bundle,
            create: true
        )
    }


    static func installedVersion() -> AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap(AppVersion.init)
    }

    /// The version to show in the settings panel, packaged or not.
    var versionLabel: String {
        guard let currentVersion else { return "unpackaged build" }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(currentVersion) (\($0))" } ?? "\(currentVersion)"
    }

    // MARK: - Shell

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdaterError.message(
                "\((tool as NSString).lastPathComponent) failed"
                    + (detail.isEmpty ? "" : ": \(detail.prefix(160))")
            )
        }
    }

    private static func escape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Bytes-written callbacks for the download task, hopped onto the main actor.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate,
    URLSessionDownloadDelegate, Sendable
{
    private let report: @MainActor @Sendable (_ written: Int64, _ total: Int64) -> Void

    init(report: @escaping @MainActor @Sendable (Int64, Int64) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let report = report
        Task { @MainActor in report(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async `download(for:)` call hands back its own copy; nothing to do.
    }
}

enum UpdaterError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): text
        }
    }
}

extension Updater.Status {
    /// One line for the settings panel.
    var summary: String {
        switch self {
        case let .unsupported(reason): reason
        case .idle: "Not checked yet."
        case .checking: "Checking for updates…"
        case let .upToDate(checkedAt):
            "Up to date. Checked \(Self.relative(checkedAt))."
        case let .available(release):
            "Version \(release.version) is out." + (release.isPrerelease ? " (pre-release)" : "")
        case let .downloading(release, fraction):
            "Downloading \(release.version)… \(Int(fraction * 100))%"
        case let .readyToInstall(release, _):
            "Version \(release.version) is ready to install."
        case let .installing(release): "Installing \(release.version)…"
        case let .failed(message): message
        }
    }

    var isProblem: Bool {
        if case .failed = self { return true }
        return false
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
