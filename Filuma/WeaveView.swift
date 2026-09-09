// Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V4
// Hallmark · atmospheric utility · intimate restraint · tapestry-led continuous document

import SwiftUI
import SwiftData

// MARK: - Weave data

/// One day of the tapestry: how much thread each context contributed.
struct WeaveDay: Identifiable, Equatable {
    let date: Date
    let minutesByContext: [TaskContext: Int]
    let sessionCount: Int

    var id: Date { date }
    var totalMinutes: Int { minutesByContext.values.reduce(0, +) }
}

/// Pure aggregation for the Weave tab, kept separate from the view so the
/// math is testable.
struct WeaveBuilder {

    /// The last `daysBack` days, oldest first. Worked time follows the same
    /// convention as `timeSpentMinutes`: timed sessions plus checked-off
    /// blocks that do not have a linked timed session, attributed to the day
    /// they started.
    static func days(
        sessions: [WorkSession],
        blocks: [ScheduledBlock],
        daysBack: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WeaveDay] {
        let today = calendar.startOfDay(for: now)
        let timedBlockIds = Set(sessions.compactMap(\.scheduledBlockId))
        var result: [WeaveDay] = []
        for offset in stride(from: daysBack - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            var minutes: [TaskContext: Int] = [:]
            var sessionCount = 0
            for session in sessions where calendar.isDate(session.startedAt, inSameDayAs: day) {
                guard let context = session.task?.context else { continue }
                minutes[context, default: 0] += (session.durationSeconds + 30) / 60
                sessionCount += 1
            }
            for block in blocks where block.isComplete
                && !timedBlockIds.contains(block.id)
                && calendar.isDate(block.startTime, inSameDayAs: day) {
                guard let context = block.task?.context else { continue }
                minutes[context, default: 0] += block.durationMinutes
            }
            result.append(WeaveDay(date: day, minutesByContext: minutes, sessionCount: sessionCount))
        }
        return result
    }

    /// Median actual÷planned ratio over the most recent tracked completions,
    /// across all contexts — the app-wide "how hot do my estimates run"
    /// number. Nil under 3 samples.
    static func estimateHeat(tasks: [FilumaTask], sampleLimit: Int = 10) -> Double? {
        let ratios = tasks
            .filter { $0.isComplete && $0.effortMinutes > 0 && $0.timeSpentMinutes > 0 }
            .sorted { ($0.completedAt ?? $0.deadline) > ($1.completedAt ?? $1.deadline) }
            .prefix(sampleLimit)
            .map { Double($0.timeSpentMinutes) / Double($0.effortMinutes) }
            .sorted()
        guard ratios.count >= 3 else { return nil }
        return ratios.count.isMultiple(of: 2)
            ? (ratios[ratios.count / 2 - 1] + ratios[ratios.count / 2]) / 2
            : ratios[ratios.count / 2]
    }
}

// MARK: - Weave view

/// The reflection surface: two weeks of showing up, rendered as woven thread.
/// Work can disappear behind the next deadline; the tapestry keeps that
/// accumulation visible. Colored threads represent worked time, while a bare
/// warp dot represents a rest day (rest days hold the cloth together; they
/// are not gaps).
struct WeaveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sessions: [WorkSession]
    @Query private var tasks: [FilumaTask]
    @Query private var blocks: [ScheduledBlock]

    @State private var selectedDay: WeaveDay?
    @State private var period = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let columnHeight: CGFloat = 260

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    tapestrySection
                    weaveDivider
                    statsSection
                    threadsSection
                    estimateHeatLine
                    winsSection
                }
                .padding(.bottom, 110)
                .frame(maxWidth: FilumaLayout.readableContentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Color.filumaBackground.ignoresSafeArea())
        }
    }

    private var days: [WeaveDay] {
        WeaveBuilder.days(sessions: sessions, blocks: blocks, daysBack: period)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Your effort, over time")
                .font(AppFont.caption(13))
                .foregroundStyle(Color.brand300)
            Text("Weave")
                .font(AppFont.title(30))
                .foregroundStyle(Color.filumaText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    // MARK: Tapestry

    private var tapestrySection: some View {
        let days = self.days
        let hasAnyThread = days.contains { $0.totalMinutes > 0 }

        return VStack(alignment: .leading, spacing: 12) {
            if let first = days.first, let last = days.last {
                Text("\(first.date.formatted(.dateTime.month(.abbreviated).day())) – \(last.date.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(AppFont.body(14))
                    .foregroundStyle(Color.filumaSubtle)
            }
            Picker("Time period", selection: $period) {
                Text("Week").tag(7)
                Text("2 Weeks").tag(14)
                Text("Month").tag(30)
            }
            .pickerStyle(.segmented)
            .onChange(of: period) { _, _ in selectedDay = nil }
            if hasAnyThread {
                tapestry(days: days)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { contextLegend }
                    VStack(alignment: .leading, spacing: 8) { contextLegend }
                }

                if let day = selectedDay {
                    Text(detailLine(for: day))
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.filumaSubtle)
                        .transition(.opacity)
                } else {
                    Text("Each colored knot is recorded effort. Tap a day to see its detail.")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.filumaFaint)
                }
            } else {
                EmptyStateView(
                    icon: "square.grid.3x3.fill",
                    title: "The loom is warped and ready",
                    subtitle: "The first thread lands with your first work session. Nothing here is behind — it just hasn't started."
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.bottom, 20)
    }

    private func tapestry(days: [WeaveDay]) -> some View {
        return VStack(spacing: 6) {
            GeometryReader { geometry in
                wovenThreads(days: days)
                .frame(width: geometry.size.width, height: Self.columnHeight + 10)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            selectDay(
                                at: value.location.x,
                                chartWidth: geometry.size.width,
                                days: days
                            )
                        }
                )
                .background {
                    ZStack {
                        Color.filumaSurface
                        grid(color: Color.filumaBorder.opacity(0.42))
                    }
                    .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(height: Self.columnHeight + 10)
            // A chart is one interaction surface, not fourteen undersized
            // pseudo-buttons. Touch selects the nearest day anywhere in the
            // generous plot; assistive technologies scrub the same sequence.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(period) day weave")
            .accessibilityValue(chartAccessibilityValue(days: days))
            .accessibilityHint("Swipe up or down to read each day")
            .accessibilityAdjustableAction { direction in
                adjustSelectedDay(direction, days: days)
            }
            .accessibilityIdentifier("weave.tapestry")
            .sensoryFeedback(.selection, trigger: selectedDay?.id)

            HStack(spacing: 5) {
                ForEach(days) { day in
                    Text(period == 30 ? (Calendar.current.component(.day, from: day.date).isMultiple(of: 5) ? day.date.formatted(.dateTime.day()) : "") : weekdayLetter(day.date))
                        .font(AppFont.caption(9))
                        .foregroundStyle(
                            Calendar.current.isDateInToday(day.date)
                                ? Color.brand300
                                : Color.filumaFaint
                        )
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var contextLegend: some View {
        ForEach(TaskContext.allCases) { context in
            HStack(spacing: 6) {
                Circle().fill(context.color).frame(width: 6, height: 6)
                Text(context.rawValue).font(AppFont.caption(11)).foregroundStyle(Color.filumaSubtle)
            }
        }
    }

    private func selectDay(at x: CGFloat, chartWidth: CGFloat, days: [WeaveDay]) {
        guard !days.isEmpty, chartWidth > 0 else { return }
        let fraction = min(max(x / chartWidth, 0), 0.999_999)
        let index = min(days.count - 1, Int(fraction * CGFloat(days.count)))
        let day = days[index]
        withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
            selectedDay = selectedDay == day ? nil : day
        }
    }

    private func adjustSelectedDay(
        _ direction: AccessibilityAdjustmentDirection,
        days: [WeaveDay]
    ) {
        guard !days.isEmpty else { return }
        let currentIndex = selectedDay.flatMap { days.firstIndex(of: $0) }
            ?? (direction == .decrement ? days.count : -1)
        let nextIndex: Int
        switch direction {
        case .increment:
            nextIndex = min(days.count - 1, currentIndex + 1)
        case .decrement:
            nextIndex = max(0, currentIndex - 1)
        @unknown default:
            return
        }
        withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
            selectedDay = days[nextIndex]
        }
    }

    private func chartAccessibilityValue(days: [WeaveDay]) -> String {
        if let selectedDay {
            return detailLine(for: selectedDay)
        }
        let totalMinutes = days.reduce(0) { $0 + $1.totalMinutes }
        return "No day selected. \(CountdownFormatter.effortString(minutes: totalMinutes)) woven across \(days.count) days."
    }

    /// Knots encode recorded minutes; the fine connecting strand communicates
    /// continuity, not unrecorded work on intervening days.
    private func wovenThreads(days: [WeaveDay]) -> some View {
        Canvas { drawing, size in
            guard !days.isEmpty else { return }
            let step = size.width / CGFloat(days.count)
            let maxMinutes = max(days.flatMap { $0.minutesByContext.values }.max() ?? 1, 1)
            for (index, day) in days.enumerated() {
                let x = (CGFloat(index) + 0.5) * step
                var warp = Path()
                warp.move(to: CGPoint(x: x, y: 8))
                warp.addLine(to: CGPoint(x: x, y: size.height - 8))
                drawing.stroke(warp, with: .linearGradient(
                    Gradient(colors: [.clear, Color.filumaSubtle.opacity(0.25), .clear]),
                    startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x, y: size.height)
                ), lineWidth: selectedDay == day ? 3 : 1)
                if selectedDay == day {
                    drawing.fill(Path(CGRect(x: x - step / 2, y: 0, width: step, height: size.height)),
                                 with: .color(Color.brand300.opacity(0.09)))
                }
            }
            for (contextIndex, context) in TaskContext.allCases.enumerated() {
                let active = days.enumerated().filter { ($0.element.minutesByContext[context] ?? 0) > 0 }
                guard !active.isEmpty else { continue }
                let points = active.map { index, day -> CGPoint in
                    // Vertical travel is the weave, not a value axis. Knots
                    // alone encode effort, while context strands cross in time.
                    let phase = CGFloat(index) * 0.62 + CGFloat(contextIndex) * 2.094
                    return CGPoint(x: (CGFloat(index) + 0.5) * step,
                                   y: size.height * (0.5 + sin(phase) * 0.32))
                }
                var thread = Path()
                thread.move(to: points[0])
                for index in points.indices.dropFirst() {
                    let previous = points[index - 1]
                    let point = points[index]
                    let middle = (previous.x + point.x) / 2
                    thread.addCurve(to: point,
                                    control1: CGPoint(x: middle, y: previous.y),
                                    control2: CGPoint(x: middle, y: point.y))
                }
                drawing.stroke(thread, with: .color(context.color.opacity(0.65)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round))
                drawing.stroke(thread, with: .color(context.displayColor.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                for (index, entry) in active.enumerated() {
                    let minutes = entry.element.minutesByContext[context] ?? 0
                    let radius = 2.5 + sqrt(CGFloat(minutes) / CGFloat(maxMinutes)) * 3
                    let point = points[index]
                    let knot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                     width: radius * 2, height: radius * 2))
                    let opacity = selectedDay == nil || selectedDay == entry.element ? 1.0 : 0.4
                    drawing.fill(knot, with: .color(context.color.opacity(opacity)))
                    drawing.stroke(knot, with: .color(context.displayColor.opacity(opacity)), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func grid(color: Color) -> some View {
        LinearGradient(colors: [Color.brand500.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func weekdayLetter(_ date: Date) -> String {
        String(TimeFormatter.dayOfWeek.string(from: date).prefix(1))
    }

    private func detailLine(for day: WeaveDay) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        let name = Calendar.current.isDateInToday(day.date) ? "Today" : formatter.string(from: day.date)
        guard day.totalMinutes > 0 else {
            return "\(name): a rest day. The warp holds."
        }
        let parts = TaskContext.allCases
            .compactMap { context -> String? in
                guard let minutes = day.minutesByContext[context], minutes > 0 else { return nil }
                return "\(context.rawValue) \(CountdownFormatter.effortString(minutes: minutes))"
            }
            .joined(separator: " · ")
        let starts = day.sessionCount > 0
            ? " — \(day.sessionCount == 1 ? "1 start" : "\(day.sessionCount) starts")"
            : ""
        return "\(name): \(CountdownFormatter.effortString(minutes: day.totalMinutes)) woven. \(parts)\(starts)"
    }

    // MARK: Inline reflection

    private var statsSection: some View {
        let all = days
        let totalMinutes = all.reduce(0) { $0 + $1.totalMinutes }
        let totalStarts = all.reduce(0) { $0 + $1.sessionCount }
        let streak = tasks.filter { task in
            guard task.isComplete, let completed = task.completedAt, let first = all.first else { return false }
            return completed >= first.date && completed <= Date.now
        }.count

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    weaveMetrics(totalMinutes: totalMinutes, totalStarts: totalStarts, streak: streak)
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    weaveMetrics(totalMinutes: totalMinutes, totalStarts: totalStarts, streak: streak)
                }
            }
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func weaveMetrics(totalMinutes: Int, totalStarts: Int, streak: Int) -> some View {
        WeaveMetric(
            value: CountdownFormatter.effortString(minutes: totalMinutes),
            label: "focused",
            tint: .filumaText
        )
        WeaveMetric(
            value: "\(totalStarts)",
            label: totalStarts == 1 ? "session" : "sessions",
            tint: .filumaText
        )
        WeaveMetric(
            value: "\(streak)",
            label: "tasks finished",
            tint: .personalDisplay
        )
    }

    // MARK: - This week's threads

    /// One or two specific, true things worth saying out loud — generated
    /// from the record, never canned praise.
    @ViewBuilder
    private var threadsSection: some View {
        let lines = threadLines
        if !lines.isEmpty {
            weaveDivider

            VStack(alignment: .leading, spacing: 12) {
                Text("This week’s threads")
                    .font(AppFont.heading(15))
                    .foregroundStyle(Color.filumaText)

                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(AppFont.bodySemibold(14))
                        .foregroundStyle(Color.filumaText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FilumaSpacing.screen)
            .padding(.vertical, 18)
        }
    }

    private var threadLines: [String] {
        var lines: [String] = []
        let calendar = Calendar.current
        let now = Date()
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else { return lines }

        // Most recent task finished ahead of its deadline.
        if let earlyWin = tasks
            .filter({ $0.isComplete })
            .compactMap({ task -> (FilumaTask, Date)? in
                guard let done = task.completedAt, done >= weekAgo, done < task.deadline else { return nil }
                return (task, done)
            })
            .max(by: { $0.1 < $1.1 }) {
            let lead = earlyWin.0.deadline.timeIntervalSince(earlyWin.1)
            let leadLabel: String
            if lead >= 172_800 { leadLabel = "\(Int(lead) / 86_400) days early" }
            else if lead >= 86_400 { leadLabel = "a day early" }
            else if lead >= 3600 { leadLabel = "\(Int(lead) / 3600)h early" }
            else { leadLabel = "ahead of the deadline" }
            lines.append("Finished \(earlyWin.0.title) \(leadLabel)")
        }

        // Attendance: of the last 7 days that had planned blocks, how many
        // saw you actually show up (a session started that day).
        let weekDays = (0..<7).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: now))
        }
        let plannedDays = weekDays.filter { day in
            blocks.contains { calendar.isDate($0.startTime, inSameDayAs: day) }
        }
        if plannedDays.count >= 2 {
            let showedUp = plannedDays.filter { day in
                sessions.contains { calendar.isDate($0.startedAt, inSameDayAs: day) }
            }.count
            if showedUp > 0 {
                lines.append("Showed up \(showedUp) of \(plannedDays.count) planned days")
            }
        }

        return Array(lines.prefix(2))
    }

    // MARK: Estimate heat

    @ViewBuilder
    private var estimateHeatLine: some View {
        if let heat = WeaveBuilder.estimateHeat(tasks: tasks) {
            weaveDivider

            VStack(alignment: .leading, spacing: 6) {
                Text("Estimate pattern")
                    .font(AppFont.heading(15))
                    .foregroundStyle(Color.filumaText)
                Text(heatLine(heat))
                    .font(AppFont.body(13))
                    .foregroundStyle(Color.filumaSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FilumaSpacing.screen)
            .padding(.vertical, 18)
        }
    }

    private func heatLine(_ heat: Double) -> String {
        String(
            format: "Across recent completed tasks, tracked time is about %.1f× the original estimate.",
            heat
        )
    }

    // MARK: Wins

    @ViewBuilder
    private var winsSection: some View {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let wins = tasks
            .filter { $0.isComplete && ($0.completedAt ?? .distantPast) >= weekAgo }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

        if !wins.isEmpty {
            weaveDivider

            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Finished this week")
                                .font(AppFont.heading(15))
                                .foregroundStyle(Color.filumaText)
                            Text("\(wins.count) \(wins.count == 1 ? "task" : "tasks")")
                                .font(AppFont.caption(12))
                                .foregroundStyle(Color.filumaSubtle)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("Finished this week")
                                .font(AppFont.heading(15))
                                .foregroundStyle(Color.filumaText)
                            Text("\(wins.count)")
                                .font(AppFont.caption(12))
                                .foregroundStyle(Color.filumaFaint)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .accessibilityElement(children: .combine)

                ForEach(wins) { task in
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.title)
                                    .font(AppFont.bodySemibold(14))
                                    .foregroundStyle(Color.filumaText)
                                if task.timeSpentMinutes > 0 {
                                    Text(CountdownFormatter.effortString(minutes: task.timeSpentMinutes))
                                        .font(AppFont.monoMedium(11))
                                        .foregroundStyle(Color.filumaSubtle)
                                }
                            }
                        } else {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(task.context.color)
                                    .frame(width: 7, height: 7)
                                    .accessibilityHidden(true)
                                Text(task.title)
                                    .font(AppFont.bodySemibold(14))
                                    .foregroundStyle(Color.filumaText)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if task.timeSpentMinutes > 0 {
                                    Text(CountdownFormatter.effortString(minutes: task.timeSpentMinutes))
                                        .font(AppFont.monoMedium(11))
                                        .foregroundStyle(Color.filumaSubtle)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FilumaSpacing.screen)
            .padding(.vertical, 18)
        }
    }

    private var weaveDivider: some View {
        Rectangle()
            .fill(Color.filumaBorder)
            .frame(height: 1)
            .padding(.horizontal, FilumaSpacing.screen)
            .accessibilityHidden(true)
    }
}

// MARK: - Inline metric

private struct WeaveMetric: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(AppFont.mono(18))
                .foregroundStyle(tint)
            Text(label)
                .font(AppFont.caption(11))
                .foregroundStyle(Color.filumaSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
