import AppKit
import Observation

/// Reads the active tab's address from the frontmost browser via AppleScript, so website time can
/// be tracked. macOS asks once per browser for permission ("SelfControl wants to control …").
@MainActor @Observable
final class BrowserTracker {
    enum Family { case safari, chromium }

    /// Browsers whose tab URLs can be read. Firefox-based browsers don't support this.
    static let supported: [String: (name: String, family: Family)] = [
        "com.apple.Safari": ("Safari", .safari),
        "com.apple.SafariTechnologyPreview": ("Safari Technology Preview", .safari),
        "com.google.Chrome": ("Google Chrome", .chromium),
        "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
        "com.brave.Browser": ("Brave", .chromium),
        "company.thebrowser.Browser": ("Arc", .chromium),
        "com.vivaldi.Vivaldi": ("Vivaldi", .chromium),
        "com.operasoftware.Opera": ("Opera", .chromium),
        "org.chromium.Chromium": ("Chromium", .chromium),
    ]
    static let unsupported: [String: String] = [
        "org.mozilla.firefox": "Firefox", "app.zen-browser.zen": "Zen", "org.mozilla.firefoxdeveloperedition": "Firefox Developer Edition",
    ]

    struct Visit: Equatable {
        var browserID: String
        var host: String
        /// Registrable domain, e.g. "youtube.com" for "m.youtube.com". Usage is counted per domain.
        var domain: String
    }

    /// The active tab of the frontmost supported browser, if it's an http(s) page.
    private(set) var current: Visit?
    /// Browsers the user hasn't allowed SelfControl to read.
    private(set) var deniedBrowsers: Set<String> = []
    /// Browsers successfully read at least once.
    private(set) var workingBrowsers: Set<String> = []
    private(set) var unsupportedInUse: Set<String> = []

    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastPoll = Date.distantPast

    /// Called every tick with the frontmost app. Reads the tab at most every 2 seconds.
    func update(frontmost app: NSRunningApplication?) {
        guard let id = app?.bundleIdentifier, let browser = Self.supported[id] else {
            if let id = app?.bundleIdentifier, Self.unsupported[id] != nil, !unsupportedInUse.contains(id) {
                unsupportedInUse.insert(id)
            }
            if current != nil { current = nil }
            return
        }
        if let current, current.browserID != id { self.current = nil }
        guard !inFlight, Date().timeIntervalSince(lastPoll) >= 2 else { return }
        inFlight = true
        lastPoll = Date()

        let family = browser.family
        Self.queue.async {
            let result = AppleEvents.activeTabURL(browserID: id, family: family)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(result, browserID: id) } }
        }
    }

    private func handle(_ result: Result<String?, AppleEvents.Failure>, browserID id: String) {
        inFlight = false
        switch result {
        case .success(let url):
            if !workingBrowsers.contains(id) { workingBrowsers.insert(id) }
            if deniedBrowsers.contains(id) { deniedBrowsers.remove(id) }
            if let url, let host = Domains.host(ofURL: url), let domain = Domains.registrableDomain(host) {
                let visit = Visit(browserID: id, host: host, domain: domain)
                if current != visit { current = visit }
            } else if current != nil {
                current = nil
            }
        case .failure(let failure):
            if failure == .denied, !deniedBrowsers.contains(id) { deniedBrowsers.insert(id) }
            if current != nil { current = nil }
        }
    }

    /// Points the frontmost browser's active tab at a blank page, so a blocked site stops right away.
    func blankActiveTab(browserID: String) {
        guard let family = Self.supported[browserID]?.family else { return }
        Self.queue.async { AppleEvents.setActiveTabURL(browserID: browserID, family: family, to: "about:blank") }
    }

    /// One serial queue for all Apple Events, so a slow browser never blocks the main thread.
    nonisolated private static let queue = DispatchQueue(label: "browser-tracker", qos: .utility)

    /// Opens System Settings at Privacy & Security → Automation.
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Reads and sets a browser's active-tab URL by sending Apple Events directly. This is the same
/// thing `tell application … to get URL of active tab of front window` does, without starting an
/// osascript process each time (about 1 ms instead of about 80 ms of CPU).
enum AppleEvents {
    enum Failure: Error, Equatable {
        /// errAEEventNotPermitted (-1743): the user declined Automation access.
        case denied
        case other(Int)
    }

    private static func code(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// An object specifier, like AppleScript's "<property> of <container>".
    private static func specifier(want: String, form: String, data: NSAppleEventDescriptor,
                                  from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        spec.setDescriptor(data, forKeyword: code("seld"))
        spec.setDescriptor(container, forKeyword: code("from"))
        return spec
    }

    /// "URL of <active|current> tab of window 1". Codes come from each browser's scripting dictionary.
    private static func urlSpecifier(_ family: BrowserTracker.Family) -> NSAppleEventDescriptor {
        let (tabProperty, urlProperty) = family == .safari ? ("cTab", "pURL") : ("acTa", "URL ")
        let window = specifier(want: "cwin", form: "indx", data: NSAppleEventDescriptor(int32: 1), from: .null())
        let tab = specifier(want: "prop", form: "prop", data: NSAppleEventDescriptor(typeCode: code(tabProperty)), from: window)
        return specifier(want: "prop", form: "prop", data: NSAppleEventDescriptor(typeCode: code(urlProperty)), from: tab)
    }

    private static func event(_ eventClass: String, _ eventID: String, to browserID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(eventID),
                               targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: browserID),
                               returnID: AEReturnID(kAutoGenerateReturnID),
                               transactionID: AETransactionID(kAnyTransactionID))
    }

    private static func send(_ event: NSAppleEventDescriptor) -> Result<NSAppleEventDescriptor, Failure> {
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 2)
            if let errn = reply.paramDescriptor(forKeyword: code("errn"))?.int32Value, errn != 0 {
                return .failure(errn == -1743 ? .denied : .other(Int(errn)))
            }
            return .success(reply)
        } catch {
            let status = (error as NSError).code
            return .failure(status == -1743 ? .denied : .other(status))
        }
    }

    /// The active tab's URL, nil if the browser has no windows, or a failure (e.g. not permitted).
    static func activeTabURL(browserID: String, family: BrowserTracker.Family) -> Result<String?, Failure> {
        let e = event("core", "getd", to: browserID)
        e.setParam(urlSpecifier(family), forKeyword: code("----"))
        switch send(e) {
        case .success(let reply):
            return .success(reply.paramDescriptor(forKeyword: code("----"))?.stringValue)
        case .failure(.other(-1719)), .failure(.other(-1728)):
            return .success(nil)   // no such window/tab: nothing open
        case .failure(let f):
            return .failure(f)
        }
    }

    static func setActiveTabURL(browserID: String, family: BrowserTracker.Family, to url: String) {
        let e = event("core", "setd", to: browserID)
        e.setParam(urlSpecifier(family), forKeyword: code("----"))
        e.setParam(NSAppleEventDescriptor(string: url), forKeyword: code("data"))
        _ = send(e)
    }
}
