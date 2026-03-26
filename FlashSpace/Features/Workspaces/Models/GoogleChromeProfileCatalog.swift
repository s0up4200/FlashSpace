import Foundation

enum GoogleChromeProfileCatalog {
    static let localStateUrl = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")

    static func load() -> [BrowserProfile] {
        guard let data = try? Data(contentsOf: localStateUrl) else { return [] }
        return (try? parse(data: data)) ?? []
    }

    static func parse(data: Data) throws -> [BrowserProfile] {
        let localState = try JSONDecoder().decode(LocalState.self, from: data)

        return localState.profile.infoCache
            .map { directory, profile in
                BrowserProfile(
                    directory: directory,
                    name: profile.name,
                    email: profile.userName
                )
            }
            .sorted { $0.directory < $1.directory }
    }
}

private struct LocalState: Decodable {
    let profile: ProfileState
}

private struct ProfileState: Decodable {
    let infoCache: [String: LocalStateProfile]

    enum CodingKeys: String, CodingKey {
        case infoCache = "info_cache"
    }
}

private struct LocalStateProfile: Decodable {
    let name: String
    let userName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case userName = "user_name"
    }
}
