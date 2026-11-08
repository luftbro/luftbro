import AppKit
import CryptoKit

/// Updates from the GitHub releases, without a framework: the newest release
/// carries `latest.json` (build number, zip, SHA-256; package-app.sh writes
/// it) and `latest.json.sig`, its Ed25519 signature, made by
/// scripts/publish_release.py with a key that never goes to GitHub. A feed
/// whose signature doesn't verify against `updateKey` is ignored, so write
/// access to the releases alone can't ship an update. The app checks at
/// launch (at most daily, if allowed in Settings) and from the app menu;
/// Install downloads the zip, checks it, and a small shell helper swaps the
/// app once Luftbro has quit, then reopens it. When GitHub fails at a file's
/// download address (5xx, no answer), the file comes through GitHub's API.
///
/// Only the downloadable app updates itself: a development build keeps its
/// sources. LUFTBRO_UPDATE_FEED points at another latest.json and
/// LUFTBRO_UPDATE_KEY at another public key (testing).
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Decodable, Equatable {
        let version: String
        let build: Int
        let url: URL
        let sha256: String
        /// What's new, in Markdown (docs/releases/<version>.md).
        var notes: String? = nil

        /// Only a release the feed can't have been tampered into: the zip
        /// from GitHub over https (the download follows GitHub's redirect to
        /// its object store, which is fine) and a checksum that is one.
        var looksGenuine: Bool {
            url.scheme == "https" && url.host == "github.com"
                && sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
        }
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Release)
        case checkFailed(UpdateProblem)
        /// Shown in the window (a failed check stays quiet).
        case installFailed(UpdateProblem)
    }

    private(set) var state = State.idle
    /// Why the last Install didn't get as far as replacing the app (a stalled
    /// download, a quit that didn't happen): shown with the offer to try again.
    private(set) var installError: UpdateProblem?

    static let autoCheckKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    static let releasesPage = URL(string: "https://github.com/luftbro/luftbro/releases/latest")!

    /// The public half of the release signing key (base64, raw Ed25519).
    private static let updateKey = "WVw7TweVdKxQhn7PCjkYE+nXLx0jilfwqUa8xulu+S8="

    private let feed: URL?
    /// The release feed on GitHub (not a test feed): its files can also be
    /// fetched through GitHub's API.
    private let feedOnGitHub: Bool
    private let publicKey: Curve25519.Signing.PublicKey?
    /// Downloads with limits, so a stalled connection ends instead of leaving
    /// "Downloading the update…" up for good. A request may wait a minute for
    /// data, the whole zip a quarter of an hour.
    private let downloads: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 15 * 60
        return URLSession(configuration: cfg)
    }()

    private init() {
        if let f = ProcessInfo.processInfo.environment["LUFTBRO_UPDATE_FEED"], !f.isEmpty {
            feed = f.hasPrefix("/") ? URL(fileURLWithPath: f) : URL(string: f)
            feedOnGitHub = false
        } else if BackendProcess.bundledRuntime != nil {
            feed = URL(string: "https://github.com/luftbro/luftbro/releases/latest/download/latest.json")
            feedOnGitHub = true
        } else {
            feed = nil
            feedOnGitHub = false
        }
        let key = ProcessInfo.processInfo.environment["LUFTBRO_UPDATE_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.updateKey
        publicKey = Data(base64Encoded: key).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        UserDefaults.standard.register(defaults: [Self.autoCheckKey: true])
    }

    /// Whether this copy checks at all (not a development build).
    var isAvailable: Bool { feed != nil }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// Where the app can replace itself: not run from the disk image or from
    /// Downloads through App Translocation, and in a folder it may write to.
    static var canInstallInPlace: Bool {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/") else { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    // MARK: - Check

    /// At launch: at most once a day, when allowed in Settings.
    func checkAtLaunch() async {
        guard isAvailable, UserDefaults.standard.bool(forKey: Self.autoCheckKey) else { return }
        let testing = ProcessInfo.processInfo.environment["LUFTBRO_UPDATE_FEED"] != nil
        if !testing, let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 20 * 3600 { return }
        await check()
    }

    /// From the menu: says what it found, also when there is nothing new.
    func checkFromMenu() async {
        guard isAvailable else {
            alert("Updates", "This is a development build: it updates from its sources, not from the releases.")
            return
        }
        await checkShowingProgress()
        switch state {
        case .available(let r):
            let a = NSAlert()
            a.messageText = "A newer Luftbro is available"
            a.informativeText = "Luftbro \(r.version) (build \(r.build)) — you have \(Self.currentVersion) (build \(Self.currentBuild))."
                + (Self.canInstallInPlace ? " Luftbro quits, updates and opens again." : "")
                + (r.notes.map { "\n\n" + Self.plainNotes($0) } ?? "")
            a.addButton(withTitle: Self.canInstallInPlace ? "Install and Relaunch" : "Download")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { install() }
        case .upToDate:
            alert("Luftbro is up to date", "Luftbro \(Self.currentVersion) (build \(Self.currentBuild)) is the newest version.")
        case .checkFailed(let p):
            alert("Couldn’t check for updates", p.message, details: p.details)
        default:
            break
        }
    }

    /// The check from the menu. GitHub can take many seconds to answer, so
    /// unless it answers within a moment a window says it is checking, with
    /// Cancel; it closes by itself when the answer is in.
    private func checkShowingProgress() async {
        let task = Task { await check() }
        try? await Task.sleep(for: .milliseconds(500))
        guard state == .checking else { return await task.value }
        let progress = NSAlert()
        progress.messageText = "Checking for Updates…"
        progress.informativeText = "Asking GitHub for the newest release."
        progress.addButton(withTitle: "Cancel")
        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 16))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        progress.accessoryView = bar
        // The modal loop keeps serving the main actor, so the check finishes
        // while the window is up; then the window closes itself.
        Task {
            await task.value
            if NSApp.modalWindow === progress.window { NSApp.abortModal() }
        }
        if progress.runModal() != .abort { task.cancel() }
        await task.value
    }

    private func check() async {
        guard let feed, !isBusy else { return }
        state = .checking
        do {
            let data = try await releaseFile(feed)
            let sigURL = feed.deletingLastPathComponent().appendingPathComponent(feed.lastPathComponent + ".sig")
            let sigText = try await releaseFile(sigURL, ifMissing: "This release isn’t signed, so Luftbro won’t install it.")
            guard let sig = Data(base64Encoded: String(decoding: sigText, as: UTF8.self)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)),
                  publicKey?.isValidSignature(sig, for: data) == true else {
                throw UpdateError("This release isn’t signed with Luftbro’s key, so Luftbro won’t install it.")
            }
            let r: Release
            do {
                r = try JSONDecoder().decode(Release.self, from: data)
            } catch {
                throw UpdateError("The update feed doesn’t look like Luftbro’s.", details: "\(feed.absoluteString)\n\(error)")
            }
            guard r.looksGenuine else {
                throw UpdateError("The update feed doesn’t look like Luftbro’s.",
                                  details: "\(feed.absoluteString)\nurl \(r.url.absoluteString)\nsha256 \(r.sha256)")
            }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            state = r.build > Self.currentBuild ? .available(r) : .upToDate
        } catch _ where Task.isCancelled {
            state = .idle
        } catch let e as UpdateError {
            state = .checkFailed(e.problem)
        } catch {
            state = .checkFailed(UpdateProblem(message: error.localizedDescription, details: String(describing: error)))
        }
    }

    private func fetch(_ url: URL, ifMissing: String? = nil, accept: String? = nil) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Luftbro/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw UpdateError(Self.problem(requesting: url, error: error), atGitHub: !Self.isCancellation(error))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var p = Self.problem(requesting: url, response: http)
            if http.statusCode == 404, let ifMissing { p = UpdateProblem(message: ifMissing, details: p.details) }
            throw UpdateError(p, atGitHub: http.statusCode >= 500)
        }
        return data
    }

    /// A release file from its download address, or, when GitHub fails there
    /// (5xx, no answer), the same file through GitHub's API: its download
    /// edge can serve a cached 504 for hours while the API answers. Either way
    /// it is this repository's release file, checked by signature and checksum.
    private func releaseFile(_ url: URL, ifMissing: String? = nil) async throws -> Data {
        do {
            return try await fetch(url, ifMissing: ifMissing)
        } catch let e as UpdateError where e.atGitHub && feedOnGitHub {
            guard let file = Self.releaseFile(of: url) else { throw e }
            do {
                let asset = try await apiAsset(file.name, tag: file.tag)
                return try await fetch(asset, ifMissing: ifMissing, accept: "application/octet-stream")
            } catch let api as UpdateError {
                throw UpdateError(Self.problem(e.problem, thenThroughAPI: api.problem))
            }
        }
    }

    /// (tag, file name) of a download address in Luftbro's releases; the tag
    /// is nil for releases/latest.
    static func releaseFile(of url: URL) -> (tag: String?, name: String)? {
        let p = url.pathComponents       // ["/", "luftbro", "luftbro", "releases", ...]
        guard url.scheme == "https", url.host == "github.com", p.count == 7,
              p[1] == "luftbro", p[2] == "luftbro", p[3] == "releases" else { return nil }
        if p[4] == "latest", p[5] == "download" { return (nil, p[6]) }
        if p[4] == "download" { return (p[5], p[6]) }
        return nil
    }

    /// The API address of a release file, from the release's list of assets.
    private func apiAsset(_ name: String, tag: String?) async throws -> URL {
        let which = tag.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) }.map { "tags/\($0)" } ?? "latest"
        let release = URL(string: "https://api.github.com/repos/luftbro/luftbro/releases/\(which)")!
        let data = try await fetch(release, accept: "application/vnd.github+json")
        struct APIRelease: Decodable {
            struct Asset: Decodable { let name: String; let url: URL }
            let assets: [Asset]
        }
        guard let asset = (try? JSONDecoder().decode(APIRelease.self, from: data))?.assets.first(where: { $0.name == name }),
              asset.url.host == "api.github.com" else {
            throw UpdateError("GitHub doesn’t have the update file.", details: "GET \(release.absoluteString)\nno asset named \(name)")
        }
        return asset.url
    }

    /// The first attempt's sentence, with both attempts in the details.
    static func problem(_ first: UpdateProblem, thenThroughAPI api: UpdateProblem) -> UpdateProblem {
        UpdateProblem(message: first.message,
                      details: [first.details, "Then through GitHub’s API:\n" + (api.details ?? api.message)]
                          .compactMap { $0 }.joined(separator: "\n\n"))
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// An answer other than 200: a sentence for people, and the request, any
    /// redirect, the status and GitHub's request id for the details.
    static func problem(requesting url: URL, response: HTTPURLResponse) -> UpdateProblem {
        let status = response.statusCode
        let message = switch status {
        case 500...599: "GitHub isn’t responding right now. Try again later."
        case 403, 429: "GitHub is turning requests away right now. Try again later."
        case 404: "GitHub doesn’t have the update file."
        default: "GitHub answered with an error."
        }
        var lines = ["GET \(url.absoluteString)"]
        if let final = response.url, final != url {
            var c = URLComponents(url: final, resolvingAgainstBaseURL: false)
            c?.query = nil                  // signed, short-lived download tokens
            lines.append("→ \(c?.string ?? final.absoluteString)")
        }
        lines.append("HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))")
        if let id = response.value(forHTTPHeaderField: "X-GitHub-Request-Id") {
            lines.append("X-GitHub-Request-Id: \(id)")
        }
        return UpdateProblem(message: message, details: lines.joined(separator: "\n"))
    }

    /// No answer at all (offline, a timeout, TLS): the same, with the system's error.
    static func problem(requesting url: URL, error: Error) -> UpdateProblem {
        let ns = error as NSError
        let message = ns.domain == NSURLErrorDomain
            ? "Luftbro couldn’t reach GitHub. Check the internet connection and try again."
            : error.localizedDescription
        return UpdateProblem(message: message,
                             details: "GET \(url.absoluteString)\n\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }

    private var isBusy: Bool {
        if case .downloading = state { return true }
        return state == .checking
    }

    // MARK: - Install

    /// Install button: download, verify, swap and relaunch; where the app
    /// can't replace itself, the release page instead.
    func install() {
        guard case .available(let r) = state else { return }
        guard Self.canInstallInPlace else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        installError = nil
        state = .downloading(r)
        Task {
            do {
                let app = try await download(r)
                try relaunch(replacingWith: app, release: r)
            } catch let e as DownloadError {
                // The network let us down, not the release: offer Install again.
                installError = e.problem
                state = .available(r)
            } catch let e as UpdateError {
                state = .installFailed(e.problem)
            } catch {
                state = .installFailed(UpdateProblem(message: error.localizedDescription,
                                                     details: String(describing: error)))
            }
        }
    }

    /// The new Luftbro.app, unpacked next to the zip and checked: the checksum
    /// from the feed, then that it is a real app folder claiming to be this
    /// app at the promised build, with a signature that still verifies.
    private func download(_ r: Release) async throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/luftbro/update", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var result = await downloadOnce(r.url)
        // GitHub failing at its download address: the same zip through its API.
        if case .failure(let e) = result, e.atGitHub, feedOnGitHub, let file = Self.releaseFile(of: r.url) {
            do {
                let asset = try await apiAsset(file.name, tag: file.tag)
                result = await downloadOnce(asset, accept: "application/octet-stream")
                if case .failure(let api) = result {
                    result = .failure(DownloadError(Self.problem(e.problem, thenThroughAPI: api.problem)))
                }
            } catch let api as UpdateError {
                result = .failure(DownloadError(Self.problem(e.problem, thenThroughAPI: api.problem)))
            }
        }
        let tmp = try result.get()
        let zip = dir.appendingPathComponent("Luftbro.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)

        let digest = try await Task.detached {
            SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
        }.value
        guard digest == r.sha256.lowercased() else {
            throw UpdateError("The download is damaged (checksum mismatch).",
                              details: "\(r.url.absoluteString)\nexpected sha256 \(r.sha256.lowercased())\ngot      sha256 \(digest)")
        }

        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], failure: "Unpacking the update failed.")
        let app = dir.appendingPathComponent("Luftbro.app")
        // A symlink named Luftbro.app would make the helper swap in whatever
        // it points at; attributesOfItem doesn't follow links.
        let type = (try? FileManager.default.attributesOfItem(atPath: app.path))?[.type] as? FileAttributeType
        guard type == .typeDirectory else { throw UpdateError("The download doesn’t contain a Luftbro app.") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard Int(info?["CFBundleVersion"] as? String ?? "") == r.build,
              info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download doesn’t contain the expected Luftbro build.")
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                      failure: "The downloaded Luftbro isn’t signed as expected.")
        return app
    }

    /// Hands over to a shell helper and quits: once Luftbro has exited it
    /// moves the new app into place (the old one back if that fails) and
    /// opens it again. Quitting goes through AppDelegate.quit(): AppKit
    /// refuses a plain terminate while a sheet is up. If the app is still
    /// here two seconds later the quit was cancelled: the helper is stopped
    /// (it would otherwise swap the app under a running Luftbro) and the
    /// offer comes back.
    private func relaunch(replacingWith new: URL, release: Release) throws {
        let script = """
        waited=0
        while /bin/kill -0 "$1" 2>/dev/null; do
          /bin/sleep 0.2; waited=$((waited + 1))
          [ "$waited" -ge 300 ] && exit 1
        done
        old="$2"; new="$3"; backup="$(dirname "$old")/.Luftbro-previous.app"
        /bin/rm -rf "$backup"
        if /bin/mv "$old" "$backup"; then
          if /bin/mv "$new" "$old"; then /bin/rm -rf "$backup"; else /bin/mv "$backup" "$old"; fi
        fi
        /usr/bin/open "$old"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "luftbro-update", String(getpid()), Bundle.main.bundleURL.path, new.path]
        try p.run()
        AppDelegate.quit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                if p.isRunning { p.terminate() }
                self.installError = UpdateProblem(message: "Luftbro didn’t quit, so the update wasn’t installed.")
                self.state = .available(release)
            }
        }
    }

    private func downloadOnce(_ url: URL, accept: String? = nil) async -> Result<URL, DownloadError> {
        var req = URLRequest(url: url)
        req.setValue("Luftbro/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        do {
            let (tmp, response) = try await downloads.download(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failure(DownloadError(Self.problem(requesting: url, response: http), atGitHub: http.statusCode >= 500))
            }
            return .success(tmp)
        } catch {
            return .failure(DownloadError(Self.problem(requesting: url, error: error), atGitHub: !Self.isCancellation(error)))
        }
    }

    private func run(_ tool: String, _ args: [String], failure: String) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw UpdateError(failure, details: "\(tool) \(args.joined(separator: " ")) exited with status \(p.terminationStatus)")
            }
        }.value
    }

    /// The notes without Markdown's marks, for an alert.
    static func plainNotes(_ md: String) -> String {
        md.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var l = String(line)
            if l.hasPrefix("#") { l = l.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
            return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func alert(_ title: String, _ message: String, details: String? = nil) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        if let details { a.accessoryView = AlertDetails(details, in: a) }
        a.runModal()
    }
}

/// What went wrong with an update: a sentence for people, and the technical
/// details (request, answer, error codes) for whoever wants them.
struct UpdateProblem: Equatable {
    let message: String
    var details: String? = nil
}

struct UpdateError: LocalizedError {
    let problem: UpdateProblem
    /// GitHub failed at its end (5xx or no answer): its API may still answer.
    var atGitHub = false
    var errorDescription: String? { problem.message }
    init(_ problem: UpdateProblem, atGitHub: Bool = false) { self.problem = problem; self.atGitHub = atGitHub }
    init(_ message: String, details: String? = nil) { problem = UpdateProblem(message: message, details: details) }
}

/// A download that didn't arrive (as opposed to one that arrived wrong).
private struct DownloadError: Error {
    let problem: UpdateProblem
    var atGitHub = false
    init(_ problem: UpdateProblem, atGitHub: Bool = false) { self.problem = problem; self.atGitHub = atGitHub }
}
