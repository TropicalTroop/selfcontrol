import SwiftUI

struct WebsiteLimitsView: View {
    @Environment(Store.self) private var store
    let select: (SidebarItem) -> Void
    @State private var editing: SiteLimitSheetItem?

    var body: some View {
        @Bindable var store = store
        let websites = store.config.websites
        Form {
            Section {
                HStack(spacing: 14) {
                    SymbolBadge(symbol: "globe", tint: .teal, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Website Limits").font(.title3.weight(.semibold))
                        Text("SelfControl keeps track of the sites you use. Any site that goes over its daily limit asks whether it's a good time, then gets blocked in every browser until midnight.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Website limits", isOn: $store.config.websites.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.vertical, 4)

                LabeledContent {
                    HStack {
                        if websites.limitAllSites {
                            DurationPicker(minutes: $store.config.websites.minutesPerSite)
                        }
                        Toggle("Limit every other website", isOn: $store.config.websites.limitAllSites)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                } label: {
                    Text("Limit for every other website")
                    Text(websites.limitAllSites ? "Each site without its own limit gets this much time a day."
                                                : "Only sites with their own limit are limited.")
                }
                .disabled(!websites.enabled)

                StrictModeRow()
                HelperRequiredRow(reason: "Without the helper, SelfControl can only close a blocked site's tab. Install the helper to block sites in every browser and app.")
            }

            Section {
                ForEach(websites.siteLimits) { limit in
                    SiteLimitRow(limit: limit) { editing = SiteLimitSheetItem(limit: limit, isNew: false) }
                }
                Button {
                    editing = SiteLimitSheetItem(limit: store.newSiteLimit(domain: ""), isNew: true)
                } label: {
                    Label("Add Website Limit…", systemImage: "plus")
                }
                .buttonStyle(.link)
            } header: {
                Text("Limits for specific websites")
            } footer: {
                Text("A site's own limit replaces the limit for every other website, and covers its subdomains. Set one per weekday to allow more time on weekends.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!websites.enabled)

            browserSection

            Section {
                let sites = store.topSites()
                if sites.isEmpty {
                    Text("No websites tracked yet today.").foregroundStyle(.secondary)
                }
                ForEach(sites, id: \.domain) { site in
                    SiteRow(domain: site.domain, seconds: site.seconds,
                            limit: websites.limitSeconds(for: site.domain),
                            blockedUntil: store.helper.status?.websiteBlocks[site.domain],
                            whitelisted: websites.isWhitelisted(host: site.domain),
                            editLimit: { editSiteLimit(for: site.domain) })
                }
            } header: {
                Text("Today")
            } footer: {
                Text("Time counts while a site is the active tab of the browser in front, even if you're just watching. Whitelisted sites aren't counted.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button {
                    editing = SiteLimitSheetItem(limit: store.newSiteLimit(domain: ""), isNew: true)
                } label: { Label("Add Website Limit", systemImage: "plus") }
                    .help("Add a limit for a specific website")
            }
        }
        .sheet(item: $editing) { item in
            SiteLimitEditorSheet(original: item.limit, isNew: item.isNew)
        }
    }

    private func editSiteLimit(for domain: String) {
        if let existing = store.config.websites.siteLimits.first(where: { Domains.matches(domain, $0.domain) }) {
            editing = SiteLimitSheetItem(limit: existing, isNew: false)
        } else {
            editing = SiteLimitSheetItem(limit: store.newSiteLimit(domain: domain), isNew: true)
        }
    }

    @ViewBuilder
    private var browserSection: some View {
        let browser = store.browser
        if !browser.deniedBrowsers.isEmpty || !browser.unsupportedInUse.isEmpty || browser.workingBrowsers.isEmpty {
            Section("Browsers") {
                ForEach(Array(browser.deniedBrowsers).sorted(), id: \.self) { id in
                    HStack {
                        Label("SelfControl isn't allowed to read \(BrowserTracker.supported[id]?.name ?? id)'s tabs.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings…") { BrowserTracker.openAutomationSettings() }
                    }
                }
                ForEach(Array(browser.unsupportedInUse).sorted(), id: \.self) { id in
                    Label("\(BrowserTracker.unsupported[id] ?? id) doesn't let other apps read its tabs, so time there isn't tracked.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                if browser.workingBrowsers.isEmpty && browser.deniedBrowsers.isEmpty {
                    Label("Works with Safari, Chrome, Edge, Brave, Arc, Vivaldi and Opera. The first time you use one, macOS asks whether SelfControl may read its tabs. Choose Allow.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SiteRow: View {
    @Environment(Store.self) private var store
    let domain: String
    let seconds: TimeInterval
    let limit: TimeInterval?
    let blockedUntil: Date?
    let whitelisted: Bool
    let editLimit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TargetIcon(target: .website(domain), size: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(domain).font(.body.weight(.medium))
                    if blockedUntil != nil {
                        Text("Blocked").font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.red.opacity(0.2)))
                            .foregroundStyle(.red)
                    } else if whitelisted {
                        Text("Whitelisted").font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.green.opacity(0.2)))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Text(limit.map { "\(formatDuration(seconds)) of \(formatDuration($0))" } ?? formatDuration(seconds))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if !whitelisted { UsageBar(used: seconds, limit: limit) }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            let hasOwn = store.config.websites.siteLimits.contains { Domains.matches(domain, $0.domain) }
            Button(hasOwn ? "Edit Limit…" : "Set a Limit for This Site…", action: editLimit)
                .disabled(whitelisted)
            Button("Add to Whitelist") {
                if !store.config.websites.whitelist.contains(domain) { store.config.websites.whitelist.append(domain) }
            }
            .disabled(whitelisted)
        }
    }
}

private struct SiteLimitSheetItem: Identifiable {
    var limit: SiteLimit
    var isNew: Bool
    var id: String { (isNew ? "new|" : "") + limit.domain }
}

private struct SiteLimitRow: View {
    @Environment(Store.self) private var store
    let limit: SiteLimit
    let edit: () -> Void

    var body: some View {
        let used = store.webUsage(for: limit.domain)
        let total = store.config.websites.enabled ? limit.limitSeconds(on: Date()) : nil
        let cantDisable = !store.strictProblems(replacingSite: limit, with: { var c = limit; c.enabled = false; return c }()).isEmpty
        let cantDelete = !store.strictProblems(replacingSite: limit, with: nil).isEmpty
        HStack(spacing: 12) {
            TargetIcon(target: .website(limit.domain), size: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(limit.domain).font(.body.weight(.medium))
                    if cantDelete {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .help("Locked by Strict Mode")
                    }
                    Spacer()
                    Text(total.map { "\(formatDuration(used)) of \(formatDuration($0))" } ?? "\(formatDuration(used)) today")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if limit.enabled { UsageBar(used: used, limit: total) }
                Text(limit.enabled ? limit.summary : "Paused, so the limit for every other website applies")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Enabled", isOn: Binding(
                get: { limit.enabled },
                set: { newValue in
                    if let i = store.config.websites.siteLimits.firstIndex(where: { $0.id == limit.id }) {
                        store.config.websites.siteLimits[i].enabled = newValue
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(cantDisable && limit.enabled)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Delete", role: .destructive) {
                store.config.websites.siteLimits.removeAll { $0.id == limit.id }
            }
            .disabled(cantDelete)
        }
    }
}

private struct SiteLimitEditorSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let original: SiteLimit
    let isNew: Bool
    @State private var draft: SiteLimit
    @State private var domainEntry: String
    @State private var error: String?

    init(original: SiteLimit, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _draft = State(initialValue: original)
        _domainEntry = State(initialValue: original.domain)
    }

    var body: some View {
        let locked = !isNew && !store.strictProblems(replacingSite: original, with: nil).isEmpty
        let domain = isNew ? Self.domain(from: domainEntry) : original.domain
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                TargetIcon(target: .website(domain ?? "website"), size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    if isNew {
                        TextField("Website", text: $domainEntry, prompt: Text("Website, like youtube.com"))
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .onChange(of: domainEntry) { error = nil }
                    } else {
                        Text(original.domain).font(.title2.weight(.semibold))
                    }
                    if let domain {
                        Text("Used \(formatDuration(store.webUsage(for: domain))) today")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)

            Form {
                AllowanceFields(allowance: $draft)

                if locked {
                    Section {
                        Label("Strict Mode is on, so this limit can be lowered but not raised or removed.",
                              systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 20)
            }

            HStack {
                if !isNew {
                    Button("Delete Limit", role: .destructive) {
                        store.config.websites.siteLimits.removeAll { $0.id == original.id }
                        dismiss()
                    }
                    .disabled(locked)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isNew && domainEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: draft.customDays ? 640 : 440)
        .animation(.snappy, value: draft.customDays)
    }

    /// Site limits are kept per registrable domain, the same way website time is recorded.
    private static func domain(from entry: String) -> String? {
        guard let normalized = Domains.normalize(entry), !Domains.isIPRange(normalized) else { return nil }
        return Domains.registrableDomain(normalized) ?? normalized
    }

    private func save() {
        var limit = draft
        if isNew {
            guard let domain = Self.domain(from: domainEntry) else {
                error = "That doesn't look like a website address."
                return
            }
            if store.config.websites.siteLimits.contains(where: { $0.domain == domain }) {
                error = "\(domain) already has its own limit."
                return
            }
            if store.config.websites.isWhitelisted(host: domain) {
                error = "\(domain) is on the Website Whitelist, so it's never limited."
                return
            }
            limit.domain = domain
        }
        let problems = store.strictProblems(replacingSite: isNew ? nil : original, with: limit)
        if !problems.isEmpty {
            error = "Strict Mode is on, so you can't \(problems.formatted(.list(type: .or)))."
            return
        }
        if isNew {
            store.config.websites.siteLimits.append(limit)
            store.config.websites.siteLimits.sort { $0.domain < $1.domain }
        } else if let i = store.config.websites.siteLimits.firstIndex(where: { $0.id == original.id }) {
            store.config.websites.siteLimits[i] = limit
        }
        dismiss()
    }
}

struct WebsiteWhitelistView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                HStack(spacing: 14) {
                    SymbolBadge(symbol: "checkmark.shield.fill", tint: .green, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Website Whitelist").font(.title3.weight(.semibold))
                        Text("Sites here never count toward website limits and are never blocked by them. Subdomains are included: whitelisting github.com also covers gist.github.com.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                StrictModeRow()
            }

            Section {
                if store.config.websites.whitelist.isEmpty {
                    Text("No whitelisted sites yet.").foregroundStyle(.secondary)
                }
                WebsiteListEditor(websites: $store.config.websites.whitelist)
            } header: {
                Text("Always allowed")
            } footer: {
                Text("The whitelist only affects website limits. Focus Sessions and Downtime can still block these sites.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
