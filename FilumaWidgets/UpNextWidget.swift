import WidgetKit
import SwiftUI
import SwiftData

// MARK: - Timeline

struct UpNextEntry: TimelineEntry {
    /// A row on the widget: a scheduled work block or a point-in-time reminder,
    /// merged into one chronological stream.
    struct ItemInfo: Identifiable {
        enum Kind {
            case block
            case reminder
        }

        let id: UUID
        let kind: Kind
        let title: String
        let contextName: String
        let start: Date
        let end: Date
        var taskId: UUID? = nil

        func isActive(at date: Date) -> Bool {
            kind == .block && start <= date && date < end
        }

        /// Tap target: blocks jump straight into the work session timer for
        /// their task; reminders just open the app.
        var deepLink: URL {
            if kind == .block, let taskId {
                return URL(string: "filuma://start-session/\(taskId.uuidString)")
                    ?? URL(string: "filuma://open")!
            }
            return URL(string: "filuma://open")!
        }
    }

    let date: Date
    let isPro: Bool
    let items: [ItemInfo]
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: Date(), isPro: true, items: [
            .init(id: UUID(), kind: .block, title: "Finish lab report", contextName: "School",
                  start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(5400))
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(fetchEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let entry = fetchEntry()

        // Wake at the next block/reminder boundary so "Now" flips without polling.
        let now = entry.date
        var boundaries: [Date] = []
        for item in entry.items {
            if item.start > now { boundaries.append(item.start) }
            if item.end > now { boundaries.append(item.end) }
        }
        let fallback = now.addingTimeInterval(30 * 60)
        let refresh = boundaries.min().map { min($0, fallback) } ?? fallback

        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func fetchEntry() -> UpNextEntry {
        let now = Date()
        guard let container = WidgetStore.container else {
            return UpNextEntry(date: now, isPro: FilumaProAccess.isPro, items: [])
        }
        let context = ModelContext(container)

        let activeDescriptor = FetchDescriptor<ScheduledBlock>(
            predicate: #Predicate { block in
                !block.isComplete && block.durationMinutes > 0
                    && block.startTime < now && block.task?.isComplete == false
            },
            sortBy: [SortDescriptor(\ScheduledBlock.startTime)]
        )
        let activeBlocks = ((try? context.fetch(activeDescriptor)) ?? [])
            .filter { $0.endTime > now }

        var upcomingDescriptor = FetchDescriptor<ScheduledBlock>(
            predicate: #Predicate { block in
                !block.isComplete && block.durationMinutes > 0
                    && block.startTime >= now && block.task?.isComplete == false
            },
            sortBy: [SortDescriptor(\ScheduledBlock.startTime)]
        )
        upcomingDescriptor.fetchLimit = 4
        let upcomingBlocks = (try? context.fetch(upcomingDescriptor)) ?? []

        let blocks = (activeBlocks + upcomingBlocks)
            .map { block in
                UpNextEntry.ItemInfo(
                    id: block.id,
                    kind: .block,
                    title: block.task?.title ?? "Task",
                    contextName: block.task?.context.rawValue ?? "",
                    start: block.startTime,
                    end: block.endTime,
                    taskId: block.task?.id
                )
            }

        var reminderDescriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { !$0.isComplete && $0.dueDate > now },
            sortBy: [SortDescriptor(\Reminder.dueDate)]
        )
        reminderDescriptor.fetchLimit = 4
        let reminders = ((try? context.fetch(reminderDescriptor)) ?? [])
            .map { reminder in
                UpNextEntry.ItemInfo(
                    id: reminder.id,
                    kind: .reminder,
                    title: reminder.title,
                    contextName: "",
                    start: reminder.dueDate,
                    end: reminder.dueDate
                )
            }

        let items = (blocks + reminders)
            .sorted { $0.start < $1.start }
            .prefix(4)

        return UpNextEntry(
            date: now,
            isPro: FilumaProAccess.isPro,
            items: Array(items)
        )
    }
}

// MARK: - Widget

/// Home Screen / Lock Screen glance at the next scheduled blocks. Styled with
/// the app's own palette and type so it reads as Filuma, and adapts to
/// light/dark like a native widget.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNextWidget", provider: UpNextProvider()) { entry in
            UpNextWidgetView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("Your next work blocks and reminders at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Views

private func widgetContextColor(_ name: String) -> Color {
    TaskContext(rawValue: name)?.color ?? .brand500
}

private struct UpNextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpNextEntry

    var body: some View {
        if entry.isPro {
            switch family {
            case .accessoryInline:
                inlineView
            case .accessoryRectangular:
                rectangularView
            case .systemMedium:
                mediumView
            default:
                smallView
            }
        } else {
            ProWidgetGate(family: family)
        }
    }

    private var next: UpNextEntry.ItemInfo? { entry.items.first }

    private func timeLabel(_ item: UpNextEntry.ItemInfo) -> String {
        if item.kind == .reminder {
            return TimeFormatter.clock.string(from: item.start)
        }
        return "\(TimeFormatter.clock.string(from: item.start)) – \(TimeFormatter.clock.string(from: item.end))"
    }

    private func itemColor(_ item: UpNextEntry.ItemInfo) -> Color {
        item.kind == .reminder ? .brand500 : widgetContextColor(item.contextName)
    }

    private func itemLabel(_ item: UpNextEntry.ItemInfo) -> String {
        if item.kind == .reminder { return "REMINDER" }
        return item.isActive(at: entry.date) ? "NOW" : "UP NEXT"
    }

    // MARK: Home Screen

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = next {
                let color = itemColor(item)

                HStack(spacing: 5) {
                    if item.kind == .reminder {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(color)
                            .accessibilityHidden(true)
                    } else {
                        Circle()
                            .fill(color)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    Text(itemLabel(item))
                        .font(AppFont.caption(10))
                        .foregroundStyle(color)
                        .kerning(0.5)
                }
                .padding(.bottom, 6)

                Text(item.title)
                    .font(AppFont.heading(15))
                    .foregroundStyle(Color.filumaText)
                    .lineLimit(2)
                    .padding(.bottom, 3)

                Text(timeLabel(item))
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.filumaSubtle)

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    if item.kind == .block {
                        // One tap from Home Screen to a running timer.
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(color)
                            .accessibilityHidden(true)
                        Text("Start")
                            .font(AppFont.caption(11))
                            .foregroundStyle(color)
                    }
                    Spacer(minLength: 0)
                    if entry.items.count > 1 {
                        Text("+\(entry.items.count - 1) more")
                            .font(AppFont.caption(10))
                            .foregroundStyle(Color.filumaFaint)
                    }
                }
            } else {
                emptyView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .widgetURL(next?.deepLink)
        .containerBackground(for: .widget) {
            HearthWidgetBackground()
        }
    }

    /// The home screen's glowing-thread list, widget-sized: a fading thread
    /// down the left edge, context dots breaking through it, the active item
    /// in accent with "Now" instead of a time.
    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 7) {
            if entry.items.isEmpty {
                emptyView
            } else {
                Text("UP NEXT")
                    .font(AppFont.caption(9))
                    .foregroundStyle(Color.filumaSubtle)
                    .kerning(1.2)
                    .padding(.leading, 18)

                ZStack(alignment: .topLeading) {
                    LinearGradient(
                        colors: [Color.brand300.opacity(0.8), Color.brand300.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, 3)
                    .padding(.vertical, 4)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(entry.items.prefix(4)) { item in
                            threadRow(item)
                        }
                    }
                    .padding(.leading, 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .containerBackground(for: .widget) {
            HearthWidgetBackground()
        }
    }

    private func threadRow(_ item: UpNextEntry.ItemInfo) -> some View {
        let isActive = item.isActive(at: entry.date)
        let color = isActive ? Color.brand300 : itemColor(item)

        return Link(destination: item.deepLink) {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(AppFont.cardTitle(13))
                    .foregroundStyle(isActive ? Color.brand100 : Color.filumaText)
                    .lineLimit(1)

                if item.kind == .reminder {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(color)
                }

                Spacer(minLength: 0)

                Text(isActive ? "Now" : TimeFormatter.clock.string(from: item.start))
                    .font(AppFont.mono(11))
                    .foregroundStyle(color)
            }
            .overlay(alignment: .leading) {
                Circle()
                    .fill(color)
                    .frame(width: isActive ? 9 : 7, height: isActive ? 9 : 7)
                    .shadow(color: color.opacity(0.8), radius: 4)
                    // A fixed housing keeps both dot sizes on one centerline:
                    // rows sit 18pt in, so -18.5 lands the housing's center on
                    // the rail's centerline at x = 4 (3pt inset + half its 2pt
                    // width).
                    .frame(width: 9, height: 9)
                    .offset(x: -18.5)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(threadRowAccessibilityLabel(item, isActive: isActive))
    }

    private func threadRowAccessibilityLabel(_ item: UpNextEntry.ItemInfo, isActive: Bool) -> String {
        var parts = [item.title]
        if item.kind == .reminder {
            parts.append("Reminder")
        } else if !item.contextName.isEmpty {
            parts.append(item.contextName)
        }
        parts.append(isActive ? "Now" : TimeFormatter.clock.string(from: item.start))
        return parts.joined(separator: ", ")
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ALL CLEAR")
                .font(AppFont.caption(10))
                .foregroundStyle(Color.filumaFaint)
                .kerning(0.5)
            Text("Nothing scheduled")
                .font(AppFont.heading(14))
                .foregroundStyle(Color.filumaText)
            Spacer(minLength: 0)
        }
    }

    // MARK: Lock Screen

    private var rectangularView: some View {
        Group {
            if let item = next {
                VStack(alignment: .leading, spacing: 1) {
                    Text(itemLabel(item))
                        .font(AppFont.caption(10))
                        .widgetAccentable()
                    Text(item.title)
                        .font(AppFont.heading(14))
                        .lineLimit(1)
                    Text(timeLabel(item))
                        .font(AppFont.monoMedium(11))
                        .opacity(0.7)
                }
            } else {
                Text("Filuma: nothing scheduled")
                    .font(AppFont.bodySemibold(13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(next?.deepLink)
        .containerBackground(.clear, for: .widget)
    }

    private var inlineView: some View {
        Group {
            if let item = next {
                Text("\(item.isActive(at: entry.date) ? "Now" : TimeFormatter.clock.string(from: item.start)): \(item.title)")
            } else {
                Text("Filuma: all clear")
            }
        }
        .widgetURL(next?.deepLink)
        .containerBackground(.clear, for: .widget)
    }
}
