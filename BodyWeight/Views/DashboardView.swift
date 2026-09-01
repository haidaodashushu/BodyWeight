import Charts
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WeightEntry.recordedAt, order: .forward) private var entries: [WeightEntry]
    @State private var showsAddWeight = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if entries.isEmpty {
                        emptyState
                    } else {
                        summaryCard
                        chartCard
                        historyCard
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("体重趋势")
            .toolbar {
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
                Text(latestEntry?.weightKG.formatted(.number.precision(.fractionLength(1))) ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("kg")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                if let change = recentChange {
                    Label(
                        change == 0 ? "持平" : change.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + " kg",
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
            Text("趋势")
                .font(.headline)
            Chart(entries) { entry in
                LineMark(
                    x: .value("日期", entry.recordedAt),
                    y: .value("体重", entry.weightKG)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.blue.gradient)

                AreaMark(
                    x: .value("日期", entry.recordedAt),
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
                    x: .value("日期", entry.recordedAt),
                    y: .value("体重", entry.weightKG)
                )
                .foregroundStyle(.blue)
            }
            .chartYScale(domain: chartDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.month().day())
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
                        Text(entry.source.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.weightKG.formatted(.number.precision(.fractionLength(1))) + " kg")
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

    private func delete(_ entry: WeightEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
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
