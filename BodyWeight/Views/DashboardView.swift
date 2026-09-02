import Charts
import SwiftData
import SwiftUI
import UIKit

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<WeightEntry> { !$0.isDeleted },
        sort: \WeightEntry.recordedAt,
        order: .forward
    ) private var entries: [WeightEntry]
    @StateObject private var syncService = WeightSyncService.shared
    @State private var showsAddWeight = false
    @State private var showsSyncSettings = false
    @State private var selectedPhotoEntry: WeightEntry?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if entries.isEmpty {
                        emptyState
                    } else {
                        summaryCard
                        chartCard
                        if !photoEntries.isEmpty { photoTimelineCard }
                        historyCard
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("体重趋势")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSyncSettings = true
                    } label: {
                        Image(systemName: syncService.isConfigured ? "cloud.fill" : "cloud")
                    }
                    .accessibilityLabel("服务器同步设置")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsAddWeight = true
                    } label: {
                        Label("记录体重", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showsAddWeight) {
                AddWeightView()
            }
            .sheet(isPresented: $showsSyncSettings) {
                SyncSettingsView(syncService: syncService)
            }
            .sheet(item: $selectedPhotoEntry) { entry in
                BodyPhotoDetailView(entry: entry)
            }
            .task {
                await syncService.synchronize(modelContext: modelContext)
            }
            .refreshable {
                await syncService.synchronize(modelContext: modelContext)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("开始记录体重", systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            Text("每天记录一次，几天后就能看到清晰的趋势。")
        } actions: {
            Button("记录第一笔") { showsAddWeight = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(minHeight: 480)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近体重")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(latestEntry.map { formattedWeight($0.weightKG) } ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("kg")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                if let change = recentChange {
                    Label(
                        change == 0 ? "持平" : formattedWeightChange(change) + " kg",
                        systemImage: change < 0 ? "arrow.down.right" : (change > 0 ? "arrow.up.right" : "arrow.right")
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(change <= 0 ? .green : .orange)
                }
            }
            if let latestEntry {
                Text(latestEntry.recordedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("趋势")
                    .font(.headline)
                Spacer()
                if chartCanScroll {
                    Label("左右滑动", systemImage: "arrow.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Chart(entries) { entry in
                LineMark(
                    x: .value("日期", chartDate(for: entry)),
                    y: .value("体重", entry.weightKG)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.blue.gradient)

                AreaMark(
                    x: .value("日期", chartDate(for: entry)),
                    yStart: .value("下限", chartDomain.lowerBound),
                    yEnd: .value("体重", entry.weightKG)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.linearGradient(
                    colors: [.blue.opacity(0.22), .blue.opacity(0.01)],
                    startPoint: .top,
                    endPoint: .bottom
                ))

                PointMark(
                    x: .value("日期", chartDate(for: entry)),
                    y: .value("体重", entry.weightKG)
                )
                .foregroundStyle(.blue)
            }
            .chartYScale(domain: chartDomain)
            .chartXScale(
                domain: chartXDomain,
                range: .plotDimension(startPadding: 30, endPadding: 30)
            )
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: chartVisibleDomainLength)
            .chartScrollPosition(initialX: chartInitialScrollDate)
            .chartScrollTargetBehavior(
                .valueAligned(
                    matching: DateComponents(hour: 0),
                    majorAlignment: .matching(DateComponents(day: 1))
                )
            )
            .chartXAxis {
                AxisMarks(values: chartXAxisDates) { value in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(
                        collisionResolution: .greedy(
                            priority: value.index == value.count - 1 ? 1 : 0,
                            minimumSpacing: 8
                        )
                    ) {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month().day()))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 240)
        }
        .cardStyle()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("历史记录")
                .font(.headline)
                .padding(.bottom, 8)

            ForEach(Array(entries.reversed())) { entry in
                HStack(spacing: 12) {
                    Image(systemName: entry.source.symbol)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.1), in: Circle())
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.recordedAt.formatted(date: .abbreviated, time: .omitted))
                        HStack(spacing: 5) {
                            Text(entry.source.title)
                            if BodyPhotoStore.image(filename: entry.photoLocalFilename) != nil {
                                Label("全身照", systemImage: "photo.fill")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formattedWeight(entry.weightKG) + " kg")
                        .fontWeight(.semibold)
                    Button(role: .destructive) {
                        delete(entry)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除这条记录")
                }
                .padding(.vertical, 10)
                if entry.id != entries.first?.id { Divider() }
            }
        }
        .cardStyle()
    }

    private var latestEntry: WeightEntry? { entries.last }

    private var photoEntries: [WeightEntry] {
        entries.filter { BodyPhotoStore.image(filename: $0.photoLocalFilename) != nil }
    }

    private var photoTimelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("身材变化")
                .font(.headline)
            Text("点开照片，对照当天体重查看变化。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(photoEntries.reversed()) { entry in
                        Button {
                            selectedPhotoEntry = entry
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                if let image = BodyPhotoStore.image(filename: entry.photoLocalFilename) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 132, height: 190)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                Text(entry.recordedAt.formatted(.dateTime.month().day()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(formattedWeight(entry.weightKG) + " kg")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            entry.recordedAt.formatted(date: .abbreviated, time: .omitted)
                            + "，" + formattedWeight(entry.weightKG) + "公斤，全身照"
                        )
                    }
                }
            }
        }
        .cardStyle()
    }

    private var recentChange: Double? {
        guard let latest = entries.last else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: latest.recordedAt) ?? latest.recordedAt
        let recent = entries.filter { $0.recordedAt >= cutoff }
        guard let first = recent.first, first.id != latest.id else { return nil }
        return latest.weightKG - first.weightKG
    }

    private var chartDomain: ClosedRange<Double> {
        guard let minimum = entries.map(\.weightKG).min(),
              let maximum = entries.map(\.weightKG).max() else { return 0...100 }
        let padding = max((maximum - minimum) * 0.2, 1.5)
        return (minimum - padding)...(maximum + padding)
    }

    private var chartXAxisDates: [Date] {
        guard chartDates.count > Self.visibleChartDateCount else { return chartDates }
        var sampledDates = Array(chartDates.reversed().enumerated().compactMap { offset, date in
            offset.isMultiple(of: 2) ? date : nil
        }.reversed())
        if let earliestDate = chartDates.first, sampledDates.first != earliestDate {
            sampledDates.insert(earliestDate, at: 0)
        }
        return sampledDates
    }

    private var chartCanScroll: Bool {
        chartXDomain.upperBound.timeIntervalSince(chartXDomain.lowerBound) > Self.visibleChartDaySpan
    }

    private var chartVisibleDomainLength: TimeInterval {
        let fullDomainLength = chartXDomain.upperBound.timeIntervalSince(chartXDomain.lowerBound)
        return min(fullDomainLength, Self.visibleChartDaySpan)
    }

    private var chartInitialScrollDate: Date {
        chartXDomain.upperBound.addingTimeInterval(-chartVisibleDomainLength)
    }

    private func chartDate(for entry: WeightEntry) -> Date {
        Calendar.current.startOfDay(for: entry.recordedAt)
    }

    private var chartXDomain: ClosedRange<Date> {
        guard let first = chartDates.first,
              let last = chartDates.last else {
            let now = Calendar.current.startOfDay(for: Date())
            return now.addingTimeInterval(-Self.halfDay)...now.addingTimeInterval(Self.halfDay)
        }
        return first.addingTimeInterval(-Self.halfDay)...last.addingTimeInterval(Self.halfDay)
    }

    private var chartDates: [Date] {
        Set(entries.map { chartDate(for: $0) }).sorted()
    }

    private static let secondsPerDay: TimeInterval = 24 * 60 * 60
    private static let halfDay = secondsPerDay / 2
    private static let visibleChartDateCount = 5
    private static let visibleChartDaySpan = secondsPerDay * 5

    private func delete(_ entry: WeightEntry) {
        BodyPhotoStore.delete(filename: entry.photoLocalFilename)
        entry.photoLocalFilename = nil
        entry.photoUpdatedAt = nil
        entry.isDeleted = true
        entry.updatedAt = Date()
        try? modelContext.save()
        Task { await syncService.synchronize(modelContext: modelContext) }
    }
}

private struct BodyPhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: WeightEntry

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let image = BodyPhotoStore.image(filename: entry.photoLocalFilename) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        ContentUnavailableView("照片暂不可用", systemImage: "photo.badge.exclamationmark")
                    }

                    HStack {
                        Label(
                            entry.recordedAt.formatted(date: .complete, time: .omitted),
                            systemImage: "calendar"
                        )
                        Spacer()
                        Text(formattedWeight(entry.weightKG) + " kg")
                            .font(.title3.weight(.bold))
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("当日记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct SyncSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var syncService: WeightSyncService
    @State private var token = ""
    @State private var localMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    LabeledContent("地址") {
                        Text("8.138.40.226")
                            .foregroundStyle(.secondary)
                    }
                    Label("使用 HTTPS 加密传输", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("访问令牌") {
                    SecureField(
                        syncService.isConfigured ? "已保存；留空则保持不变" : "粘贴服务器令牌",
                        text: $token
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button("保存并立即同步") {
                        Task { await saveAndSync() }
                    }
                    .disabled(token.isEmpty && !syncService.isConfigured)

                    if syncService.isConfigured {
                        Button("停止使用服务器", role: .destructive) {
                            syncService.clearToken()
                            token = ""
                            localMessage = syncService.statusMessage
                        }
                    }
                }

                Section("状态") {
                    if syncService.isSyncing { ProgressView("正在同步…") }
                    Text(localMessage.isEmpty ? syncService.statusMessage : localMessage)
                    if let lastSyncDate = syncService.lastSyncDate {
                        LabeledContent("最近同步") {
                            Text(lastSyncDate.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }

                Section {
                    Text("App 会保留本地副本。断网时可以继续记录，恢复网络后再次下拉即可同步。令牌仅保存在本机 Keychain。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("服务器同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func saveAndSync() async {
        do {
            if !token.isEmpty {
                try syncService.saveToken(token)
                token = ""
            }
            await syncService.synchronize(modelContext: modelContext)
            localMessage = syncService.statusMessage
        } catch {
            localMessage = error.localizedDescription
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private func formattedWeight(_ value: Double) -> String {
    String(format: "%.2f", locale: .current, value)
}

private func formattedWeightChange(_ value: Double) -> String {
    String(format: "%+.2f", locale: .current, value)
}
