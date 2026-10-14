import SwiftUI

extension UserProfile {
    static let palette: [Color] = [
        Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.93, green: 0.28, blue: 0.60),
        Color(red: 0.20, green: 0.65, blue: 0.95), Color(red: 0.18, green: 0.78, blue: 0.55),
        Color(red: 0.98, green: 0.62, blue: 0.20), Color(red: 0.95, green: 0.33, blue: 0.30),
        Color(red: 0.45, green: 0.50, blue: 0.60), Color(red: 0.98, green: 0.80, blue: 0.25),
    ]
    var color: Color { Self.palette[((colorIndex % Self.palette.count) + Self.palette.count) % Self.palette.count] }
}

struct ProfileAvatar: View {
    var profile: UserProfile
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [profile.color, profile.color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(profile.emoji).font(.system(size: size * 0.5))
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if profile.isKids {
                Text("KIDS").font(.system(size: max(8, size * 0.13), weight: .heavy))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Theme.gold, in: Capsule())
                    .foregroundStyle(.black)
                    .offset(x: 4, y: 4)
            }
        }
    }
}

/// "Who's watching?" — shown at launch when there are several profiles, and from Home/Settings.
struct ProfilePickerView: View {
    var dismissible = false
    var onDone: (() -> Void)?
    private var store: ProfileStore { .shared }
    @State private var pinFor: UserProfile?
    @State private var pinError = false

    private var avatarSize: CGFloat {
        #if os(tvOS)
        return 180
        #else
        return 96
        #endif
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let profile = pinFor {
                PINPadView(title: "Enter \(profile.name)'s PIN", subtitle: nil, error: pinError) { pin in
                    if store.verify(pin: pin, for: profile) {
                        pinFor = nil
                        choose(profile)
                        return true
                    }
                    pinError = true
                    return false
                } onCancel: {
                    pinFor = nil
                    pinError = false
                }
            } else {
                VStack(spacing: 40) {
                    Text("Who's watching?").font(.largeTitle.weight(.heavy))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 30) {
                            ForEach(store.profiles) { profile in
                                Button {
                                    if profile.hasPIN && profile.id != store.activeProfileID {
                                        pinError = false
                                        pinFor = profile
                                    } else {
                                        choose(profile)
                                    }
                                } label: {
                                    VStack(spacing: 12) {
                                        ProfileAvatar(profile: profile, size: avatarSize)
                                        HStack(spacing: 4) {
                                            Text(profile.name).font(.headline)
                                            if profile.hasPIN { Image(systemName: "lock.fill").font(.caption) }
                                        }
                                    }
                                    .padding(12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Theme.gutter)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                    }
                    #if os(tvOS)
                    .scrollClipDisabled()
                    #endif
                    if dismissible {
                        Button("Cancel") { finish() }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func choose(_ profile: UserProfile) {
        store.select(profile.id)
        finish()
    }

    private func finish() {
        store.needsSelection = false
        onDone?()
    }
}

/// On-screen 4-digit keypad; works with the Siri Remote (every key is a focusable button).
struct PINPadView: View {
    var title: String
    var subtitle: String?
    var error: Bool
    /// Return true when the PIN was accepted.
    var onComplete: (String) -> Bool
    var onCancel: () -> Void
    @State private var digits = ""
    @State private var shake = false

    private var keySize: CGFloat {
        #if os(tvOS)
        return 110
        #else
        return 72
        #endif
    }

    var body: some View {
        VStack(spacing: 22) {
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center) }
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < digits.count ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceHigh))
                        .frame(width: 18, height: 18)
                }
            }
            .offset(x: shake ? -10 : 0)
            .animation(.default.repeatCount(3, autoreverses: true).speed(4), value: shake)
            if error && digits.isEmpty {
                Text("Wrong PIN").font(.footnote.weight(.semibold)).foregroundStyle(Theme.live)
            }
            VStack(spacing: 14) {
                ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                    HStack(spacing: 14) {
                        ForEach(row, id: \.self) { n in key("\(n)") }
                    }
                }
                HStack(spacing: 14) {
                    Button(action: onCancel) {
                        Text("Cancel").font(.subheadline.weight(.semibold)).frame(width: keySize, height: keySize)
                    }
                    .buttonStyle(.plain)
                    key("0")
                    Button { if !digits.isEmpty { digits.removeLast() } } label: {
                        Image(systemName: "delete.left").font(.title2).frame(width: keySize, height: keySize)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(30)
    }

    private func key(_ d: String) -> some View {
        Button {
            guard digits.count < 4 else { return }
            digits += d
            if digits.count == 4 {
                let entered = digits
                if !onComplete(entered) {
                    shake.toggle()
                    digits = ""
                }
            }
        } label: {
            Text(d).font(.system(size: keySize * 0.38, weight: .semibold, design: .rounded))
                .frame(width: keySize, height: keySize)
                .background(Theme.surfaceHigh, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Settings require the parent PIN while a kids profile is active.
struct SettingsGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    private var store: ProfileStore { .shared }
    @State private var error = false

    var body: some View {
        if store.settingsLocked {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 10) {
                    PINPadView(title: "Settings are locked", subtitle: "Enter the parent PIN to continue.", error: error) { pin in
                        let ok = store.unlockSettings(pin: pin)
                        error = !ok
                        return ok
                    } onCancel: {
                        error = false
                    }
                    Button { store.needsSelection = true } label: { Label("Switch Profile", systemImage: "person.2") }
                        .buttonStyle(.bordered)
                }
            }
            .navigationTitle("Settings")
        } else {
            content()
        }
    }
}

// MARK: - Settings → Profiles

struct ProfilesSettingsView: View {
    private var store: ProfileStore { .shared }
    @State private var editing: UserProfile?
    @State private var adding = false
    @State private var settingParentPIN = false
    @State private var parentPINStep: String?

    var body: some View {
        List {
            Section {
                ForEach(store.profiles) { profile in
                    Button { editing = profile } label: {
                        HStack(spacing: 14) {
                            ProfileAvatar(profile: profile, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.headline)
                                Text(details(profile)).font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            if profile.id == store.activeProfileID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .contextMenu {
                        Button { store.select(profile.id) } label: { Label("Switch to \(profile.name)", systemImage: "person.crop.circle") }
                        if store.profiles.count > 1 {
                            Button(role: .destructive) { store.delete(profile) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                Button { adding = true } label: { Label("Add Profile", systemImage: "plus.circle.fill") }
            } footer: {
                Text("Each profile has its own My List, favorite channels, recents, watch progress and hidden categories. Trakt is shared.")
            }
            Section {
                Button { store.needsSelection = true } label: { Label("Switch Profile…", systemImage: "person.2") }
                Button { settingParentPIN = true } label: {
                    Label(store.parentPIN.isEmpty ? "Set Parent PIN" : "Change Parent PIN", systemImage: "lock.shield")
                }
                if !store.parentPIN.isEmpty {
                    Button(role: .destructive) { store.parentPIN = "" } label: { Label("Remove Parent PIN", systemImage: "lock.open") }
                }
            } header: {
                Text("Parental controls")
            } footer: {
                Text("Kids profiles hide adult content, show only kids and family channels and titles, and need the parent PIN to open Settings.")
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Profiles")
        .sheet(item: $editing) { ProfileEditor(profile: $0) }
        .sheet(isPresented: $adding) { ProfileEditor(profile: nil) }
        .sheet(isPresented: $settingParentPIN) {
            ZStack {
                Theme.background.ignoresSafeArea()
                PINPadView(title: parentPINStep == nil ? "New parent PIN" : "Repeat the PIN", subtitle: nil, error: false) { pin in
                    if let first = parentPINStep {
                        if first == pin {
                            store.parentPIN = pin
                            parentPINStep = nil
                            settingParentPIN = false
                            return true
                        }
                        parentPINStep = nil
                        return false
                    }
                    parentPINStep = pin
                    return true
                } onCancel: {
                    parentPINStep = nil
                    settingParentPIN = false
                }
                .id(parentPINStep == nil ? "first" : "second")
            }
        }
    }

    private func details(_ p: UserProfile) -> String {
        var parts: [String] = []
        if p.isKids { parts.append("Kids") }
        if p.hasPIN { parts.append("PIN") }
        if p.id == store.activeProfileID { parts.append("Active") }
        return parts.isEmpty ? "Standard" : parts.joined(separator: " · ")
    }
}

struct ProfileEditor: View {
    var profile: UserProfile?
    @Environment(\.dismiss) private var dismiss
    private var store: ProfileStore { .shared }
    @State private var name = ""
    @State private var emoji = "🍿"
    @State private var colorIndex = 0
    @State private var isKids = false
    @State private var allowed: Set<String> = []
    @State private var pin = ""
    @State private var editingPIN = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ProfileAvatar(profile: preview, size: 90)
                        Spacer()
                    }
                    TextField("Name", text: $name)
                }
                Section("Avatar") {
                    Picker("Emoji", selection: $emoji) {
                        ForEach(UserProfile.emojis, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Colour", selection: $colorIndex) {
                        ForEach(0..<UserProfile.palette.count, id: \.self) { i in
                            Text(colorName(i)).tag(i)
                        }
                    }
                }
                Section {
                    Toggle("Kids profile", isOn: $isKids)
                    if isKids, ProfileStore.shared.parentPIN.isEmpty {
                        Text("Set a parent PIN in Settings → Profiles so kids can't open Settings.")
                            .font(.footnote).foregroundStyle(Theme.gold)
                    }
                } footer: {
                    Text("Kids mode hides adult content, shows only kids / family channels and titles (Animation, Family, Kids, or rated up to PG when known).")
                }
                if isKids {
                    Section {
                        ForEach(DispatcharrStore.shared.liveCategoriesForKidsPicker) { cat in
                            Toggle(cat.name, isOn: Binding(get: { allowed.contains(cat.id) || KidsFilter.isKidsCategory(cat.name) },
                                                           set: { on in if on { allowed.insert(cat.id) } else { allowed.remove(cat.id) } }))
                                .disabled(KidsFilter.isKidsCategory(cat.name))
                        }
                    } header: {
                        Text("Allowed channel groups")
                    }
                }
                Section {
                    if editingPIN {
                        SecureField("4-digit PIN (empty for none)", text: $pin)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    } else {
                        Button(pinLabel) { editingPIN = true }
                    }
                } header: {
                    Text("Profile PIN")
                } footer: {
                    Text("Asked when switching to this profile.")
                }
            }
            .navigationTitle(profile == nil ? "New Profile" : "Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!pin.isEmpty && (pin.count != 4 || !pin.allSatisfy(\.isNumber)))
                }
            }
        }
        .onAppear {
            if let profile {
                name = profile.name
                emoji = profile.emoji
                colorIndex = profile.colorIndex
                isKids = profile.isKids
                allowed = Set(profile.allowedCategoryIDs)
                pin = profile.pin
            } else {
                colorIndex = store.profiles.count % UserProfile.palette.count
                emoji = UserProfile.emojis[store.profiles.count % UserProfile.emojis.count]
                editingPIN = true
            }
        }
    }

    private var pinLabel: String { (profile?.hasPIN ?? false) ? "Change PIN" : "Add PIN" }

    private var preview: UserProfile {
        UserProfile(id: profile?.id ?? UUID(), name: name, emoji: emoji, colorIndex: colorIndex, isKids: isKids, allowedCategoryIDs: [])
    }

    private func colorName(_ i: Int) -> String {
        ["Violet", "Pink", "Blue", "Green", "Orange", "Red", "Slate", "Gold"][i % 8]
    }

    private func save() {
        if var p = profile {
            p.name = name.trimmed.isEmpty ? p.name : name.trimmed
            p.emoji = emoji
            p.colorIndex = colorIndex
            p.isKids = isKids
            p.allowedCategoryIDs = Array(allowed)
            if editingPIN { p.pin = pin }
            store.update(p)
        } else {
            let p = store.add(name: name, emoji: emoji, colorIndex: colorIndex, isKids: isKids)
            var updated = p
            updated.allowedCategoryIDs = Array(allowed)
            updated.pin = pin
            store.update(updated)
        }
        dismiss()
    }
}
