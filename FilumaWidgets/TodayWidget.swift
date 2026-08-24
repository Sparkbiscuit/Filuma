import WidgetKit
import SwiftUI
import SwiftData

enum WidgetStore {
    static let container = try? SharedStore.makeContainer()
}

// MARK: - Timeline

struct TodayEntry: TimelineEntry {
    let date: Date
    let isPro: Bool
    let doneBlocks: Int
    let totalBlocks: Int
    let nextTitle: String?
    let nextStart: Date?
    let nextTaskId: UUID?
    let streakDays: Int

    var allDone: Bool { totalBlocks > 0 && doneBlocks >= totalBlocks }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(
            date: Date(),
            isPro: true,
            doneBlocks: 1,
            totalBlocks: 3,
            nextTitle: "Finish lab report",
            nextStart: Date().addingTimeInterval(3600),
            nextTaskId: nil,
            streakDays: 4
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(fetchEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = fetchEntry()
        let now = entry.date
        var boundaries: [Date] = []
        if let start = entry.nextStart, start > now { boundaries.append(start) }
        let fallback = now.addingTimeInterval(30 * 60)
        let refresh = boundaries.min().map { min($0, fallback) } ?? fallback
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func fetchEntry() -> TodayEntry {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let container = WidgetStore.container,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return TodayEntry(
                date: now, isPro: FilumaProAccess.isPro,
                doneBlocks: 0, totalBlocks: 0,
                nextTitle: nil, nextStart: nil, nextTaskId: nil, streakDays: 0
            )
        }
        let context = ModelContext(container)

        // Today's work: checked blocks stay countable even after their task
        // completes (the work happened); unchecked blocks of completed tasks
        // don't linger — they're removed on completion.
        let blockDescriptor = FetchDescriptor<ScheduledBlock>(
            predicate: #Predicate { block in
                block.startTime >= today && block.startTime < tomorrow
            },
            sortBy: [SortDescriptor(\ScheduledBlock.startTime)]
        )
        let todayBlocks = ((try? context.fetch(blockDescriptor)) ?? [])
            .filter { block in
                guard let task = block.task else { return false }
                return block.isComplete || !task.isComplete
            }
        let done = todayBlocks.filter(\.isComplete).count

        let next = todayBlocks
            .filter { block in
                guard let task = block.task else { return false }
                return !block.isComplete && !task.isComplete && block.endTime > now
            }
            .min { $0.startTime < $1.startTime }

        let sessionDescriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate { $0.startedAt <= now },
            sortBy: [SortDescriptor(\WorkSession.startedAt, order: .reverse)]
        )
        let sessions = (try? context.fetch(sessionDescriptor)) ?? []
        let streak = StreakCalculator.startStreak(startDates: sessions.map(\.startedAt), now: now)

        return TodayEntry(
            date: now,
            isPro: FilumaProAccess.isPro,
            doneBlocks: done,
            totalBlocks: todayBlocks.count,
            nextTitle: next?.task?.title,
            nextStart: next?.startTime,
            nextTaskId: next?.task?.id,
            streakDays: streak
        )
    }
}

// MARK: - Widget

/// Today at a glance: blocks done vs planned, the next one up, and the start
/// streak — the day's shape without opening anything. The Lock Screen ring is
/// the anti-time-blindness dial.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayWidget", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Blocks done today, what's next, and your start streak.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Views

private struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        if entry.isPro {
            switch family {
            case .accessoryCircular:
                circularView
            case .accessoryInline:
                inlineView
            default:
                smallView
            }
        } else {
            ProWidgetGate(family: family)
        }
    }

    private var deepLink: URL {
        if let taskId = entry.nextTaskId {
            return URL(string: "filuma://start-session/\(taskId.uuidString)")
                ?? URL(string: "filuma://open")!
        }
        return URL(string: "filuma://open")!
    }

    // MARK: Lock Screen

    private var circularView: some View {
        Group {
            if entry.totalBlocks > 0 {
                Gauge(
                    value: Double(entry.doneBlocks),
                    in: 0...Double(entry.totalBlocks)
                ) {
                    Image(systemName: "circle.hexagongrid.fill")
                } currentValueLabel: {
                    Text("\(entry.doneBlocks)/\(entry.totalBlocks)")
                        .font(AppFont.heading(15))
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 1) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(entry.streakDays)")
                            .font(AppFont.heading(15))
                    }
                }
            }
        }
        .widgetURL(deepLink)
        .containerBackground(.clear, for: .widget)
    }

    private var inlineView: some View {
        Group {
            if entry.allDone {
                Text("Filuma: today all woven")
            } else if entry.totalBlocks > 0 {
                Text("Filuma: \(entry.doneBlocks)/\(entry.totalBlocks) blocks done")
            } else {
                Text("Filuma: nothing scheduled")
            }
        }
        .widgetURL(deepLink)
        .containerBackground(.clear, for: .widget)
    }

    // MARK: Home Screen

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                // Mini flame ring: blocks done vs planned.
                ZStack {
                    HearthProgressRing(
                        progress: entry.totalBlocks > 0
                            ? Double(entry.doneBlocks) / Double(entry.totalBlocks)
                            : 0,
                        size: 44,
                        lineWidth: 5
                    )
                    Text("\(entry.doneBlocks)/\(entry.totalBlocks)")
                        .font(AppFont.mono(11))
                        .foregroundStyle(Color.filumaText)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 48, height: 48)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Blocks done today")
                .accessibilityValue("\(entry.doneBlocks) of \(entry.totalBlocks)")

                Spacer()

                if entry.streakDays >= 2 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.brand300)
                        Text("\(entry.streakDays)")
                            .font(AppFont.mono(11))
                            .foregroundStyle(Color.brand100)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.brand500.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Color.brand500.opacity(0.35), lineWidth: 1))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.streakDays) day streak")
                }
            }

            Spacer(minLength: 4)

            if entry.allDone {
                Text("All woven for today.")
                    .font(AppFont.cardTitle(13))
                    .foregroundStyle(Color.personalDisplay)
            } else if let title = entry.nextTitle, let start = entry.nextStart {
                VStack(alignment: .leading, spacing: 1) {
                    Text("NEXT · \(TimeFormatter.clock.string(from: start))")
                        .font(AppFont.caption(9))
                        .foregroundStyle(Color.brand300)
                        .kerning(0.5)
                    Text(title)
                        .font(AppFont.cardTitle(13))
                        .foregroundStyle(Color.filumaText)
                        .lineLimit(2)
                    let left = entry.totalBlocks - entry.doneBlocks
                    Text(left == 1 ? "1 block left today" : "\(left) blocks left today")
                        .font(AppFont.caption(10))
                        .foregroundStyle(Color.filumaSubtle)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nothing scheduled")
                        .font(AppFont.cardTitle(13))
                        .foregroundStyle(Color.filumaText)
                    Text("A clear day is a valid plan.")
                        .font(AppFont.caption(10))
                        .foregroundStyle(Color.filumaSubtle)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .widgetURL(deepLink)
        .containerBackground(for: .widget) {
            HearthWidgetBackground()
        }
    }
}

struct ProWidgetGate: View {
    let family: WidgetFamily

    private let upgradeURL = URL(string: "filuma://upgrade")!

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text("Filuma Pro: unlock widgets")
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "flame.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text("FILUMA PRO")
                        .font(AppFont.caption(9))
                    Text("Unlock your plan at a glance")
                        .font(AppFont.bodySemibold(13))
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.brand300)
                    Text("Filuma Pro")
                        .font(AppFont.heading(16))
                        .foregroundStyle(Color.filumaText)
                    Text("Unlock your plan at a glance.")
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.filumaSubtle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.colorScheme, .dark)
            }
        }
        .widgetURL(upgradeURL)
        .containerBackground(for: .widget) {
            if family == .systemSmall || family == .systemMedium {
                HearthWidgetBackground()
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Widget backdrop

/// Dark hearth surface with the flame banked at the bottom and a scatter of
/// ember sparks — the widget-sized version of the app's ambient background.
/// WidgetKit renders are static, so the embers are a frozen moment of the
/// rising fire rather than an animation. Widgets always render the dark look;
/// the dark environment override upstream keeps adaptive text legible on it.
struct HearthWidgetBackground: View {
    private struct Spark: Identifiable {
        let id: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let alpha: Double
    }

    /// Deterministic spark field (unit coordinates, biased toward the hearth
    /// at the bottom) so every render looks alive but identical.
    private static let sparks: [Spark] = [
        Spark(id: 0, x: 0.14, y: 0.82, size: 3.0, alpha: 0.55),
        Spark(id: 1, x: 0.32, y: 0.64, size: 2.2, alpha: 0.35),
        Spark(id: 2, x: 0.47, y: 0.88, size: 3.6, alpha: 0.6),
        Spark(id: 3, x: 0.63, y: 0.72, size: 2.4, alpha: 0.4),
        Spark(id: 4, x: 0.78, y: 0.9, size: 3.0, alpha: 0.5),
        Spark(id: 5, x: 0.88, y: 0.58, size: 2.0, alpha: 0.3)
    ]

    var body: some View {
        let accent = HearthAccent.current
        ZStack {
            Color(hex: 0x131316)

            // The held flame below, per the design's widget frames.
            RadialGradient(
                colors: [Color.brand500.opacity(0.34), .clear],
                center: UnitPoint(x: 0.5, y: 1.12),
                startRadius: 0,
                endRadius: 260
            )

            GeometryReader { geo in
                ForEach(Self.sparks) { spark in
                    Circle()
                        .fill(accent.soft)
                        .frame(width: spark.size, height: spark.size)
                        .blur(radius: 0.5)
                        .shadow(color: accent.color.opacity(0.7), radius: 3)
                        .opacity(spark.alpha)
                        .position(
                            x: spark.x * geo.size.width,
                            y: spark.y * geo.size.height
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }
}
