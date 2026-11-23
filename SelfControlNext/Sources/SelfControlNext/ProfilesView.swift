import SwiftUI

// MARK: - Templates

enum ProfileTemplates {
    static let all: [FocusList] = [
        FocusList(name: "Work", symbol: "briefcase.fill", color: "indigo", mode: .exempt,
                  blockedWebsites: ["instagram.com", "tiktok.com", "netflix.com", "youtube.com", "reddit.com", "x.com"]),
        FocusList(name: "Studying", symbol: "graduationcap.fill", color: "blue", mode: .allowlist,
                  allowedWebsites: ["instructure.com"]),
        FocusList(name: "Social Media Break", symbol: "leaf.fill", color: "green", mode: .exempt,
                  blockedApps: [AppRef(bundleID: "com.hnc.Discord", name: "Discord", path: "/Applications/Discord.app")],
                  blockedWebsites: ["instagram.com", "tiktok.com", "x.com", "facebook.com", "snapchat.com", "reddit.com"]),
    ]
}

// MARK: - Profiles

/// Profiles are Focus Lists you switch on and off whenever you like: no timer, and no lock.
struct ProfilesView: View {
    @Environment(Store.self) private var store
    @State private var editing: FocusList?
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profiles").font(.title2.weight(.semibold))
                    Text("Sets of apps and websites to block, like Work or Studying. Turn one on when you need it and off whenever you want. There's no timer.")
                        .foregroundStyle(.secondary)
                }

                ActiveProfileBanner()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(store.config.profiles) { profile in
                        ProfileCard(profile: profile, edit: { editing = profile })
                    }
                    NewProfileCard(
                        create: { creating = true },
                        addTemplate: { template in
                            var copy = template
                            copy.id = UUID()
                            store.config.profiles.append(copy)
                        }
                    )
                }

                Label("Profiles are enforced by SelfControl itself, so it needs to be running. Blocked websites are cleared from the tab in Safari, Chrome, Edge, Brave, Arc, Vivaldi and Opera.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem {
                Button { creating = true } label: { Label("New Profile", systemImage: "plus") }
                    .help("Create a profile")
            }
        }
        .sheet(item: $editing) { profile in
            FocusListEditor(original: profile, isProfile: true)
        }
        .sheet(isPresented: $creating) {
            FocusListEditor(original: nil, isProfile: true)
        }
    }
}

private struct ActiveProfileBanner: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let profile = store.activeProfile {
            let tint = ListStyle.color(profile.color)
            HStack(spacing: 12) {
                SymbolBadge(symbol: profile.symbol, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(profile.name) is on").font(.headline)
                    if let since = store.state.profileActivatedAt {
                        Text("Since \(since.formatted(date: Calendar.current.isDateInToday(since) ? .omitted : .abbreviated, time: .shortened))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Turn Off") { withAnimation(.snappy) { store.deactivateProfile() } }
                    .controlSize(.large)
            }
            .padding(14)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.4)))
        }
    }
}

private struct ProfileCard: View {
    @Environment(Store.self) private var store
    let profile: FocusList
    let edit: () -> Void

    private var isOn: Bool { store.activeProfile?.id == profile.id }

    var body: some View {
        let tint = ListStyle.color(profile.color)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SymbolBadge(symbol: profile.symbol, tint: tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.headline)
                    Text(profile.mode.shortTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.18)))
                        .foregroundStyle(tint)
                }
                Spacer()
                if isOn {
                    Label("On", systemImage: "circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                summaryRow(symbol: "nosign", tint: .red, label: "Blocks",
                           items: profile.blockedApps.map(\.name) + profile.blockedWebsites,
                           empty: profile.mode == .allowlist ? "Everything not allowed" : "Nothing")
                summaryRow(symbol: "checkmark.circle", tint: .green, label: "Allows",
                           items: profile.allowedApps.map(\.name) + profile.allowedWebsites, empty: "Nothing")
            }

            HStack {
                Button("Edit", action: edit)
                Spacer()
                if isOn {
                    Button("Turn Off") { withAnimation(.snappy) { store.deactivateProfile() } }
                } else {
                    Button {
                        withAnimation(.snappy) { store.activateProfile(profile) }
                    } label: {
                        Label(store.activeProfile == nil ? "Turn On" : "Switch To", systemImage: "power")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.separator.opacity(0.5)), lineWidth: isOn ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }

    private func summaryRow(symbol: String, tint: Color, label: String, items: [String], empty: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            Text(label).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(items.isEmpty ? empty : summary(items)).lineLimit(2)
        }
        .font(.callout)
    }

    private func summary(_ items: [String]) -> String {
        items.count <= 3 ? items.joined(separator: ", ")
            : items.prefix(3).joined(separator: ", ") + " +\(items.count - 3) more"
    }
}

private struct NewProfileCard: View {
    let create: () -> Void
    let addTemplate: (FocusList) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: create) {
                VStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("New Profile").font(.headline)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu("Add from Templates") {
                ForEach(ProfileTemplates.all) { template in
                    Button(template.name) { addTemplate(template) }
                }
            }
            .fixedSize()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(.separator))
    }
}
