import LibraryCore
import Metadata
import Security
import SwiftUI

/// IGDB proxy settings. The address lives in UserDefaults; the shared key in the Keychain.
enum IGDBSettings {
    static let urlKey = "igdbProxyURL"
    private static let keychainService = "\(AppIdentity.bundleIdentifier).igdb"

    static var proxyURL: URL? {
        get { UserDefaults.standard.string(forKey: urlKey).flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil } }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: urlKey) }
    }

    static var appKey: String? {
        get {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func provider() -> IGDBProvider? {
        guard let url = proxyURL, let key = appKey, !key.isEmpty else { return nil }
        return IGDBProvider(baseURL: url, appKey: key)
    }
}

struct SettingsView: View {
    @State private var url = IGDBSettings.proxyURL?.absoluteString ?? ""
    @State private var key = IGDBSettings.appKey ?? ""
    @State private var status: Status = .idle

    enum Status: Equatable { case idle, testing, ok, failed(String) }

    var body: some View {
        Form {
            Section {
                TextField("Proxy address", text: $url, prompt: Text("https://igdb-proxy.you.workers.dev"))
                SecureField("App key", text: $key, prompt: Text("The APP_KEY secret you set"))
                HStack {
                    statusView
                    Spacer()
                    Button("Test Connection", action: test)
                        .buttonStyle(.glass)
                        .disabled(URL(string: url)?.scheme == nil || key.isEmpty || status == .testing)
                }
            } header: {
                Text("IGDB")
            } footer: {
                Text("Your private Cloudflare Worker from igdb-proxy/. Without it, metadata comes from the Steam Store only.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: url) { save() }
        .onChange(of: key) { save() }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func save() {
        IGDBSettings.proxyURL = URL(string: url.trimmingCharacters(in: .whitespaces))
        IGDBSettings.appKey = key.trimmingCharacters(in: .whitespaces)
        status = .idle
    }

    private func test() {
        save()
        guard let provider = IGDBSettings.provider() else { status = .failed("Enter an https address and key."); return }
        status = .testing
        Task {
            do {
                try await provider.testConnection()
                status = .ok
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
