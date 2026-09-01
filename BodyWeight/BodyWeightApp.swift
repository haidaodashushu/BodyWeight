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
