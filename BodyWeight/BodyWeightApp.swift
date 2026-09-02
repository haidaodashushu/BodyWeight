import Foundation
import Security
import SwiftData
import SwiftUI
import UIKit

@main
struct BodyWeightApp: App {
    private let modelContainer = ModelContainerFactory.make()
    @StateObject private var syncService = WeightSyncService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if syncService.isAuthenticated {
                    DashboardView()
                } else {
                    AuthenticationView(syncService: syncService)
                }
            }
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
    private static let sessionTokenAccount = "session-token"
    private static let currentUserAccount = "current-user"
    private static let legacyTokenAccount = "server-api-token"

    static func readSession() -> (token: String, user: AuthenticatedUser)? {
        guard let token = read(account: sessionTokenAccount),
              let userData = readData(account: currentUserAccount),
              let user = try? JSONDecoder().decode(AuthenticatedUser.self, from: userData) else {
            return nil
        }
        return (token, user)
    }

    static func saveSession(token: String, user: AuthenticatedUser) throws {
        do {
            try save(Data(token.utf8), account: sessionTokenAccount)
            try save(try JSONEncoder().encode(user), account: currentUserAccount)
            delete(account: legacyTokenAccount)
        } catch {
            clearSession()
            throw error
        }
    }

    static func clearSession() {
        delete(account: sessionTokenAccount)
        delete(account: currentUserAccount)
    }

    static func readLegacyToken() -> String? {
        read(account: legacyTokenAccount)
    }

    private static func read(account: String) -> String? {
        guard let data = readData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func save(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func delete(account: String) {
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

struct AuthenticatedUser: Codable, Equatable {
    let id: String
    let username: String
}

private struct AuthenticationRequest: Encodable {
    let username: String
    let password: String
    let registrationCode: String?
}

private struct AuthenticationResponse: Decodable {
    let token: String
    let user: AuthenticatedUser
    let claimedLegacyData: Bool
}

private struct APIErrorResponse: Decodable {
    let error: String
    let message: String?
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
    let photoUpdatedAt: Date?

    init(_ entry: WeightEntry) {
        id = entry.id
        weightKG = entry.weightKG
        recordedAt = entry.recordedAt
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        source = entry.sourceRawValue
        originalText = entry.originalText
        isDeleted = entry.isDeleted
        photoUpdatedAt = entry.photoUpdatedAt
    }
}

enum BodyPhotoStore {
    private static let directoryName = "body-weight-photos"

    static func save(_ image: UIImage, for entryID: UUID) throws -> String {
        guard let data = resizedJPEGData(from: image) else {
            throw PhotoError.encodingFailed
        }
        return try saveJPEGData(data, for: entryID)
    }

    static func saveJPEGData(_ data: Data, for entryID: UUID) throws -> String {
        let filename = entryID.uuidString.lowercased() + ".jpg"
        try data.write(to: try fileURL(filename: filename), options: .atomic)
        return filename
    }

    static func data(filename: String?) -> Data? {
        guard let filename,
              let url = try? fileURL(filename: filename) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func image(filename: String?) -> UIImage? {
        guard let data = data(filename: filename) else { return nil }
        return UIImage(data: data)
    }

    static func delete(filename: String?) {
        guard let filename,
              let url = try? fileURL(filename: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileURL(filename: String) throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    private static func resizedJPEGData(from image: UIImage) -> Data? {
        let maximumDimension: CGFloat = 1_800
        let currentMaximum = max(image.size.width, image.size.height)
        let scale = currentMaximum > maximumDimension ? maximumDimension / currentMaximum : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.82)
    }

    enum PhotoError: LocalizedError {
        case encodingFailed
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .encodingFailed: "无法压缩这张照片，请换一张后重试。"
            case .invalidImage: "无法读取这张照片，请换一张后重试。"
            }
        }
    }
}

@MainActor
final class WeightSyncService: ObservableObject {
    static let shared = WeightSyncService()
    static let serverAddress = "https://8.138.40.226/body-weight-api"

    @Published private(set) var currentUser: AuthenticatedUser?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var statusMessage = "请登录后同步"

    private let endpoint = URL(string: serverAddress + "/v1/sync")!
    private let photoEndpoint = URL(string: serverAddress + "/v1/photos/")!
    private let loginEndpoint = URL(string: serverAddress + "/v1/auth/login")!
    private let registerEndpoint = URL(string: serverAddress + "/v1/auth/register")!
    private let logoutEndpoint = URL(string: serverAddress + "/v1/auth/logout")!
    private var sessionToken: String?

    var isAuthenticated: Bool { currentUser != nil && sessionToken != nil }
    var isConfigured: Bool { isAuthenticated }
    var hasLegacyRegistrationCode: Bool { KeychainStore.readLegacyToken() != nil }

    private init() {
        if let session = KeychainStore.readSession() {
            sessionToken = session.token
            currentUser = session.user
            statusMessage = "等待同步"
        }
    }

    func register(
        username: String,
        password: String,
        registrationCode: String,
        modelContext: ModelContext
    ) async throws {
        let code = registrationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveCode = code.isEmpty ? KeychainStore.readLegacyToken() : code
        guard let effectiveCode, !effectiveCode.isEmpty else {
            throw SyncError.missingRegistrationCode
        }
        try await authenticate(
            endpoint: registerEndpoint,
            username: username,
            password: password,
            registrationCode: effectiveCode,
            modelContext: modelContext
        )
    }

    func login(username: String, password: String, modelContext: ModelContext) async throws {
        try await authenticate(
            endpoint: loginEndpoint,
            username: username,
            password: password,
            registrationCode: nil,
            modelContext: modelContext
        )
    }

    func signOut() async {
        if let sessionToken {
            var request = URLRequest(url: logoutEndpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        clearSession(message: "已退出登录；本机缓存不会被删除")
    }

    func prepareLocalData(modelContext: ModelContext) throws {
        guard let ownerID = currentUser?.id else { return }
        let localEntries = try modelContext.fetch(FetchDescriptor<WeightEntry>())
        var changed = false
        for entry in localEntries where entry.ownerID == nil {
            entry.ownerID = ownerID
            changed = true
        }
        if changed { try modelContext.save() }
    }

    private func authenticate(
        endpoint: URL,
        username rawUsername: String,
        password: String,
        registrationCode: String?,
        modelContext: ModelContext
    ) async throws {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...32).contains(username.count),
              username.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) else {
            throw SyncError.invalidUsername
        }
        guard (8...128).contains(password.count) else { throw SyncError.invalidPassword }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AuthenticationRequest(
            username: username,
            password: password,
            registrationCode: registrationCode
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverError = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            switch serverError?.error {
            case "invalid_credentials": throw SyncError.invalidCredentials
            case "username_taken": throw SyncError.usernameTaken
            case "invalid_registration_code": throw SyncError.invalidRegistrationCode
            default: throw SyncError.serverError(httpResponse.statusCode)
            }
        }
        let authentication = try JSONDecoder().decode(AuthenticationResponse.self, from: data)
        try KeychainStore.saveSession(token: authentication.token, user: authentication.user)
        sessionToken = authentication.token
        currentUser = authentication.user
        statusMessage = authentication.claimedLegacyData ? "已接管原有服务器数据" : "登录成功"
        try prepareLocalData(modelContext: modelContext)
        await synchronize(modelContext: modelContext)
    }

    private func clearSession(message: String) {
        KeychainStore.clearSession()
        sessionToken = nil
        currentUser = nil
        lastSyncDate = nil
        statusMessage = message
    }

    func synchronize(modelContext: ModelContext) async {
        guard !isSyncing,
              let token = sessionToken,
              let ownerID = currentUser?.id else { return }
        isSyncing = true
        statusMessage = "正在同步…"
        defer { isSyncing = false }

        do {
            try prepareLocalData(modelContext: modelContext)
            let allLocalEntries = try modelContext.fetch(FetchDescriptor<WeightEntry>())
            let localEntries = allLocalEntries.filter { $0.ownerID == ownerID }
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
            try merge(remote.entries, ownerID: ownerID, into: modelContext)
            try await synchronizePhotos(
                remote.entries,
                ownerID: ownerID,
                token: token,
                modelContext: modelContext
            )
            try modelContext.save()
            lastSyncDate = Date()
            statusMessage = "体重和照片已与服务器同步"
        } catch {
            if case SyncError.unauthorized = error {
                clearSession(message: "登录已过期，请重新登录")
            }
            statusMessage = error.localizedDescription
        }
    }

    private func merge(
        _ remoteEntries: [RemoteWeightEntry],
        ownerID: String,
        into modelContext: ModelContext
    ) throws {
        let localEntries = try modelContext.fetch(FetchDescriptor<WeightEntry>()).filter {
            $0.ownerID == ownerID
        }
        var localByID = Dictionary(uniqueKeysWithValues: localEntries.map { ($0.id, $0) })

        for remote in remoteEntries {
            if remote.isDeleted {
                if let local = localByID.removeValue(forKey: remote.id),
                   remote.updatedAt >= local.updatedAt {
                    BodyPhotoStore.delete(filename: local.photoLocalFilename)
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
                    updatedAt: remote.updatedAt,
                    ownerID: ownerID
                ))
            }
        }
    }

    private func synchronizePhotos(
        _ remoteEntries: [RemoteWeightEntry],
        ownerID: String,
        token: String,
        modelContext: ModelContext
    ) async throws {
        let localEntries = try modelContext.fetch(FetchDescriptor<WeightEntry>()).filter {
            $0.ownerID == ownerID
        }
        let localByID = Dictionary(uniqueKeysWithValues: localEntries.map { ($0.id, $0) })

        for remote in remoteEntries where !remote.isDeleted {
            guard let local = localByID[remote.id] else { continue }
            let localData = BodyPhotoStore.data(filename: local.photoLocalFilename)

            if let localData, let localUpdatedAt = local.photoUpdatedAt,
               remote.photoUpdatedAt == nil || localUpdatedAt > remote.photoUpdatedAt! {
                let uploadUpdatedAt = Date(
                    timeIntervalSince1970: floor(localUpdatedAt.timeIntervalSince1970)
                )
                try await uploadPhoto(
                    localData,
                    entryID: local.id,
                    updatedAt: uploadUpdatedAt,
                    token: token
                )
                local.photoUpdatedAt = uploadUpdatedAt
            } else if let remoteUpdatedAt = remote.photoUpdatedAt,
                      localData == nil || local.photoUpdatedAt == nil || remoteUpdatedAt > local.photoUpdatedAt! {
                let data = try await downloadPhoto(entryID: local.id, token: token)
                local.photoLocalFilename = try BodyPhotoStore.saveJPEGData(data, for: local.id)
                local.photoUpdatedAt = remoteUpdatedAt
            }
        }
    }

    private func uploadPhoto(
        _ data: Data,
        entryID: UUID,
        updatedAt: Date,
        token: String
    ) async throws {
        var request = URLRequest(url: photoEndpoint.appendingPathComponent(entryID.uuidString.lowercased()))
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(ISO8601DateFormatter().string(from: updatedAt), forHTTPHeaderField: "X-Photo-Updated-At")
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    private func downloadPhoto(entryID: UUID, token: String) async throws -> Data {
        var request = URLRequest(url: photoEndpoint.appendingPathComponent(entryID.uuidString.lowercased()))
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard data.starts(with: [0xFF, 0xD8]) else { throw SyncError.invalidResponse }
        return data
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }
        guard httpResponse.statusCode != 401 else { throw SyncError.unauthorized }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SyncError.serverError(httpResponse.statusCode)
        }
    }

    enum SyncError: LocalizedError {
        case invalidUsername
        case invalidPassword
        case missingRegistrationCode
        case invalidRegistrationCode
        case usernameTaken
        case invalidCredentials
        case invalidResponse
        case unauthorized
        case serverError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidUsername: "用户名需为 3–32 位，只能包含英文、数字、点、下划线或短横线。"
            case .invalidPassword: "密码长度需为 8–128 位。"
            case .missingRegistrationCode: "请输入服务器注册码；升级用户也可以使用原访问令牌。"
            case .invalidRegistrationCode: "服务器注册码不正确。"
            case .usernameTaken: "这个用户名已经被注册。"
            case .invalidCredentials: "用户名或密码错误。"
            case .invalidResponse: "服务器返回了无法识别的响应。"
            case .unauthorized: "登录已过期，请重新登录。"
            case .serverError(let status): "服务器同步失败（HTTP \(status)）。"
            }
        }
    }
}

private struct AuthenticationView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var syncService: WeightSyncService

    @State private var mode: Mode = .login
    @State private var username = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var registrationCode = ""
    @State private var message = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "scalemass.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue.gradient)
                        Text("体重趋势")
                            .font(.title.bold())
                        Text("登录后，你的体重和全身照只会同步到自己的账号。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }

                Section {
                    Picker("账号操作", selection: $mode) {
                        ForEach(Mode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(mode == .login ? "登录" : "注册") {
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码（至少 8 位）", text: $password)
                        .textContentType(mode == .login ? .password : .newPassword)

                    if mode == .register {
                        SecureField("再次输入密码", text: $passwordConfirmation)
                            .textContentType(.newPassword)
                        SecureField(
                            syncService.hasLegacyRegistrationCode
                                ? "注册码（已保存原令牌，可留空）"
                                : "服务器注册码",
                            text: $registrationCode
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(mode.actionTitle)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSubmitting || username.isEmpty || password.isEmpty)
                }

                if !message.isEmpty {
                    Section("提示") {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Label("账号密码通过 HTTPS 加密传输；密码不会明文保存在服务器。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("账号")
            .onChange(of: mode) { _, _ in
                message = ""
                password = ""
                passwordConfirmation = ""
            }
        }
    }

    private func submit() async {
        message = ""
        if mode == .register, password != passwordConfirmation {
            message = "两次输入的密码不一致。"
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            switch mode {
            case .login:
                try await syncService.login(
                    username: username,
                    password: password,
                    modelContext: modelContext
                )
            case .register:
                try await syncService.register(
                    username: username,
                    password: password,
                    registrationCode: registrationCode,
                    modelContext: modelContext
                )
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private enum Mode: String, CaseIterable, Identifiable {
        case login
        case register

        var id: String { rawValue }
        var title: String { self == .login ? "登录" : "注册" }
        var actionTitle: String { self == .login ? "登录" : "创建账号" }
    }
}
