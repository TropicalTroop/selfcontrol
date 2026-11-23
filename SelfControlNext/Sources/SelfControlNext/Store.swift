import AppKit
import Foundation
import Observation

/// Owns the user's configuration and usage history and answers "should this app be blocked?".
///
/// When the root helper is running, it holds the authoritative copy of anything that's locked:
/// the focus session, the Strict Mode rules, and usage. Local files are just a convenience copy.
@MainActor @Observable
final class Store {
    var config: Config {
        didSet {
            scheduleConfigSave()
            scheduleRulesSync()
        }
    }
    var state: UsageState
    let helper = HelperClient()
    let browser = BrowserTracker()

    /// Shown as a banner when an edit was rejected (e.g. by Strict Mode).
    var notice: String?

    nonisolated static var ownBundleID: String { Constants.appBundleID }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Usage not yet reported to the helper: day -> bundle -> seconds.
    @ObservationIgnored private var pendingUsage: [String: [String: Double]] = [:]
    @ObservationIgnored private var pendingWebUsage: [String: [String: Double]] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("SelfControlNext", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = Self.load(Config.self, from: directory.appendingPathComponent("config.json")) ?? Config()
        state = Self.load(UsageState.self, from: directory.appendingPathComponent("state.json")) ?? UsageState()
        pruneHistory()
    }

    // MARK: Persistence

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSON.decode(type, data)
        } catch {
            // Keep the unreadable file around rather than silently overwriting it.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            NSLog("SelfControlNext: could not decode \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to name: String) {
        do {
            try JSON.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("SelfControlNext: failed to save \(name): \(error)")
        }
    }

    private func scheduleConfigSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveConfig()
        }
    }

    func saveConfig() { write(config, to: "config.json") }
    func saveState() {
        flushUsage()
        write(state, to: "state.json")
    }
    func saveAll() { saveConfig(); saveState() }

    private func pruneHistory() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) else { return }
        let cutoffKey = dayKey(cutoff)
        state.days = state.days.filter { $0.key >= cutoffKey }
        state.webDays = state.webDays.filter { $0.key >= cutoffKey }
        let todayPrefix = dayKey()
        state.warned = state.warned.filter { $0.hasPrefix(todayPrefix) }
        let now = Date()
        state.overrides = state.overrides.filter { $0.value > now }
    }

    func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Helper sync

    var localRules: Rules { Rules(limits: config.limits, downtime: config.downtime, websites: config.websites) }

    /// The rules actually enforced: the helper's locked copy in Strict Mode, otherwise local config.
    var effectiveRules: Rules {
        if helper.isStrict, let locked = helper.status?.rules { return locked }
        return localRules
    }

    var isStrict: Bool { helper.isStrict }

    /// Pushes rule edits to the helper after they settle. In Strict Mode, an edit that loosens the
    /// rules is rolled back to the locked copy.
    private func scheduleRulesSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await self?.syncRules()
        }
    }

    func syncRules() async {
        guard helper.isAvailable else { return }
        let rules = localRules
        if rules == helper.status?.rules { return }
        if helper.isStrict, let locked = helper.status?.rules {
            let problems = Rules.loosenings(from: locked, to: rules)
            if !problems.isEmpty {
                revertToLockedRules(locked)
                showNotice("Strict Mode is on, so you can't \(problems.formatted(.list(type: .or))).")
                return
            }
        }
        do {
            try await helper.send(.setRules(rules))
        } catch {
            if helper.isStrict, let locked = helper.status?.rules { revertToLockedRules(locked) }
            showNotice(error.localizedDescription)
        }
    }

    private func revertToLockedRules(_ locked: Rules) {
        config.limits = locked.limits
        config.downtime = locked.downtime
        config.websites = locked.websites
    }

    /// Called every few seconds by the monitor: reports usage and refreshes the helper's status.
    func heartbeat() async {
        guard helper.isInstalled else {
            await helper.refresh()
            return
        }
        let deltas = pendingUsage
        let webDeltas = pendingWebUsage
        do {
            try await helper.send(.heartbeat(Heartbeat(agentPath: Bundle.main.bundlePath, usageDeltas: deltas,
                                                       webUsageDeltas: webDeltas)))
            for (day, apps) in deltas {
                for (id, seconds) in apps { pendingUsage[day]?[id]? -= seconds }
            }
            for (day, sites) in webDeltas {
                for (domain, seconds) in sites { pendingWebUsage[day]?[domain]? -= seconds }
            }
            pendingUsage = pendingUsage.mapValues { $0.filter { $0.value > 0.001 } }.filter { !$0.value.isEmpty }
            pendingWebUsage = pendingWebUsage.mapValues { $0.filter { $0.value > 0.001 } }.filter { !$0.value.isEmpty }
            adoptHelperState()
        } catch {
            // Helper unreachable: keep enforcing with local rules; usage stays pending.
        }
    }

    /// Mirrors locked state from the helper so the UI shows what's actually enforced.
    private func adoptHelperState() {
        guard let status = helper.status else { return }
        if status.strict != nil, let locked = status.rules, !Rules.loosenings(from: locked, to: localRules).isEmpty {
            // Local config is looser than what's locked (e.g. the config file was edited): undo that.
            revertToLockedRules(locked)
        } else if status.rules != localRules {
            Task { await syncRules() }  // e.g. fresh helper install, or edits made while it was unreachable
        }
        if state.focus != status.focus, let focus = status.focus {
            state.focus = focus
        }
    }

    // MARK: Usage

    // Per-second usage goes into these unobserved buffers, and is copied into `state` (which the
    // UI observes) every 10 seconds by flushUsage(). Reads include the buffers, so enforcement still
    // sees every second; only on-screen numbers update less often (they show minutes anyway).
    @ObservationIgnored private var liveUsage: [String: [String: Double]] = [:]
    @ObservationIgnored private var liveWebUsage: [String: [String: Double]] = [:]

    func addUsage(bundleID: String, name: String, seconds: TimeInterval, at date: Date = Date()) {
        let day = dayKey(date)
        liveUsage[day, default: [:]][bundleID, default: 0] += seconds
        pendingUsage[day, default: [:]][bundleID, default: 0] += seconds
        if state.appNames[bundleID] != name { state.appNames[bundleID] = name }
    }

    func addWebUsage(domain: String, seconds: TimeInterval, at date: Date = Date()) {
        let day = dayKey(date)
        liveWebUsage[day, default: [:]][domain, default: 0] += seconds
        pendingWebUsage[day, default: [:]][domain, default: 0] += seconds
    }

    /// Moves buffered usage into the observed state, refreshing the UI.
    func flushUsage() {
        guard !liveUsage.isEmpty || !liveWebUsage.isEmpty else { return }
        for (day, apps) in liveUsage {
            for (id, seconds) in apps { state.days[day, default: [:]][id, default: 0] += seconds }
        }
        for (day, sites) in liveWebUsage {
            for (domain, seconds) in sites { state.webDays[day, default: [:]][domain, default: 0] += seconds }
        }
        liveUsage = [:]
        liveWebUsage = [:]
    }

    private func merged(_ saved: [String: [String: Double]], _ live: [String: [String: Double]], _ day: String) -> [String: Double] {
        (saved[day] ?? [:]).merging(live[day] ?? [:], uniquingKeysWith: +)
    }

    /// Local usage, or the helper's if higher (so resetting local data doesn't reset limits).
    func usage(for bundleID: String, on date: Date = Date()) -> TimeInterval {
        let day = dayKey(date)
        let local = (state.days[day]?[bundleID] ?? 0) + (liveUsage[day]?[bundleID] ?? 0)
        guard Calendar.current.isDateInToday(date), let remote = helper.usageToday[bundleID] else { return local }
        return max(local, remote + (pendingUsage[day]?[bundleID] ?? 0))
    }

    /// Today's time on a site: local, or the helper's if higher.
    func webUsage(for domain: String, on date: Date = Date()) -> TimeInterval {
        let day = dayKey(date)
        let local = (state.webDays[day]?[domain] ?? 0) + (liveWebUsage[day]?[domain] ?? 0)
        guard Calendar.current.isDateInToday(date), let remote = helper.webUsageToday[domain] else { return local }
        return max(local, remote + (pendingWebUsage[day]?[domain] ?? 0))
    }

    func topSites(on date: Date = Date(), limit: Int = 50) -> [(domain: String, seconds: TimeInterval)] {
        merged(state.webDays, liveWebUsage, dayKey(date)).keys
            .map { ($0, webUsage(for: $0, on: date)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }

    func totalUsage(on date: Date = Date()) -> TimeInterval {
        merged(state.days, liveUsage, dayKey(date)).values.reduce(0, +)
    }

    func topApps(on date: Date = Date(), limit: Int = 8) -> [(bundleID: String, name: String, seconds: TimeInterval)] {
        merged(state.days, liveUsage, dayKey(date))
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ($0.key, displayName(for: $0.key), $0.value) }
    }

    func displayName(for bundleID: String) -> String {
        state.appNames[bundleID]
            ?? config.limits.first { $0.app.bundleID == bundleID }?.app.name
            ?? bundleID
    }

    func resetToday() {
        liveUsage[dayKey()] = nil
        state.days[dayKey()] = [:]
        saveState()
    }

    func clearHistory() {
        liveUsage = [:]
        state.days = [:]
        saveState()
    }

    // MARK: Rules

    func limit(for bundleID: String) -> AppLimit? {
        effectiveRules.limits.first { $0.app.bundleID == bundleID }
    }

    var activeFocus: FocusSession? {
        let now = Date()
        if helper.isAvailable, let f = helper.status?.focus, f.end > now { return f }
        guard let f = state.focus, f.end > now else { return nil }
        return f
    }

    var activeDowntime: DateInterval? { effectiveRules.downtime.activeInterval(at: Date()) }

    func isOverridden(_ kind: String, _ bundleID: String, at now: Date = Date()) -> Bool {
        (state.overrides["\(kind)|\(bundleID)"] ?? .distantPast) > now
    }

    func setOverride(_ kind: String, _ bundleID: String, until: Date) {
        state.overrides["\(kind)|\(bundleID)"] = until
        saveState()
    }

    func blockReason(for bundleID: String, at now: Date = Date()) -> BlockReason? {
        let strict = isStrict
        return Enforcement.reason(bundleID: bundleID, at: now, focus: activeFocus, rules: effectiveRules,
                                  usage: usage(for: bundleID, on: now), exemptionsAllowed: !strict,
                                  isOverridden: { strict ? false : self.isOverridden($0, bundleID, at: now) })
    }

    func siteBlockReason(for visit: BrowserTracker.Visit, at now: Date = Date()) -> BlockReason? {
        let strict = isStrict
        if let until = helper.status?.websiteBlocks[visit.domain], until > now {
            // Already blocked by the helper (an accepted website-limit block).
            return .siteLimit(used: webUsage(for: visit.domain), limit: effectiveRules.websites.limitSeconds(for: visit.host, on: now) ?? 0)
        }
        return Enforcement.siteReason(host: visit.host, at: now, focus: activeFocus, rules: effectiveRules,
                                      usage: webUsage(for: visit.domain, on: now), exemptionsAllowed: !strict,
                                      isOverridden: { strict ? false : self.isOverridden($0, visit.domain, at: now) })
    }

    /// Asks the helper to block a site until `until` (it can't be lifted early).
    func blockWebsite(_ domain: String, until: Date) async {
        guard helper.isAvailable else { return }
        do { try await helper.send(.blockWebsites([domain: until])) } catch { showNotice(error.localizedDescription) }
    }

    /// Whether to ask "Is this a good time?" before blocking. Focus Sessions and Strict Mode never ask.
    func allowsDelay(_ reason: BlockReason) -> Bool {
        if isStrict { return false }
        switch reason {
        case .focus: return false
        case .downtime: return !effectiveRules.downtime.blockAtDowntime
        case .limit, .siteLimit: return true
        }
    }

    /// After "Block Now", don't ask again until this block period ends (end of day, or end of Downtime).
    func isBlockAccepted(_ kind: String, _ bundleID: String) -> Bool {
        (state.overrides["accepted:\(kind)|\(bundleID)"] ?? .distantPast) > Date()
    }

    func acceptBlock(_ kind: String, _ bundleID: String, until: Date) {
        state.overrides["accepted:\(kind)|\(bundleID)"] = until
        state.overrides["\(kind)|\(bundleID)"] = nil
        saveState()
    }

    func recordDelay(for bundleID: String) {
        state.warned.append("\(dayKey())|delay|\(bundleID)|\(UUID().uuidString)")
        saveState()
    }

    func delayCount(for bundleID: String) -> Int {
        let prefix = "\(dayKey())|delay|\(bundleID)|"
        return state.warned.filter { $0.hasPrefix(prefix) }.count
    }

    /// Strict Mode problems with replacing `old` by `new` (empty if allowed).
    func strictProblems(replacing old: AppLimit?, with new: AppLimit?) -> [String] {
        guard isStrict, let locked = helper.status?.rules else { return [] }
        var proposed = localRules
        proposed.limits.removeAll { $0.id == (old?.id ?? new?.id) }
        if let new { proposed.limits.append(new) }
        return Rules.loosenings(from: locked, to: proposed)
    }

    /// A new site limit, starting no higher than the limit every other site gets.
    func newSiteLimit(domain: String) -> SiteLimit {
        var limit = SiteLimit(domain: domain)
        if config.websites.limitAllSites {
            limit.dailyMinutes = min(limit.dailyMinutes, config.websites.minutesPerSite)
            limit.perDayMinutes = Array(repeating: limit.dailyMinutes, count: 7)
        }
        return limit
    }

    func strictProblems(replacingSite old: SiteLimit?, with new: SiteLimit?) -> [String] {
        guard isStrict, let locked = helper.status?.rules else { return [] }
        var proposed = localRules
        proposed.websites.siteLimits.removeAll { $0.id == (old?.id ?? new?.id) }
        if let new { proposed.websites.siteLimits.append(new) }
        return Rules.loosenings(from: locked, to: proposed)
    }

    // MARK: Focus

    func startFocus(minutes: Int, list: FocusList? = nil) async throws {
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(minutes * 60))
        let session: FocusSession
        if let list {
            session = FocusSession(apps: list.blockedApps, websites: list.blockedWebsites, start: now, end: end,
                                   listName: list.name, mode: list.mode, allowedApps: list.allowedApps,
                                   allowedWebsites: list.allowedWebsites)
        } else {
            session = FocusSession(apps: config.focusBlocklist, websites: config.focusWebsites, start: now, end: end)
        }
        if helper.isAvailable {
            let response = try await helper.send(.startFocus(session))
            state.focus = response.status.focus ?? session
        } else {
            guard session.websites.isEmpty, session.mode == .exempt else {
                throw HelperError.message("Blocking websites needs the SelfControl helper. Install it in Settings.")
            }
            state.focus = session
        }
        saveState()
    }

    // MARK: Strict Mode

    func enableStrict(hours: Double) async {
        do {
            await syncRules()
            try await helper.send(.enableStrict(cooldownHours: hours))
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    func requestUnlock() async {
        do { try await helper.send(.requestUnlock) } catch { showNotice(error.localizedDescription) }
    }

    func cancelUnlock() async {
        do { try await helper.send(.cancelUnlock) } catch { showNotice(error.localizedDescription) }
    }

    // MARK: Warnings bookkeeping

    func markWarned(_ key: String) -> Bool {
        let full = "\(dayKey())|\(key)"
        if state.warned.contains(full) { return false }
        state.warned.append(full)
        return true
    }
}
