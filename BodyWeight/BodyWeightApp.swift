import Foundation
import Security
import SwiftData
import SwiftUI

@main
struct BodyWeightApp: App {
    private let modelContainer = ModelContainerFactory.make()

    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
        .modelContainer(modelContainer)
    }
}

private enum ModelContainerFactory {
    static func make() -> ModelContainer {
        let schema = Schema([WeightEntry.self])

#if ICLOUD_SYNC
        let cloudConfiguration = ModelConfiguration(
            "BodyWeightCloud",
            schema: schema,
            cloudKitDatabase: .automatic
        )

        if let cloudContainer = try? ModelContainer(
            for: schema,
            configurations: [cloudConfiguration]
        ) {
            return cloudContainer
        }
#endif

        let localConfiguration = ModelConfiguration(
            "BodyWeightLocal",
            schema: schema,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [localConfiguration])
        } catch {
            fatalError("无法初始化体重数据库：\(error.localizedDescription)")
        }
    }
}

private enum KeychainStore {
    private static let service = "com.haidaodashushu.BodyWeight.sync"
    private static let account = "server-api-token"

    static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct SyncPayload: Codable {
    let entries: [RemoteWeightEntry]
}

private struct SyncResponse: Codable {
    let entries: [RemoteWeightEntry]
    let serverTime: String
}

private struct RemoteWeightEntry: Codable {
    let id: UUID
    let weightKG: Double
    let recordedAt: Date
    let createdAt: Date
    let updatedAt: Date
    let source: String
    let originalText: String
    let isDeleted: Bool

    init(_ entry: WeightEntry) {
        id = entry.id
        weightKG = entry.weightKG
        recordedAt = entry.recordedAt
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        source = entry.sourceRawValue
        originalText = entry.originalText
        isDeleted = entry.isDeleted
    }
}

@MainActor
final class WeightSyncService: ObservableObject {
    static let shared = WeightSyncService()
    static let serverAddress = "https://8.138.40.226/body-weight-api"

    @Published private(set) var isConfigured: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var statusMessage = "尚未配置服务器令牌"

    private let endpoint = URL(string: serverAddress + "/v1/sync")!

    private init() {
        isConfigured = KeychainStore.readToken() != nil
        if isConfigured { statusMessage = "等待同步" }
    }

    func saveToken(_ rawToken: String) throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32 else {
            throw SyncError.invalidTokenFormat
        }
        try KeychainStore.saveToken(token)
        isConfigured = true
        statusMessage = "令牌已保存"
    }

    func clearToken() {
        KeychainStore.deleteToken()
        isConfigured = false
        lastSyncDate = nil
        statusMessage = "已停止云端同步，本地数据不会被删除"
    }

    func synchronize(modelContext: ModelContext) async {
        guard !isSyncing, let token = KeychainStore.readToken() else { return }
        isSyncing = true
        statusMessage = "正在同步…"
        defer { isSyncing = false }

        do {
            let localEntries = try modelContext.fetch(FetchDescriptor<WeightEntry>())
            let payload = SyncPayload(entries: localEntries.map(RemoteWeightEntry.init))
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SyncError.invalidResponse
            }
            guard httpResponse.statusCode != 401 else { throw SyncError.unauthorized }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw SyncError.serverError(httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let remote = try decoder.decode(SyncResponse.self, from: data)
            try merge(remote.entries, into: modelContext)
            try modelContext.save()
            lastSyncDate = Date()
            statusMessage = "已与服务器同步"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func merge(_ remoteEntries: [RemoteWeightEntry], into modelContext: ModelContext) throws {
        let localEntries = try modelContext.fetch(FetchDescriptor<WeightEntry>())
        var localByID = Dictionary(uniqueKeysWithValues: localEntries.map { ($0.id, $0) })

        for remote in remoteEntries {
            if remote.isDeleted {
                if let local = localByID.removeValue(forKey: remote.id),
                   remote.updatedAt >= local.updatedAt {
                    modelContext.delete(local)
                }
                continue
            }

            if let local = localByID[remote.id] {
                guard remote.updatedAt > local.updatedAt else { continue }
                local.weightKG = remote.weightKG
                local.recordedAt = remote.recordedAt
                local.createdAt = remote.createdAt
                local.updatedAt = remote.updatedAt
                local.sourceRawValue = remote.source
                local.originalText = remote.originalText
                local.isDeleted = false
            } else {
                let source = WeightEntry.Source(rawValue: remote.source) ?? .manual
                modelContext.insert(WeightEntry(
                    id: remote.id,
                    weightKG: remote.weightKG,
                    recordedAt: remote.recordedAt,
                    source: source,
                    originalText: remote.originalText,
                    createdAt: remote.createdAt,
                    updatedAt: remote.updatedAt
                ))
            }
        }
    }

    enum SyncError: LocalizedError {
        case invalidTokenFormat
        case invalidResponse
        case unauthorized
        case serverError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidTokenFormat: "令牌格式不正确，请完整粘贴服务器令牌。"
            case .invalidResponse: "服务器返回了无法识别的响应。"
            case .unauthorized: "服务器拒绝了令牌，请重新粘贴。"
            case .serverError(let status): "服务器同步失败（HTTP \(status)）。"
            }
        }
    }
}
