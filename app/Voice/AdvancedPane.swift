import Charts
import SwiftUI
import VoiceCore

/// Everything Advanced draws, read once off the main thread. Numbers only.
struct AdvancedData: Sendable {
    var timings: [ModelTimings.Entry] = []
    var retryDays: [RetryStats.Day] = []
    var retrySeconds: [Double] = []

    static func load(_ database: URL, now: Date = Date()) -> AdvancedData {
        var data = AdvancedData()
        data.timings = (try? ModelTimings.read(database, now: now)) ?? []
        if let retries = try? RetryStats.daily(database, now: now) {
            data.retryDays = retries.days
            data.retrySeconds = retries.retrySeconds
        }
        return data
    }
}

/// Hidden until Developer mode in About is on: how long the intelligence model and the retry
/// pass take on this Mac. Nothing here leaves it.
struct AdvancedPane: View {
    @Environment(AppModel.self) private var model
    private let database: URL
    @State private var data: AdvancedData?

    init(database: URL = Paths.database) {
        self.database = database
    }

    var body: some View {
        Form {
            if let data, data.timings.isEmpty, data.retryDays.isEmpty {
                Text("No measurements yet.").foregroundStyle(.secondary)
            } else if let data {
                TimingSection(entries: data.timings)
                DistributionSection(entries: data.timings)
                RetrySection(days: data.retryDays, seconds: data.retrySeconds)
            }
        }
        .formStyle(.grouped)
        .task(id: refreshKey) {
            let database = database
            data = await Task.detached(priority: .utility) { AdvancedData.load(database) }.value
        }
    }

    /// Changes with each new dictation, and when a call starts or ends.
    private var refreshKey: String {
        "\(model.recent.first?.id ?? "")|\(model.calls?.recording?.id ?? "")"
    }
}

// MARK: Shared

private extension ModelTimings.Work {
    var label: String { self == .title ? "Title" : "Fix" }
}

private enum Numbers {
    static let days = 30
    static let height: CGFloat = 180

    static func seconds(_ value: Double?) -> String {
        guard let value else { return "none" }
        return String(format: value < 10 ? "%.1f s" : "%.0f s", value)
    }

    static func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "No measurements yet." }
        return "\(values.count) measured \u{00B7} median \(seconds(RetryStats.percentile(values, 0.5))) \u{00B7} "
            + "p90 \(seconds(RetryStats.percentile(values, 0.9)))"
    }

    static var end: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))! }

    static func start(now: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(days - 1) * 24 * 3600))
    }
}

private struct Quiet: View {
    var body: some View {
        Text("No measurements yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: Numbers.height / 2)
    }
}

/// A measurement that finished, as a point.
private struct Point: Identifiable {
    let id: Int
    let date: Date
    let seconds: Double
    let work: ModelTimings.Work

    static func make(_ entries: [ModelTimings.Entry]) -> [Point] {
        entries.filter { $0.outcome == .ok }.enumerated().map {
            Point(id: $0.offset, date: $0.element.createdAt, seconds: Double($0.element.totalMs) / 1000, work: $0.element.work)
        }
    }
}

private let seriesColors: KeyValuePairs<String, Color> = ["Title": .blue, "Fix": .green]

// MARK: Title and fix time

private struct TimingSection: View {
    let entries: [ModelTimings.Entry]

    var body: some View {
        let points = Point.make(entries)
        let failed = entries.filter { $0.outcome == .failed }.count
        Section("Title and fix time") {
            if points.isEmpty {
                Quiet()
            } else {
                Chart {
                    ForEach(points) { point in
                        PointMark(x: .value("Date", point.date), y: .value("Seconds", point.seconds))
                            .foregroundStyle(by: .value("Task", point.work.label))
                            .symbolSize(30)
                    }
                }
                .chartForegroundStyleScale(seriesColors)
                .chartXScale(domain: Numbers.start()...Numbers.end)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxisLabel("Seconds")
                .chartLegend(position: .bottom)
                .frame(height: Numbers.height)
                .padding(.vertical, 4)
                ForEach(ModelTimings.Work.allCases, id: \.self) { work in
                    LabeledContent(work.label) {
                        Text(Numbers.summary(points.filter { $0.work == work }.map(\.seconds))).monospacedDigit()
                    }
                }
                if failed > 0 {
                    LabeledContent("Failed") { Text("\(failed)").monospacedDigit() }
                }
            }
        }
    }
}

// MARK: Distribution

private struct Bin: Identifiable {
    let id: Int
    let label: String
    let work: ModelTimings.Work
    let count: Int
}

private struct DistributionSection: View {
    let entries: [ModelTimings.Entry]

    /// A step that gives about ten bins, from a few round ones.
    private static func step(for maximum: Double) -> Double {
        [0.25, 0.5, 1, 2, 5, 10, 20, 30, 60, 120].first { maximum / $0 <= 10 } ?? 300
    }

    var body: some View {
        let points = Point.make(entries)
        let step = Self.step(for: points.map(\.seconds).max() ?? 1)
        let bins = Self.bins(points, step: step)
        Section("Distribution") {
            if points.isEmpty {
                Quiet()
            } else {
                Chart(bins) { bin in
                    BarMark(x: .value("Seconds", bin.label), y: .value("Runs", bin.count), width: .ratio(0.9))
                        .foregroundStyle(by: .value("Task", bin.work.label))
                        .position(by: .value("Task", bin.work.label))
                }
                .chartForegroundStyleScale(seriesColors)
                .chartXScale(domain: bins.map(\.label).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
                .chartXAxisLabel("Seconds")
                .chartYAxisLabel("Runs")
                .chartLegend(position: .bottom)
                .frame(height: Numbers.height)
                .padding(.vertical, 4)
            }
        }
    }

    /// Every bin is listed for both tasks, empty ones too, so the bins keep their order and gaps.
    private static func bins(_ points: [Point], step: Double) -> [Bin] {
        guard let maximum = points.map(\.seconds).max() else { return [] }
        let count = max(1, Int((maximum / step).rounded(.up)))
        func number(_ value: Double) -> String { String(format: "%g", value) }
        var result: [Bin] = []
        for index in 0..<count {
            let low = Double(index) * step, high = low + step
            let label = "\(number(low))\u{2013}\(number(high)) s"
            for work in ModelTimings.Work.allCases {
                let n = points.filter { $0.work == work && $0.seconds >= low && ($0.seconds < high || (index == count - 1 && $0.seconds <= high)) }.count
                result.append(Bin(id: result.count, label: label, work: work, count: n))
            }
        }
        return result
    }
}

// MARK: Retries

private struct RetryBar: Identifiable {
    let id: Int
    let day: Date
    let kind: String
    let count: Int
}

private struct RetrySection: View {
    let days: [RetryStats.Day]
    let seconds: [Double]
    private static let changed = "Changed"
    private static let unchanged = "Retried (unchanged)"

    var body: some View {
        let bars = days.flatMap { [($0.day, Self.changed, $0.changed), ($0.day, Self.unchanged, max(0, $0.retried - $0.changed))] }
            .enumerated().map { RetryBar(id: $0.offset, day: $0.element.0, kind: $0.element.1, count: $0.element.2) }
        Section("Retries") {
            if days.isEmpty {
                Quiet()
            } else {
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Segments", bar.count), width: .ratio(0.7))
                        .foregroundStyle(by: .value("Kind", bar.kind))
                }
                .chartForegroundStyleScale([Self.unchanged: Color.indigo, Self.changed: Color.orange])
                .chartXScale(domain: Numbers.start()...Numbers.end)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxisLabel("Segments")
                .chartLegend(position: .bottom)
                .frame(height: Numbers.height)
                .padding(.vertical, 4)
                LabeledContent("Last 30 days") {
                    Text("\(days.map(\.unsure).reduce(0, +)) unsure \u{00B7} \(days.map(\.retried).reduce(0, +)) retried \u{00B7} "
                         + "\(days.map(\.changed).reduce(0, +)) changed").monospacedDigit()
                }
                LabeledContent("Median retry time") {
                    Text(Numbers.seconds(RetryStats.percentile(seconds, 0.5))).monospacedDigit()
                }
            }
        }
    }
}
