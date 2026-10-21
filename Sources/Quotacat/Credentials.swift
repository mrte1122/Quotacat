import Foundation
import Security

enum TokenSource: String {
    case signIn = "GitHub sign-in"
    case ghCLI = "GitHub CLI"
    case keychain = "Personal access token"
}

struct Credential {
    let token: String
    let source: TokenSource
}

/// Mirrors Claude Usage's `ClaudeCodeSyncService`: reuse the CLI's login, fall back to a stored secret.
enum CredentialProvider {
    // GUI apps don't inherit the shell PATH, so probe the usual install locations.
    static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    static var ghPath: String? {
        ghCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func ghToken() -> String? {
        guard let path = ghPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["auth", "token", "--hostname", "github.com"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Order: an explicit "Sign in with GitHub" first, then the PAT if preferred, then the
    /// GitHub CLI login, then any saved PAT.
    static func resolve(preferPAT: Bool) -> Credential? {
        if let t = Keychain.load(.signIn) { return Credential(token: t, source: .signIn) }
        let pat = Keychain.loadToken().map { Credential(token: $0, source: .keychain) }
        if preferPAT, let pat { return pat }
        if let t = ghToken() { return Credential(token: t, source: .ghCLI) }
        return pat
    }
}

enum Keychain {
    enum Item: String {
        case personalAccessToken = "personal-access-token"
        case signIn = "github-sign-in"
    }

    private static let service = "Quotacat"

    private static func query(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item.rawValue]
    }

    static func load(_ item: Item) -> String? {
        var q = query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    @discardableResult
    static func save(_ token: String, _ item: Item) -> Bool {
        delete(item)
        var q = query(item)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ item: Item) {
        SecItemDelete(query(item) as CFDictionary)
    }

    // The personal access token entered in Settings → Account.
    static func loadToken() -> String? { load(.personalAccessToken) }
    @discardableResult static func saveToken(_ token: String) -> Bool { save(token, .personalAccessToken) }
    static func deleteToken() { delete(.personalAccessToken) }
}
