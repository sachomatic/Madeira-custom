import SwiftUI

/// One option Madeira reads from Documents/madeira.cfg: a plain key
/// ("vram-mb = 4352") or an environment switch the app exports before Wine
/// starts ("env.MADEIRA_SWAP_COVERAGE = classic"). The list itself is
/// ConfigCatalog.generated.swift, written by build/tools/gen-config-catalog.py
/// from the code that reads each option; check-config-catalog.py fails when it
/// falls behind the code.
struct ConfigOption: Identifiable {
    enum Kind { case bool, int, text, choice }
    struct Choice: Hashable { let value: String; let label: String }

    let key: String
    let title: String
    let kind: Kind
    let defaultValue: String
    let category: String
    let note: String
    let choices: [Choice]
    let sources: [String]
    var id: String { key }
    var displayTitle: String { title.isEmpty ? key : title }

    init(key: String, title: String, kind: Kind, defaultValue: String, category: String, note: String,
         choices: [(String, String)], sources: [String]) {
        self.key = key; self.title = title; self.kind = kind; self.defaultValue = defaultValue
        self.category = category; self.note = note; self.sources = sources
        self.choices = choices.map { Choice(value: $0.0, label: $0.1) }
    }
}

enum ConfigCatalog {
    /// Categories in the order the catalog lists them.
    static let categories: [String] = {
        var seen = Set<String>()
        return generated.map(\.category).filter { seen.insert($0).inserted }
    }()
    static let keys = Set(generated.map(\.key))

    /// Options whose key, title, note or category contains `query` (case-insensitive).
    static func search(_ query: String, limit: Int = .max) -> [ConfigOption] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Array(generated.filter { o in
            [o.key, o.title, o.note, o.category].contains { $0.localizedCaseInsensitiveContains(q) }
        }.prefix(limit))
    }

    /// Autocomplete: options whose key starts with `typed` first, then those that
    /// merely contain it in the key or title. The exact key itself is left out.
    static func suggest(_ typed: String, limit: Int = 8) -> [ConfigOption] {
        let t = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return [] }
        let starts = generated.filter { $0.key.lowercased().hasPrefix(t) }
        let contains = generated.filter {
            !$0.key.lowercased().hasPrefix(t) && ($0.key.lowercased().contains(t) || $0.title.lowercased().contains(t))
        }
        return Array((starts + contains).filter { $0.key.lowercased() != t }.prefix(limit))
    }
}

/// Reads and edits "key = value" lines in a plain text in madeira.cfg's syntax,
/// such as a library game's own config (LibraryEntry.config). Comments and every
/// other line are kept; setting a key drops its earlier lines (the last line wins).
enum GameCfgText {
    static func value(_ key: String, in text: String) -> String? { MadeiraConfig.parse(text)[key] }

    static func setting(_ key: String, to value: String?, in text: String) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
        while lines.last == "" { lines.removeLast() }
        lines.removeAll { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return false }
            return t[..<eq].trimmingCharacters(in: .whitespaces) == key
        }
        if let value { lines.append("\(key) = \(value)") }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

/// A row of tappable option keys that complete what is being typed.
struct ConfigKeySuggestions: View {
    let typed: String
    let pick: (ConfigOption) -> Void

    var body: some View {
        let hits = ConfigCatalog.suggest(typed)
        if !hits.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(hits) { option in
                        Button { pick(option) } label: {
                            Text(option.key).font(.caption.monospaced())
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Settings › All settings: every catalogued option, editable in place.
/// Writing goes through MadeiraConfig.set, which keeps comments and every other
/// line of madeira.cfg; an option set back to Default is removed from the file.
struct AllSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = MadeiraConfig.all()
    @State private var search = ""
    @State private var changed = false
    @State private var newKey = ""
    @State private var newValue = ""

    private func matches(_ o: ConfigOption) -> Bool {
        search.isEmpty || [o.key, o.title, o.note, o.category].contains { $0.localizedCaseInsensitiveContains(search) }
    }
    private var otherKeys: [String] {
        values.keys.filter { !ConfigCatalog.keys.contains($0) && (search.isEmpty || $0.localizedCaseInsensitiveContains(search)) }.sorted()
    }

    private func binding(_ key: String) -> Binding<String?> {
        Binding(get: { values[key] }, set: { new in
            let v = new?.trimmingCharacters(in: .whitespaces)
            let stored = (v?.isEmpty ?? true) ? nil : v
            guard stored != values[key] else { return }
            MadeiraConfig.set(key, stored)
            values = MadeiraConfig.all()
            changed = true
            LogStore.shared.log("[all-settings] \(key) = \(stored ?? "(default)")")
        })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Every other option Madeira reads from madeira.cfg. JIT pool, video memory, the swap tier, the sync engine and eco mode are in Settings › Memory & sync. Most options are read when Madeira starts, so close it from the app switcher after a change. Default leaves the option out of the file. Swipe left on a row to reset it.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if changed {
                        Text("Restart Madeira (close it from the app switcher) for changes to apply.").font(.footnote).foregroundStyle(.orange)
                    }
                }
                ForEach(ConfigCatalog.categories, id: \.self) { category in
                    let options = ConfigCatalog.generated.filter {
                        $0.category == category && !RuntimeMemorySyncSettings.featuredKeys.contains($0.key) && matches($0)
                    }
                    if !options.isEmpty {
                        Section(category) {
                            ForEach(options) { ConfigOptionRow(option: $0, value: binding($0.key)) }
                        }
                    }
                }
                if !otherKeys.isEmpty {
                    Section {
                        ForEach(otherKeys, id: \.self) { key in
                            ConfigOptionRow(option: ConfigOption(key: key, title: "", kind: .text, defaultValue: "",
                                                                 category: "", note: "", choices: [], sources: []),
                                            value: binding(key))
                        }
                    } header: { Text("Other entries in madeira.cfg") } footer: {
                        Text("Set in your madeira.cfg but not read by name in Madeira's code, for example FEX options passed as env.FEX_*.")
                    }
                }
                Section {
                    TextField("key, or env.NAME", text: $newKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    ConfigKeySuggestions(typed: newKey) { newKey = $0.key }
                    TextField("value", text: $newValue)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    Button("Add to madeira.cfg") {
                        let k = newKey.trimmingCharacters(in: .whitespaces)
                        guard !k.isEmpty, !k.contains("="), !k.hasPrefix("#") else { return }
                        binding(k).wrappedValue = newValue
                        newKey = ""; newValue = ""
                    }
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { Text("Add an entry") } footer: {
                    Text("For anything not listed, such as env.FEX_TSOENABLED = 1.")
                }
            }
            .searchable(text: $search, prompt: "Search options")
            .navigationTitle("All settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { values = MadeiraConfig.all() }
        }
    }
}

/// One option: its control, what the code says about it, its key and default.
struct ConfigOptionRow: View {
    let option: ConfigOption
    @Binding var value: String?
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if !option.note.isEmpty {
                Text(option.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !option.title.isEmpty { Text(option.key).font(.caption2.monospaced()) }
                if !option.defaultValue.isEmpty { Text("default \(option.defaultValue)").font(.caption2) }
                if value != nil { Text("set").font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
            }
            .foregroundStyle(.secondary)
        }
        .swipeActions {
            if value != nil { Button("Reset", role: .destructive) { value = nil; draft = "" } }
        }
    }

    @ViewBuilder private var control: some View {
        switch option.kind {
        case .bool:
            Picker(option.displayTitle, selection: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 })) {
                Text("Default").tag("")
                Text("On").tag("1")
                Text("Off").tag("0")
                if let v = value, !["1", "0"].contains(v) { Text(v).tag(v) }
            }
        case .choice:
            Picker(option.displayTitle, selection: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 })) {
                ForEach(option.choices, id: \.self) { Text($0.label).tag($0.value) }
                if let v = value, !option.choices.contains(where: { $0.value == v }) { Text("Custom: \(v)").tag(v) }
            }
        case .int, .text:
            HStack {
                Text(option.displayTitle).lineLimit(2)
                Spacer(minLength: 12)
                TextField("Default", text: $draft)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(option.kind == .int ? .numbersAndPunctuation : .default)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    .focused($editing)
                    .onSubmit { value = draft }
                    .frame(maxWidth: 170)
            }
            .onAppear { draft = value ?? "" }
            .onChange(of: value) { _, v in if !editing { draft = v ?? "" } }
            .onChange(of: editing) { _, on in if !on, draft != (value ?? "") { value = draft } }
        }
    }
}

/// Settings search: the All settings options that match, editable in place.
/// The options with a row of their own in Settings › Memory & sync are left out.
struct SettingsSearchResults: View {
    let query: String
    /// Bumped when a Settings sheet closes, so the rows re-read madeira.cfg.
    var refresh = 0
    @State private var values: [String: String] = MadeiraConfig.all()
    private static let limit = 60

    private var hits: [ConfigOption] {
        ConfigCatalog.generated.filter { o in
            !RuntimeMemorySyncSettings.featuredKeys.contains(o.key)
                && [o.key, o.title, o.note, o.category].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private func binding(_ key: String) -> Binding<String?> {
        Binding(get: { values[key] }, set: { new in
            let v = new?.trimmingCharacters(in: .whitespaces)
            let stored = (v?.isEmpty ?? true) ? nil : v
            guard stored != values[key] else { return }
            MadeiraConfig.set(key, stored)
            values = MadeiraConfig.all()
            LogStore.shared.log("[settings-search] \(key) = \(stored ?? "(default)")")
        })
    }

    var body: some View {
        let hits = self.hits
        Section {
            if hits.isEmpty {
                Text("No other options match \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
            }
            ForEach(hits.prefix(Self.limit)) { ConfigOptionRow(option: $0, value: binding($0.key)) }
        } header: {
            Text(hits.isEmpty ? "Options" : "Options (\(hits.count))")
        } footer: {
            if hits.count > Self.limit {
                Text("Showing \(Self.limit) of \(hits.count). Refine the search, or open All settings.")
            } else if !hits.isEmpty {
                Text("Most options are read when Madeira starts: close it from the app switcher after a change.")
            }
        }
        .onChange(of: refresh) { _, _ in values = MadeiraConfig.all() }
    }
}

/// Game details › This game's config: find any catalogued option by name or
/// description and set it with its own control. The values land in the game's
/// own lines (the `config` text), never in madeira.cfg.
struct GameConfigOptionSearch: View {
    @Binding var config: String
    @State private var query = ""
    private static let limit = 25

    private func binding(_ key: String) -> Binding<String?> {
        Binding(get: { GameCfgText.value(key, in: config) }, set: { new in
            let v = new?.trimmingCharacters(in: .whitespaces)
            let stored = (v?.isEmpty ?? true) ? nil : v
            guard stored != GameCfgText.value(key, in: config) else { return }
            config = GameCfgText.setting(key, to: stored, in: config)
        })
    }

    var body: some View {
        let hits = ConfigCatalog.search(query)
        Section {
            TextField("Search options (swap, vram, sync, fex…)", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !query.trimmingCharacters(in: .whitespaces).isEmpty && hits.isEmpty {
                Text("No option matches \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
            }
            ForEach(hits.prefix(Self.limit)) { ConfigOptionRow(option: $0, value: binding($0.key)) }
        } header: { Text(hits.isEmpty ? "Find an option" : "Options (\(hits.count))") } footer: {
            Text(hits.count > Self.limit ? "Showing \(Self.limit) of \(hits.count). Refine the search."
                 : "A value set here is for this game only and wins over madeira.cfg. Swipe left on a row to reset it.")
        }
    }
}

/// Game details › Memory: this game's own swap tier, video memory and video
/// budget trim, as sliders. They write swap-mb, env.MADEIRA_SWAP_COVERAGE,
/// vram-mb and vram-trim-mb into the game's own config lines, which win over
/// Settings › Memory & sync (the runtime reads the game's lines after madeira.cfg).
struct GameMemorySettings: View {
    @Binding var config: String

    private struct SliderRow: View {
        let title: String
        let key: String
        @Binding var config: String
        let range: ClosedRange<Double>
        let step: Double
        let defaultValue: Int
        let defaultText: String
        let format: (Int) -> String

        private var stored: Int? { GameCfgText.value(key, in: config).flatMap { Int($0) } }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(stored.map(format) ?? defaultText)
                        .foregroundStyle(stored == nil ? .secondary : .primary).monospacedDigit()
                    if stored != nil {
                        Button("Reset") { config = GameCfgText.setting(key, to: nil, in: config) }
                            .font(.caption).buttonStyle(.borderless)
                    }
                }
                Slider(value: Binding(get: { Double(stored ?? defaultValue) }, set: { v in
                    let i = Int(v.rounded())
                    config = GameCfgText.setting(key, to: i == defaultValue ? nil : String(i), in: config)
                }), in: range, step: step)
            }
        }
    }

    private static let coverageKey = "env.MADEIRA_SWAP_COVERAGE"
    private var swapDefaultText: String {
        let g = RuntimeMemorySyncSettings.intKey("swap-mb")
        return g > 0 ? "Default (\(RuntimeMemorySyncSettings.gb(g)) from Settings)" : "Default (off)"
    }
    private var vramDefaultText: String {
        let g = RuntimeMemorySyncSettings.intKey("vram-mb")
        return g > 0 ? "Default (\(RuntimeMemorySyncSettings.gb(g)) from Settings)" : "Default (automatic)"
    }
    private static let gameKeys = ["swap-mb", coverageKey, "vram-mb", "vram-trim-mb"]

    var body: some View {
        Section {
            SliderRow(title: "Swap tier", key: "swap-mb", config: $config, range: 0...8192, step: 512,
                      defaultValue: 0, defaultText: swapDefaultText,
                      format: { $0 == 0 ? "Off" : RuntimeMemorySyncSettings.gb($0) })
            Picker("Swap coverage", selection: Binding(
                get: { GameCfgText.value(Self.coverageKey, in: config) ?? "" },
                set: { config = GameCfgText.setting(Self.coverageKey, to: $0.isEmpty ? nil : $0, in: config) })) {
                Text("Default (from Settings)").tag("")
                Text("Large allocations (8 MB+)").tag("classic")
                ForEach(RuntimeMemorySyncSettings.coverageChoices.filter { !$0.0.isEmpty }, id: \.0) { Text($0.1).tag($0.0) }
                if let v = GameCfgText.value(Self.coverageKey, in: config),
                   !["", "classic"].contains(v), !RuntimeMemorySyncSettings.coverageChoices.contains(where: { $0.0 == v }) {
                    Text(v).tag(v)
                }
            }
            SliderRow(title: "Video memory", key: "vram-mb", config: $config, range: 0...6144, step: 256,
                      defaultValue: 0, defaultText: vramDefaultText,
                      format: { RuntimeMemorySyncSettings.gb($0) })
            SliderRow(title: "Shrink video budget early", key: "vram-trim-mb", config: $config, range: 0...3072, step: 128,
                      defaultValue: 1536, defaultText: "Default (1.5 GB)",
                      format: { $0 == 0 ? "Never" : RuntimeMemorySyncSettings.gb($0) })
            Button {
                var t = config
                t = GameCfgText.setting("swap-mb", to: "3072", in: t)
                t = GameCfgText.setting(Self.coverageKey, to: "broad", in: t)
                t = GameCfgText.setting("vram-mb", to: "1536", in: t)
                config = t
            } label: { Label("Heavy-game preset: 3 GB swap, broad coverage, 1.5 GB video", systemImage: "memorychip") }
            if Self.gameKeys.contains(where: { GameCfgText.value($0, in: config) != nil }) {
                Button("Clear this game's memory settings", role: .destructive) {
                    var t = config
                    for k in Self.gameKeys { t = GameCfgText.setting(k, to: nil, in: t) }
                    config = t
                }
            }
        } header: { Text("Memory") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("For a game that iOS closes for using too much memory. Swap tier moves game data to a file on this device's storage, up to the chosen size, at some speed cost; Broad coverage moves the most. Video memory is how much graphics memory the game is told it has: lower makes it keep less in memory. Shrink video budget early starts lowering that budget this far below the memory limit: higher is safer.")
                Text("Swap coverage matters only while a swap tier is on, here or in Settings. These values are for this game only and win over Settings › Memory & sync. They are read when the game starts; if another game ran since Madeira opened, close Madeira from the app switcher first.")
            }
        }
    }
}
