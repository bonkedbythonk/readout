import Foundation
import Observation

/// Asks GitHub whether a newer release of Readout exists.
///
/// It only tells you. Downloads are signed ad hoc, so a new version installs
/// the way the first one did, and the release page carries those steps.
///
/// The daily check goes through `NSBackgroundActivityScheduler` rather than a
/// timer: the system runs it at a moment the Mac is awake anyway, and between
/// runs the app is not woken at all. Readout does no work while nothing is
/// open, and checking for updates should not change that.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let page: URL
    }

    /// What a check someone asked for came to, shown in the panel until it
    /// closes. Not an alert: an alert opened from the menu bar panel is
    /// cancelled the moment it appears, because the panel still holds key.
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case failed
    }

    /// Set when the newest release is newer than this build.
    private(set) var available: Release?
    /// Only checks someone asked for change this; automatic ones stay silent.
    private(set) var status = Status.idle
    private var isChecking = false

    var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Self.automaticKey)
            schedule()
        }
    }

    let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    private static let latestRelease =
        URL(string: "https://api.github.com/repos/bonkedbythonk/readout/releases/latest")!
    private static let automaticKey = "checksForUpdatesAutomatically"
    private var scheduler: NSBackgroundActivityScheduler?

    init() {
        checksAutomatically = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
        schedule()
        guard checksAutomatically else { return }
        // At login the network is often not up yet, and a failed automatic
        // check stays silent, so give it a moment rather than lose the day.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            await self?.check(userInitiated: false)
        }
    }

    var isBusy: Bool { status == .checking }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if userInitiated { status = .checking }

        do {
            let release = try await fetchLatest()
            if Self.isVersion(release.version, newerThan: currentVersion) {
                available = release
                if userInitiated { status = .idle }
            } else {
                available = nil
                if userInitiated { status = .upToDate }
            }
        } catch {
            if userInitiated { status = .failed }
        }
    }

    /// Called when the panel closes, so a result does not greet the next
    /// opening as if it were news.
    func clearStatus() {
        if status != .checking { status = .idle }
    }

    private func fetchLatest() async throws -> Release {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
        }

        var request = URLRequest(url: Self.latestRelease, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        // The page is opened in a browser, so only ever a GitHub one.
        guard let page = URL(string: payload.html_url), page.scheme == "https",
              page.host == "github.com" else {
            throw URLError(.badServerResponse)
        }
        let version = payload.tag_name.hasPrefix("v")
            ? String(payload.tag_name.dropFirst())
            : payload.tag_name
        return Release(version: version, page: page)
    }

    private func schedule() {
        scheduler?.invalidate()
        scheduler = nil
        guard checksAutomatically else { return }

        let activity = NSBackgroundActivityScheduler(identifier: "com.thomas.readout.update-check")
        activity.repeats = true
        activity.interval = 24 * 60 * 60
        activity.tolerance = 60 * 60
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.check(userInitiated: false)
                completion(.finished)
            }
        }
        scheduler = activity
    }

    /// Compares numerically, component by component: as strings, 0.1.10 would
    /// sort before 0.1.9. Anything that does not parse — a pre-release suffix,
    /// a build with no version — is never reported as newer.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func components(_ version: String) -> [Int]? {
            let parts = version.split(separator: ".").map { Int($0) }
            guard !parts.isEmpty, !parts.contains(nil) else { return nil }
            return parts.compactMap { $0 }
        }
        guard let candidate = components(candidate), let current = components(current) else {
            return false
        }
        for index in 0 ..< max(candidate.count, current.count) {
            let new = index < candidate.count ? candidate[index] : 0
            let old = index < current.count ? current[index] : 0
            if new != old { return new > old }
        }
        return false
    }
}
