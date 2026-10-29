import AppKit
import PartsClient
import SwiftUI
import UniformTypeIdentifiers

/// The first-run setup: parts sources (the user's own API keys), iCloud, and connecting Claude. Every step can be
/// skipped; Loomo works without any of it. Reopen it from Loomo ▸ Set Up Loomo… or Settings.
struct SetupAssistant: View {
    static let completedKey = "setup.completed"
    static var completed: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    enum Step: Int, CaseIterable {
        case welcome, parts, icloud, claude, done
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .parts: "Parts sources"
            case .icloud: "iCloud"
            case .claude: "Claude"
            case .done: "Done"
            }
        }
    }

    @State private var step = Step.welcome
    @State private var importNote: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 18)
            Group {
                switch step {
                case .welcome: welcome
                case .parts: parts
                case .icloud: icloud
                case .claude: claude
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            Divider()
            footer.padding(16)
        }
        .frame(width: 620, height: 600)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 40, height: 4)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome, step != .done {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            switch step {
            case .welcome: Button("Get Started") { step = .parts }.keyboardShortcut(.defaultAction)
            case .done: Button("Start Using Loomo") { finish() }.keyboardShortcut(.defaultAction)
            default:
                Button("Skip") { advance() }
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func advance() { step = Step(rawValue: step.rawValue + 1) ?? .done }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        openWindow(id: "welcome")
        dismissWindow(id: "setup")
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Welcome to Loomo").font(.largeTitle.weight(.semibold))
            Text("Loomo designs wire harnesses: connectors, wires, bundles and splices, with lengths, a bill of materials, rule checks and print-ready drawings.")
                .fixedSize(horizontal: false, vertical: true)
            Text("A few optional things to set up. Each takes a minute, and you can skip any of them and come back later from Settings.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Label("Parts sources: search distributors for parts, photos and prices", systemImage: "magnifyingglass")
                Label("iCloud: keep projects on all your Macs", systemImage: "icloud")
                Label("Claude: let an AI assistant edit harnesses with you", systemImage: "sparkles")
            }
            .padding(.top, 6)
        }
    }

    private var parts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Parts sources").font(.title2.weight(.semibold))
            Text("Loomo looks parts up with your own API keys from the distributors below. Each is free to sign up for. Add one or more; keys stay in your Mac's Keychain and go only to that distributor.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(PartsCredentials.sources) { PartsSourceForm(source: $0) }
                }
                .padding(.vertical, 6)
                .padding(.trailing, 8)
            }
            HStack {
                Button("Import from .env File…") { importEnv() }
                if let importNote { Text(importNote).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var icloud: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iCloud").font(.title2.weight(.semibold))
            if CloudDocuments.folder != nil {
                Label("iCloud Drive is on.", systemImage: "checkmark.icloud").foregroundStyle(.green)
                Text("New projects go to iCloud Drive ▸ Loomo and save automatically, so they're on every Mac signed in to your Apple ID. You can change this in Settings ▸ iCloud Drive.")
                    .fixedSize(horizontal: false, vertical: true)
                CloudDocumentsSettings().labelsHidden()
            } else {
                Label("iCloud isn't available.", systemImage: "icloud.slash").foregroundStyle(.secondary)
                Text("Loomo works without it: projects save wherever you choose. To use iCloud Drive, sign in to iCloud in System Settings and turn on iCloud Drive, then reopen Loomo.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open iCloud Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane")!)
                }
            }
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude").font(.title2.weight(.semibold))
            Text("Claude, or any app that supports the Model Context Protocol, can read and edit the harness open in Loomo while you watch. It all runs on this Mac: each edit is one undo step, and nothing is reachable from the network.")
                .fixedSize(horizontal: false, vertical: true)
            Form { AIClientsSettings() }.formStyle(.grouped).scrollDisabled(true)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're set").font(.largeTitle.weight(.semibold))
            let sources = PartsCredentials.settings.configured.compactMap { PartsProvider(rawValue: $0)?.title }
            Label(sources.isEmpty ? "Parts search: your library and a sample catalog (add keys any time in Settings)"
                                  : "Parts search: \(sources.joined(separator: ", "))", systemImage: "magnifyingglass")
            Label(CloudDocuments.folder != nil && CloudDocuments.enabled ? "New projects save to iCloud Drive" : "Projects save where you choose",
                  systemImage: "icloud")
            Text("Press ⌘N to start a harness, or open an existing project from the welcome window.")
                .foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    private func importEnv() {
        let panel = NSOpenPanel()
        panel.message = "Choose a .env file with your parts API keys (for example backend/.env from an older source checkout)."
        panel.showsHiddenFiles = true
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let found = try PartsCredentials.importEnv(url)
            importNote = found.isEmpty ? "No parts keys found in that file." : "Imported keys for \(found.compactMap { PartsProvider(rawValue: $0 == "nexar" ? "octopart" : $0)?.title }.joined(separator: ", "))."
            // Show the imported keys in the forms.
            step = .icloud
            step = .parts
        } catch {
            importNote = "Couldn't read that file: \(error.localizedDescription)"
        }
    }
}
