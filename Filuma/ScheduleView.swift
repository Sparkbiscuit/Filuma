import SwiftUI
import SwiftData

private struct ScheduleReminderRetry {
    let reminderID: UUID
    let mutation: ReminderMutation
}

struct ScheduleView: View {
    private enum ViewMode: String, CaseIterable {
        case day = "Day"
        case week = "Week"
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var navigationDockClearance: CGFloat = 110
    @Query(sort: \ScheduledBlock.startTime) private var allBlocks: [ScheduledBlock]
    @Query private var blockedTimes: [BlockedTime]
    @Query private var busyEvents: [BusyEvent]
    @Query private var reminders: [Reminder]
    @Query private var settingsArray: [UserSettings]
    @State private var selectedDate = Date()
    @State private var dayStripAnchor = Date()
    @State private var viewMode: ViewMode = .day
    @State private var weekOffset = 0
    @State private var completionReceipt: TaskCompletionReceipt?
    @State private var pendingCompletionReceipt: TaskCompletionReceipt?
    @State private var progressPromptBlock: ScheduledBlock?
    @State private var progressUpdateMessage: String?
    @State private var taskStatusMessage: String?
    @State private var pendingTaskStatusMessage: String?
    @State private var reminderRetry: ScheduleReminderRetry?

    private let calendar = Calendar.current

    var body: some View {
        let stripDays = dayRange
        let visibleDays = viewMode == .day ? stripDays : weekDays
        // A calendar day owns every interval that overlaps it, not only
        // intervals that happened to start there. That keeps an overnight
        // block visible when a week-grid fragment opens its after-midnight
        // day in the detailed timeline.
        let itemsByDay = dayItemsByDate(
            for: visibleDays,
            includeOverlappingIntervals: true
        )

        return NavigationStack {
            VStack(spacing: 0) {
                header

                switch viewMode {
                case .day:
                    dayStrip(days: stripDays, itemsByDay: itemsByDay)
                    dayList(items: itemsByDay[calendar.startOfDay(for: selectedDate)] ?? [])
                case .week:
                    weekGrid(itemsByDay: itemsByDay)
                }
            }
            .hearthScreen(topGlow: 0.26, bottomGlow: 0.32)
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(
                item: $completionReceipt,
                onDismiss: presentPendingTaskStatus
            ) { receipt in
                TaskCompletionView(receipt: receipt) {
                    completionReceipt = nil
                } onUndo: {
                    let outcome = restoreTask(withID: receipt.taskID)
                    guard outcome.didRestore else { return outcome.message }
                    pendingTaskStatusMessage = outcome.message
                    completionReceipt = nil
                    return nil
                }
            }
            .sheet(
                item: $progressPromptBlock,
                onDismiss: presentPendingCompletion
            ) { block in
                if let task = block.task {
                    BlockProgressPrompt(task: task, workedMinutes: block.durationMinutes) { reported in
                        guard let reported else {
                            progressUpdateMessage = nil
                            progressPromptBlock = nil
                            return
                        }

                        if reported >= 100 {
                            // Commit now; delay only the ritual until this
                            // progress sheet has finished dismissing.
                            if completeTask(
                                task,
                                reportedProgress: reported,
                                afterSheetDismissal: true
                            ) {
                                progressUpdateMessage = nil
                                progressPromptBlock = nil
                            }
                        } else {
                            do {
                                try PlanCoordinator.savePartialProgress(
                                    task,
                                    reportedProgress: reported,
                                    context: modelContext
                                )
                                progressUpdateMessage = nil
                                progressPromptBlock = nil
                            } catch {
                                progressUpdateMessage = "Filuma couldn’t save that progress yet, so the task is still at its previous percentage. Please try again."
                            }
                        }
                    }
                    .alert(
                        "Task update",
                        isPresented: Binding(
                            get: { progressUpdateMessage != nil },
                            set: { if !$0 { progressUpdateMessage = nil } }
                        )
                    ) {
                        Button("OK", role: .cancel) {
                            progressUpdateMessage = nil
                        }
                    } message: {
                        Text(progressUpdateMessage ?? "")
                    }
                }
            }
            .alert(
                "Task update",
                isPresented: Binding(
                    get: { taskStatusMessage != nil },
                    set: {
                        if !$0 {
                            taskStatusMessage = nil
                            reminderRetry = nil
                        }
                    }
                )
            ) {
                if let retry = reminderRetry {
                    Button("Try Again") {
                        retryReminderMutation(retry)
                    }
                }
                Button("OK", role: .cancel) {
                    taskStatusMessage = nil
                    reminderRetry = nil
                }
            } message: {
                Text(taskStatusMessage ?? "")
            }
        }
    }

    // MARK: - Header (title + Day/Week toggle)

    private var header: some View {
        HStack {
            HearthTitle(text: "Schedule", size: 30)

            Spacer()

            HStack(spacing: 2) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button {
                        guard mode != viewMode else { return }
                        withAnimation(navigationAnimation) {
                            viewMode = mode
                            weekOffset = 0
                            if mode == .day {
                                dayStripAnchor = selectedDate
                            }
                        }
                    } label: {
                        Text(mode.rawValue)
                            .font(AppFont.caption(13))
                            .foregroundStyle(viewMode == mode ? Color.brand300 : Color.filumaSubtle)
                            .padding(.horizontal, 14)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(viewMode == mode ? Color.brand500.opacity(0.2) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("schedule.mode.\(mode.rawValue.lowercased())")
                    .accessibilityAddTraits(mode == viewMode ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.filumaSurface2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.filumaBorder, lineWidth: 1))
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Horizontal Day Strip

    private func dayStrip(days: [Date], itemsByDay: [Date: [DayItem]]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { date in
                        DayPill(
                            date: date,
                            isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                            hasItems: !(itemsByDay[calendar.startOfDay(for: date)] ?? []).isEmpty,
                            action: { selectDay(date) }
                        )
                        .id(date)
                    }
                }
                .padding(.horizontal, FilumaSpacing.screen)
                .padding(.vertical, 12)
            }
            .onAppear {
                proxy.scrollTo(calendar.startOfDay(for: selectedDate), anchor: .center)
            }
        }
    }

    private var dayRange: [Date] {
        let anchor = calendar.startOfDay(for: dayStripAnchor)
        guard let start = calendar.date(byAdding: .day, value: -3, to: anchor) else { return [] }
        return (0..<30).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
        }
    }

    private func selectDay(_ date: Date) {
        withAnimation(navigationAnimation) {
            selectedDate = date
        }
    }

    // MARK: - Day list

    private func dayList(items: [DayItem]) -> some View {
        ScrollView {
            if items.isEmpty {
                EmptyStateView(
                    icon: "calendar",
                    title: "No blocks scheduled",
                    subtitle: "Add tasks and they'll appear here."
                )
                .padding(.top, 40)
            } else {
                // Minute cadence so the now-line drifts and past rows dim
                // without any interaction.
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    let now = timeline.date
                    let nowLineIndex = nowLineIndex(in: items, at: now)

                    LazyVStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == nowLineIndex {
                                NowLine(now: now)
                            }
                            timelineRow(for: item, at: now)
                        }
                        if nowLineIndex == items.count {
                            NowLine(now: now)
                        }
                    }
                    .padding(.horizontal, FilumaSpacing.screen)
                    .padding(.top, 16)
                    .padding(.bottom, min(navigationDockClearance, 300))
                }
            }
        }
    }

    /// Where the thread of light sits: after everything that has ended,
    /// before whatever is running or still to come. Only shown for today.
    private func nowLineIndex(in items: [DayItem], at now: Date) -> Int? {
        guard calendar.isDate(selectedDate, inSameDayAs: now) else { return nil }
        return items.firstIndex { $0.end > now } ?? items.count
    }

    @ViewBuilder
    private func timelineRow(for item: DayItem, at now: Date) -> some View {
        let presentation = dayTimelinePresentation(for: item, on: selectedDate)

        switch item {
        case .block(let block):
            BlockCard(
                block: block,
                now: now,
                timelineInterval: presentation.interval,
                continuityLabel: presentation.continuityLabel,
                onToggle: { toggleBlock(block) },
                onToggleLock: { toggleBlockLock(block) }
            )
        case .blocked(let interval, let label):
            BlockedTimeCard(
                interval: interval,
                label: label,
                now: now,
                timelineInterval: presentation.interval,
                continuityLabel: presentation.continuityLabel
            )
        case .busy(let event):
            BusyEventCard(
                event: event,
                now: now,
                timelineInterval: presentation.interval,
                continuityLabel: presentation.continuityLabel
            )
        case .reminder(let reminder):
            ReminderScheduleCard(reminder: reminder, now: now) {
                toggleReminder(reminder)
            }
        }
    }

    // MARK: - Week grid

    private struct WeekGridWindow {
        let startHour: Int
        let endHour: Int

        var durationHours: Int {
            max(1, endHour - startHour)
        }
    }

    private struct WeekItemPresentation {
        let start: Date
        let end: Date
        let color: Color
        let title: String
    }

    private struct MinuteRange {
        let start: Double
        let end: Double
    }

    private struct WeekItemGeometry {
        let top: CGFloat
        let height: CGFloat
    }

    private struct DayTimelinePresentation {
        let interval: DateInterval
        let continuityLabel: String?
    }

    private func weekGrid(itemsByDay: [Date: [DayItem]]) -> some View {
        let week = weekDays
        let window = weekGridWindow(for: week, itemsByDay: itemsByDay)
        let pointsPerHour: CGFloat = 22
        let gridHeight = CGFloat(window.durationHours) * pointsPerHour
        let labelHours = weekGridLabelHours(for: window)

        return ScrollView {
            VStack(spacing: 6) {
                weekNavigationHeader
                .padding(.bottom, 2)

                // The dated header and its timeline share one horizontal
                // surface so narrow split views can preserve seven distinct
                // 44pt day targets without desynchronizing the columns.
                ScrollView(.horizontal) {
                    VStack(spacing: 6) {
                        // Day headers
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 28)
                            ForEach(week, id: \.self) { day in
                                Button {
                                    jumpToDay(day)
                                } label: {
                                    VStack(spacing: 1) {
                                        Text(TimeFormatter.dayOfWeek.string(from: day).uppercased())
                                            .font(AppFont.caption(9))
                                            .foregroundStyle(calendar.isDate(day, inSameDayAs: selectedDate) ? Color.brand300 : Color.filumaSubtle)
                                        Text("\(calendar.component(.day, from: day))")
                                            .font(AppFont.mono(13))
                                            .foregroundStyle(calendar.isDateInToday(day) ? Color.brand300 : Color.filumaText)
                                    }
                                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(fullDateLabel(for: day))
                                .accessibilityAddTraits(
                                    calendar.isDate(day, inSameDayAs: selectedDate)
                                        ? [.isSelected]
                                        : []
                                )
                                .accessibilityIdentifier(dayIdentifier(prefix: "schedule.weekday", date: day))
                            }
                        }

                        // Time grid
                        HStack(alignment: .top, spacing: 0) {
                            // Hour labels
                            ZStack(alignment: .topLeading) {
                                Color.clear
                                ForEach(labelHours, id: \.self) { hour in
                                    Text(hourLabel(hour))
                                        .font(AppFont.monoMedium(8))
                                        .foregroundStyle(Color.filumaFaint)
                                        .offset(y: CGFloat(hour - window.startHour) * pointsPerHour - 5)
                                }
                            }
                            .frame(width: 28, height: gridHeight)

                            // Columns
                            ZStack(alignment: .topLeading) {
                                // Hour lines
                                ForEach(labelHours, id: \.self) { hour in
                                    Rectangle()
                                        .fill(Color.filumaBorder)
                                        .frame(height: 1)
                                        .offset(y: CGFloat(hour - window.startHour) * pointsPerHour)
                                }

                                HStack(spacing: 0) {
                                    ForEach(week, id: \.self) { day in
                                        ZStack(alignment: .topLeading) {
                                            Color.clear

                                            ForEach(itemsByDay[calendar.startOfDay(for: day)] ?? []) { item in
                                                weekItemView(
                                                    item: item,
                                                    day: day,
                                                    window: window,
                                                    pointsPerHour: pointsPerHour,
                                                    gridHeight: gridHeight
                                                )
                                            }
                                        }
                                        .frame(minWidth: 44, maxWidth: .infinity)
                                        .frame(height: gridHeight)
                                        .overlay(alignment: .trailing) {
                                            Rectangle()
                                                .fill(Color.filumaBorder)
                                                .frame(width: 1)
                                        }
                                    }
                                }
                            }
                            .frame(height: gridHeight)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.filumaBorder)
                                    .frame(width: 1)
                            }
                        }
                    }
                    .containerRelativeFrame(.horizontal)
                    .frame(minWidth: 336)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .accessibilityIdentifier("schedule.weekHorizontal")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, min(navigationDockClearance, 300))
        }
        .accessibilityIdentifier("schedule.weekGrid")
        .sensoryFeedback(.selection, trigger: weekOffset)
    }

    private var weekNavigationHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                weekRangeText
                Spacer(minLength: 8)
                weekNavigationControls
            }

            VStack(alignment: .leading, spacing: 4) {
                weekRangeText
                weekNavigationControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
    }

    private var weekRangeText: some View {
        Text(weekRangeLabel)
            .font(AppFont.caption(12))
            .foregroundStyle(Color.filumaSubtle)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("schedule.weekRange")
    }

    private var weekNavigationControls: some View {
        HStack(spacing: 4) {
            weekNavigationButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Previous week",
                accessibilityIdentifier: "schedule.previousWeek"
            ) {
                moveWeek(by: -1)
            }

            Button {
                returnToCurrentWeek()
            } label: {
                Text("Today")
                    .font(AppFont.caption(12))
                    .foregroundStyle(Color.brand300)
                    .lineLimit(1)
                    .frame(minWidth: 56, minHeight: 44)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today")
            .accessibilityHint("Returns to the week containing today")
            .accessibilityIdentifier("schedule.today")

            weekNavigationButton(
                systemImage: "chevron.right",
                accessibilityLabel: "Next week",
                accessibilityIdentifier: "schedule.nextWeek"
            ) {
                moveWeek(by: 1)
            }
        }
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.filumaSurface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        )
    }

    private func weekNavigationButton(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.brand300)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows the \(accessibilityLabel.lowercased())")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func moveWeek(by offset: Int) {
        withAnimation(navigationAnimation) {
            weekOffset += offset
        }
    }

    private func returnToCurrentWeek() {
        withAnimation(navigationAnimation) {
            weekOffset = 0
            selectedDate = Date()
        }
    }

    private var navigationAnimation: Animation? {
        reduceMotion ? nil : HearthMotion.selection
    }

    private func fullDateLabel(for date: Date) -> String {
        let formatted = date.formatted(date: .complete, time: .omitted)
        return calendar.isDateInToday(date) ? "Today, \(formatted)" : formatted
    }

    private func dayIdentifier(prefix: String, date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%@.%04d-%02d-%02d",
            prefix,
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func weekGridWindow(
        for week: [Date],
        itemsByDay: [Date: [DayItem]]
    ) -> WeekGridWindow {
        let defaults = UserSettingsSchedulingDefaults.fresh
        let settings = settingsArray.first
        let wakeMinutes = minuteOfDay(
            hour: settings?.wakeHour ?? defaults.wakeHour,
            minute: settings?.wakeMinute ?? defaults.wakeMinute
        )
        let sleepMinutes = minuteOfDay(
            hour: settings?.sleepHour ?? defaults.sleepHour,
            minute: settings?.sleepMinute ?? defaults.sleepMinute
        )

        // An awake window whose sleep time is at or before wake crosses
        // midnight. Calendar-day columns therefore need both sides of the
        // boundary, which means the honest single continuous axis is 0...24.
        var earliestMinute = sleepMinutes <= wakeMinutes ? 0 : wakeMinutes
        var latestMinute = sleepMinutes <= wakeMinutes ? 24 * 60 : sleepMinutes

        for day in week {
            let key = calendar.startOfDay(for: day)
            for item in itemsByDay[key] ?? [] {
                guard let range = clampedMinuteRange(
                    for: item,
                    on: day,
                    lowerBound: 0,
                    upperBound: 24 * 60
                ) else { continue }
                earliestMinute = min(earliestMinute, Int(floor(range.start)))
                latestMinute = max(latestMinute, Int(ceil(range.end)))
            }
        }

        let startHour = max(0, min(23, earliestMinute / 60))
        let roundedEndHour = Int(ceil(Double(latestMinute) / 60))
        let endHour = max(startHour + 1, min(24, roundedEndHour))
        return WeekGridWindow(startHour: startHour, endHour: endHour)
    }

    private func weekGridLabelHours(for window: WeekGridWindow) -> [Int] {
        let step: Int
        switch window.durationHours {
        case ...8: step = 2
        case ...16: step = 3
        default: step = 4
        }

        var hours = Array(stride(from: window.startHour, through: window.endHour, by: step))
        if hours.last != window.endHour {
            hours.append(window.endHour)
        }
        return hours
    }

    private func minuteOfDay(hour: Int, minute: Int) -> Int {
        let safeHour = min(23, max(0, hour))
        let safeMinute = min(59, max(0, minute))
        return safeHour * 60 + safeMinute
    }

    /// Solid, unlabeled block in the week grid — tapping jumps to that day.
    @ViewBuilder
    private func weekItemView(
        item: DayItem,
        day: Date,
        window: WeekGridWindow,
        pointsPerHour: CGFloat,
        gridHeight: CGFloat
    ) -> some View {
        if let presentation = weekItemPresentation(for: item),
           let geometry = weekItemGeometry(
               for: item,
               on: day,
               window: window,
               pointsPerHour: pointsPerHour,
               gridHeight: gridHeight
           ) {
            let targetHeight = max(44, geometry.height)
            let targetTop = min(
                max(0, geometry.top - (targetHeight - geometry.height) / 2),
                max(0, gridHeight - targetHeight)
            )
            let visualOffset = geometry.top - targetTop

            Button {
                jumpToDay(day)
            } label: {
                ZStack(alignment: .top) {
                    Color.clear
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(presentation.color)
                        .frame(height: geometry.height)
                        .padding(.horizontal, 2)
                        .offset(y: visualOffset)
                }
                .frame(maxWidth: .infinity)
                .frame(height: targetHeight)
                .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .offset(y: targetTop)
                .accessibilityLabel(presentation.title)
                .accessibilityHint("Jumps to this day")
                .accessibilityIdentifier(
                    dayIdentifier(prefix: "schedule.weekItem", date: day)
                        + ".\(item.id)"
                )
        }
    }

    private func weekItemPresentation(for item: DayItem) -> WeekItemPresentation? {
        switch item {
        case .block(let block):
            guard block.endTime > block.startTime else { return nil }
            return WeekItemPresentation(
                start: block.startTime,
                end: block.endTime,
                color: block.task?.context.color ?? .filumaFaint,
                title: block.task?.title ?? "Task"
            )
        case .blocked(let interval, let label):
            guard interval.end > interval.start else { return nil }
            return WeekItemPresentation(
                start: interval.start,
                end: interval.end,
                color: .filumaSurface3,
                title: label
            )
        case .busy(let event):
            guard event.endTime > event.startTime else { return nil }
            return WeekItemPresentation(
                start: event.startTime,
                end: event.endTime,
                color: .filumaSurface3,
                title: event.title
            )
        case .reminder(let reminder):
            // Point-in-time: draw a thin tick at the due time.
            return WeekItemPresentation(
                start: reminder.dueDate,
                end: reminder.dueDate.addingTimeInterval(5 * 60),
                color: .brand500,
                title: reminder.title
            )
        }
    }

    private func weekItemGeometry(
        for item: DayItem,
        on day: Date,
        window: WeekGridWindow,
        pointsPerHour: CGFloat,
        gridHeight: CGFloat
    ) -> WeekItemGeometry? {
        guard let range = clampedMinuteRange(
            for: item,
            on: day,
            lowerBound: window.startHour * 60,
            upperBound: window.endHour * 60
        ) else { return nil }

        // The interval is fully clamped to both its calendar-day column and
        // the visible grid before either coordinate is calculated. This keeps
        // early, late, and cross-midnight items inside truthful bounds.
        let top = CGFloat((range.start - Double(window.startHour * 60)) / 60) * pointsPerHour
        let rawHeight = CGFloat((range.end - range.start) / 60) * pointsPerHour
        let availableHeight = max(0, gridHeight - top)
        let height = min(max(6, rawHeight), availableHeight)
        guard height > 0 else { return nil }
        return WeekItemGeometry(top: top, height: height)
    }

    private func clampedMinuteRange(
        for item: DayItem,
        on day: Date,
        lowerBound: Int,
        upperBound: Int
    ) -> MinuteRange? {
        guard let presentation = weekItemPresentation(for: item) else { return nil }
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }

        let intervalStart = max(presentation.start, dayStart)
        let intervalEnd = min(presentation.end, dayEnd)
        guard intervalEnd > intervalStart else { return nil }

        let startMinute = wallClockMinute(for: intervalStart, dayStart: dayStart, dayEnd: dayEnd)
        let endMinute = wallClockMinute(for: intervalEnd, dayStart: dayStart, dayEnd: dayEnd)
        let clampedStart = max(Double(lowerBound), startMinute)
        let clampedEnd = min(Double(upperBound), endMinute)
        guard clampedEnd > clampedStart else { return nil }
        return MinuteRange(start: clampedStart, end: clampedEnd)
    }

    private func wallClockMinute(for date: Date, dayStart: Date, dayEnd: Date) -> Double {
        if date <= dayStart { return 0 }
        if date >= dayEnd { return 24 * 60 }
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
            + Double(components.second ?? 0) / 60
    }

    private func hourLabel(_ hour: Int) -> String {
        let normalized = hour % 24
        if normalized == 0 { return "12a" }
        if normalized == 12 { return "12p" }
        return normalized > 12 ? "\(normalized - 12)p" : "\(normalized)a"
    }

    private var weekDays: [Date] {
        // Week containing the selected date, Monday first, shifted by however
        // many weeks the user has swiped.
        var cal = calendar
        cal.firstWeekday = 2
        guard let interval = cal.dateInterval(of: .weekOfYear, for: selectedDate),
              let start = cal.date(byAdding: .weekOfYear, value: weekOffset, to: interval.start) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekRangeLabel: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: first)) – \(formatter.string(from: last))"
    }

    private func jumpToDay(_ day: Date) {
        withAnimation(navigationAnimation) {
            selectedDate = day
            dayStripAnchor = day
            viewMode = .day
            weekOffset = 0
        }
    }

    // MARK: - Items

    private enum DayItem: Identifiable {
        case block(ScheduledBlock)
        case blocked(DateInterval, String)
        case busy(BusyEvent)
        case reminder(Reminder)

        var id: String {
            switch self {
            case .block(let block): return block.id.uuidString
            case .blocked(let interval, let label): return "\(label)-\(interval.start.timeIntervalSince1970)"
            case .busy(let event): return event.id.uuidString
            case .reminder(let reminder): return reminder.id.uuidString
            }
        }

        var start: Date {
            switch self {
            case .block(let block): return block.startTime
            case .blocked(let interval, _): return interval.start
            case .busy(let event): return event.startTime
            case .reminder(let reminder): return reminder.dueDate
            }
        }

        var end: Date {
            switch self {
            case .block(let block): return block.endTime
            case .blocked(let interval, _): return interval.end
            case .busy(let event): return event.endTime
            case .reminder(let reminder): return reminder.dueDate
            }
        }
    }

    private func dayItemsByDate(
        for dates: [Date],
        includeOverlappingIntervals: Bool = false
    ) -> [Date: [DayItem]] {
        let requestedDays = Set(dates.map { calendar.startOfDay(for: $0) })
        guard !requestedDays.isEmpty else { return [:] }

        var itemsByDay: [Date: [DayItem]] = [:]
        // Blocks whose task is gone are data damage, not schedule — never
        // render them as "Unknown Task" rows (the foreground sweep in
        // MainTabView deletes them).
        for block in allBlocks where block.task != nil {
            if includeOverlappingIntervals {
                for day in requestedDays where interval(
                    start: block.startTime,
                    end: block.endTime,
                    overlapsDayStartingAt: day
                ) {
                    itemsByDay[day, default: []].append(.block(block))
                }
            } else {
                let day = calendar.startOfDay(for: block.startTime)
                if requestedDays.contains(day) {
                    itemsByDay[day, default: []].append(.block(block))
                }
            }
        }

        // Keep BlockedTime.occurrences as the single source of recurrence
        // truth — same per-day window the old itemsForDate passed it.
        for blocked in blockedTimes {
            for day in requestedDays {
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
                let searchStart = includeOverlappingIntervals
                    ? (calendar.date(byAdding: .day, value: -1, to: day) ?? day)
                    : day
                itemsByDay[day, default: []].append(contentsOf: blocked
                    .occurrences(from: searchStart, to: dayEnd)
                    .filter { !includeOverlappingIntervals || ($0.end > day && $0.start < dayEnd) }
                    .map { .blocked($0, blocked.label) })
            }
        }

        for event in busyEvents {
            if includeOverlappingIntervals {
                for day in requestedDays where interval(
                    start: event.startTime,
                    end: event.endTime,
                    overlapsDayStartingAt: day
                ) {
                    itemsByDay[day, default: []].append(.busy(event))
                }
            } else {
                let day = calendar.startOfDay(for: event.startTime)
                if requestedDays.contains(day) {
                    itemsByDay[day, default: []].append(.busy(event))
                }
            }
        }

        for reminder in reminders {
            let day = calendar.startOfDay(for: reminder.dueDate)
            if requestedDays.contains(day) {
                itemsByDay[day, default: []].append(.reminder(reminder))
            }
        }

        for day in itemsByDay.keys {
            // Overlapping overnight intervals begin at midnight in this
            // day's timeline even though their durable start belongs to the
            // previous date.
            itemsByDay[day]?.sort {
                max($0.start, day) < max($1.start, day)
            }
        }
        return itemsByDay
    }

    private func interval(start: Date, end: Date, overlapsDayStartingAt day: Date) -> Bool {
        guard end > start,
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else {
            return false
        }
        return end > day && start < dayEnd
    }

    private func dayTimelinePresentation(
        for item: DayItem,
        on day: Date
    ) -> DayTimelinePresentation {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)

        if case .reminder = item {
            return DayTimelinePresentation(
                interval: DateInterval(
                    start: item.start,
                    duration: 5 * 60
                ),
                continuityLabel: nil
            )
        }

        let visibleStart = max(item.start, dayStart)
        let visibleEnd = min(item.end, dayEnd)
        let continuesFromPreviousDay = item.start < dayStart
        let continuesIntoNextDay = item.end > dayEnd

        let continuityLabel: String?
        switch (continuesFromPreviousDay, continuesIntoNextDay) {
        case (true, true):
            continuityLabel = "Continues through this day"
        case (true, false):
            continuityLabel = "Continued from yesterday"
        case (false, true):
            continuityLabel = "Continues tomorrow"
        case (false, false):
            continuityLabel = nil
        }

        return DayTimelinePresentation(
            interval: DateInterval(start: visibleStart, end: max(visibleStart, visibleEnd)),
            continuityLabel: continuityLabel
        )
    }

    // MARK: - Completion

    private func toggleBlock(_ block: ScheduledBlock) {
        let newValue = !block.isComplete
        do {
            // Attendance and its replacement coverage are one durable user
            // action. The progress prompt only opens after both have saved.
            _ = try withAnimation(
                navigationAnimation
            ) {
                try PlanCoordinator.setBlockCompletion(
                    block,
                    isComplete: newValue,
                    context: modelContext
                )
            }
            if newValue, let task = block.task, !task.isComplete {
                progressPromptBlock = block
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            taskStatusMessage = newValue
                ? "Filuma couldn’t save that block as done yet. Its attendance and plan are unchanged—try again."
                : "Filuma couldn’t reopen that block yet. Its attendance and plan are unchanged—try again."
        }
    }

    private func toggleBlockLock(_ block: ScheduledBlock) {
        guard !block.isComplete else { return }
        let originalValue = block.isLocked

        // Rollback is context-wide, so first preserve unrelated accepted
        // edits. A failed preflight must not discard those edits itself.
        do {
            try modelContext.save()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            taskStatusMessage = "Filuma couldn’t prepare that lock change yet. Nothing was changed—try again."
            return
        }

        do {
            // The lock promise and its durable save move together inside the
            // scoped transaction below.
            try modelContext.transaction {
                withAnimation(navigationAnimation) {
                    block.isLocked = !originalValue
                }
                try modelContext.save()
            }
            PlanCoordinator.publishChange(context: modelContext)
        } catch {
            modelContext.rollback()
            block.isLocked = originalValue
            modelContext.processPendingChanges()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            taskStatusMessage = originalValue
                ? "Filuma couldn’t unlock that block yet. It is still locked—try again."
                : "Filuma couldn’t lock that block yet. Its planning state is unchanged—try again."
        }
    }

    private func toggleReminder(_ reminder: Reminder) {
        let mutation: ReminderMutation = reminder.isComplete ? .restore : .complete
        applyReminderMutation(mutation, to: reminder)
    }

    private func applyReminderMutation(
        _ mutation: ReminderMutation,
        to reminder: Reminder
    ) {
        do {
            _ = try withAnimation(navigationAnimation) {
                try ReminderMutationCoordinator.apply(
                    mutation,
                    to: reminder,
                    context: modelContext
                )
            }
            taskStatusMessage = nil
            reminderRetry = nil
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            reminderRetry = ScheduleReminderRetry(
                reminderID: reminder.id,
                mutation: mutation
            )
            taskStatusMessage = mutation == .complete
                ? "Filuma couldn’t save that reminder as complete yet. It is still active—try again."
                : "Filuma couldn’t restore that reminder yet. It is still completed—try again."
        }
    }

    private func retryReminderMutation(_ retry: ScheduleReminderRetry) {
        if let heldReminder = reminders.first(where: { $0.id == retry.reminderID }) {
            applyReminderMutation(retry.mutation, to: heldReminder)
            return
        }

        let fetched: [Reminder]
        do {
            fetched = try modelContext.fetch(FetchDescriptor<Reminder>())
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            reminderRetry = retry
            taskStatusMessage = "Filuma couldn’t reload that reminder yet. Nothing else was changed—try again."
            return
        }

        guard let reminder = fetched.first(where: { $0.id == retry.reminderID }) else {
            reminderRetry = nil
            taskStatusMessage = "That reminder is no longer available to change."
            return
        }
        applyReminderMutation(retry.mutation, to: reminder)
    }

    private func completeTask(
        _ task: FilumaTask,
        reportedProgress: Int? = nil,
        afterSheetDismissal: Bool = false
    ) -> Bool {
        do {
            let receipt = try PlanCoordinator.completeTask(
                task,
                context: modelContext,
                reportedProgress: reportedProgress
            )
            if afterSheetDismissal {
                pendingCompletionReceipt = receipt
            } else {
                completionReceipt = receipt
            }
            return true
        } catch {
            let message = "Filuma couldn’t save that completion yet, so the task is still active. Please try again."
            if afterSheetDismissal {
                progressUpdateMessage = message
            } else {
                taskStatusMessage = message
            }
            return false
        }
    }

    private func presentPendingCompletion() {
        progressUpdateMessage = nil
        guard let receipt = pendingCompletionReceipt else {
            presentPendingTaskStatus()
            return
        }
        pendingCompletionReceipt = nil
        Task { @MainActor in
            await Task.yield()
            completionReceipt = receipt
        }
    }

    private struct RestoreOutcome {
        let didRestore: Bool
        let message: String?
    }

    private func restoreTask(withID taskID: UUID) -> RestoreOutcome {
        let descriptor = FetchDescriptor<FilumaTask>(
            predicate: #Predicate { $0.id == taskID }
        )
        let task: FilumaTask
        do {
            guard let fetched = try modelContext.fetch(descriptor).first else {
                return RestoreOutcome(
                    didRestore: false,
                    message: "That task is no longer available to restore."
                )
            }
            task = fetched
        } catch {
            return RestoreOutcome(
                didRestore: false,
                message: "Filuma couldn’t read that task to restore it yet. Please try again."
            )
        }

        do {
            let result = try PlanCoordinator.restoreTask(
                task,
                context: modelContext,
                interactive: false
            )
            switch result {
            case .success:
                return RestoreOutcome(didRestore: true, message: nil)
            case .partialFit(_, let unscheduledMinutes):
                let time = CountdownFormatter.effortString(minutes: unscheduledMinutes)
                return RestoreOutcome(
                    didRestore: true,
                    message: "The task is active again. \(time) still couldn’t fit before its deadline, so it will stay visibly unblocked."
                )
            case .noSlots:
                return RestoreOutcome(
                    didRestore: true,
                    message: "The task is active again, but no open time remains before its deadline. It will stay visibly unblocked."
                )
            }
        } catch {
            return RestoreOutcome(
                didRestore: false,
                message: "Filuma couldn’t save that restore, so the task is still completed. Please try again."
            )
        }
    }

    private func presentPendingTaskStatus() {
        guard let message = pendingTaskStatusMessage else { return }
        pendingTaskStatusMessage = nil
        Task { @MainActor in
            await Task.yield()
            taskStatusMessage = message
        }
    }
}

// MARK: - Day Pill

private struct DayPill: View {
    let date: Date
    let isSelected: Bool
    let hasItems: Bool
    let action: () -> Void

    private let calendar = Calendar.current

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(TimeFormatter.dayOfWeek.string(from: date).uppercased())
                    .font(AppFont.caption(10))
                    .foregroundStyle(isSelected ? Color.brand300 : Color.filumaSubtle)
                    .kerning(0.5)
                Text("\(calendar.component(.day, from: date))")
                    .font(AppFont.mono(16))
                    .foregroundStyle(isSelected ? Color.brand100 : isToday ? Color.brand300 : Color.filumaText)
                Circle()
                    .fill(hasItems ? (isSelected ? Color.brand300 : Color.brand500.opacity(0.7)) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 46, height: 66)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.brand500.opacity(0.16) : Color.filumaSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.brand500.opacity(0.5) : Color.filumaBorder, lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.brand500.opacity(0.3) : .clear, radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(dayIdentifier)
    }

    private var isToday: Bool {
        calendar.isDateInToday(date)
    }

    private var dayLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        var label = isToday ? "Today, \(formatter.string(from: date))" : formatter.string(from: date)
        if hasItems { label += ", has scheduled items" }
        return label
    }

    private var dayIdentifier: String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "schedule.day.%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

// MARK: - Timeline time gutter

/// Mono start-time label sitting in the left gutter of the day timeline.
private struct TimeGutter: View {
    let date: Date
    var dimmed: Bool = false
    var tint: Color? = nil

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    var body: some View {
        Text(Self.formatter.string(from: date))
            .font(AppFont.mono(12))
            .foregroundStyle(tint ?? (dimmed ? Color.filumaFaint : Color.filumaSubtle))
            .frame(width: 44, alignment: .trailing)
    }
}

// MARK: - Now line

/// The thread of light marking this exact minute: mono time, a breathing dot,
/// and a gradient bar fading out to the right.
private struct NowLine: View {
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            TimeGutter(date: now, tint: .brand300)

            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [Color.brand300.opacity(0.9), Color.brand500.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2)
                .hearthGlow(.brand500, radius: 6, opacity: 0.6)

                BreathingDot(color: .brand300, size: 10)
                    .offset(x: -4)
            }
        }
        .padding(.vertical, 2)
        .accessibilityLabel("Now, \(TimeFormatter.clock.string(from: now))")
    }
}

// MARK: - Block Card

private struct BlockCard: View {
    let block: ScheduledBlock
    let now: Date
    let timelineInterval: DateInterval
    let continuityLabel: String?
    var onToggle: () -> Void
    var onToggleLock: () -> Void

    private var isInSession: Bool {
        !block.isComplete && block.startTime <= now && now < block.endTime
    }

    private var isPast: Bool {
        block.isComplete || block.endTime <= now
    }

    private var hasStarted: Bool {
        block.isComplete || block.startTime <= now
    }

    private static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimeGutter(date: timelineInterval.start, dimmed: isPast && !isInSession)

            HStack(spacing: 10) {
                Group {
                    if isInSession {
                        BreathingDot(color: .brand300, size: 9)
                    } else if block.isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.personalDisplay)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.task?.title ?? "Unknown Task")
                            .font(AppFont.cardTitle(15))
                            .strikethrough(block.isComplete)
                            .foregroundStyle(block.isComplete ? Color.filumaFaint : Color.filumaText)
                            .lineLimit(1)

                        if isInSession {
                            Text("In session · \(minutesLeftLabel) left in block")
                                .font(AppFont.bodySemibold(12))
                                .foregroundStyle(Color.brand300)
                        } else {
                            HStack(spacing: 6) {
                                Text(timelineDetailLabel)
                                    .font(AppFont.monoMedium(11))
                                    .foregroundStyle(Color.filumaSubtle)
                                if block.isLocked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.filumaFaint)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 6)

                    if isInSession {
                        Text(timelineRangeLabel)
                            .font(AppFont.mono(12))
                            .foregroundStyle(Color.brand300)
                    } else if let ctx = block.task?.context, !isPast {
                        Text(ctx.rawValue)
                            .contextTag(ctx)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
                .accessibilityActions {
                    if !block.isComplete {
                        Button(block.isLocked ? "Allow Replanning" : "Lock in Place") {
                            onToggleLock()
                        }
                    }
                }

                // The check control only surfaces once the block has started —
                // future rows stay clean, per the design. Early birds can
                // still check off from the context menu.
                if hasStarted && !isInSession {
                    Button(action: onToggle) {
                        Image(systemName: block.isComplete ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(block.isComplete ? Color.personalColor : Color.filumaFaint.opacity(0.7))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(block.isComplete ? "Mark incomplete" : "Mark complete")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                    .stroke(
                        isInSession ? Color.brand500.opacity(0.45) : Color.filumaBorder,
                        lineWidth: 1
                    )
            )
            .shadow(color: isInSession ? Color.brand500.opacity(0.3) : .clear, radius: 16)
            .opacity(isPast && !block.isComplete ? 0.55 : 1)
            .contextMenu {
                Button(action: onToggle) {
                    Label(
                        block.isComplete ? "Mark Incomplete" : "Mark Complete",
                        systemImage: block.isComplete ? "arrow.uturn.backward" : "checkmark.circle"
                    )
                }
                if !block.isComplete {
                    Divider()
                    Button(action: onToggleLock) {
                        Label(
                            block.isLocked ? "Allow Replanning" : "Lock in Place",
                            systemImage: block.isLocked ? "lock.open" : "lock"
                        )
                    }
                }
            }
        }
    }

    private var accessibilityDescription: String {
        var parts = [block.task?.title ?? "Unknown Task"]
        if block.isComplete { parts.append("Complete") }
        if isInSession {
            parts.append("In session, \(minutesLeftLabel) left in block")
        } else {
            parts.append("\(Self.shortTime.string(from: timelineInterval.start)) to \(Self.shortTime.string(from: timelineInterval.end))")
            if let continuityLabel { parts.append(continuityLabel) }
            if block.isLocked { parts.append("Locked") }
            if let ctx = block.task?.context, !isPast { parts.append(ctx.rawValue) }
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isInSession {
            LinearGradient(
                stops: [
                    .init(color: Color.brand500.opacity(0.24), location: 0),
                    .init(color: Color.filumaSurface, location: 0.6)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color.filumaSurface.opacity(block.isComplete ? 0.6 : 1)
        }
    }

    private var minutesLeftLabel: String {
        let seconds = max(0, Int(block.endTime.timeIntervalSince(now)))
        return CountdownFormatter.effortString(minutes: max(1, seconds / 60))
    }

    private var timelineRangeLabel: String {
        "\(Self.shortTime.string(from: timelineInterval.start))-\(Self.shortTime.string(from: timelineInterval.end))"
    }

    private var timelineDetailLabel: String {
        if let continuityLabel {
            return "\(timelineRangeLabel) · \(continuityLabel)"
        }
        return "\(timelineRangeLabel) · \(CountdownFormatter.effortString(minutes: block.durationMinutes))"
    }
}

// MARK: - Blocked Time Card

private struct BlockedTimeCard: View {
    let interval: DateInterval
    let label: String
    let now: Date
    let timelineInterval: DateInterval
    let continuityLabel: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimeGutter(date: timelineInterval.start, dimmed: interval.end <= now)

            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.filumaFaint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(AppFont.bodySemibold(15))
                        .foregroundStyle(Color.filumaSubtle)
                    Text("Blocked")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.filumaFaint)
                }

                Spacer(minLength: 6)

                Text(rangeLabel)
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.filumaFaint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .overlay(
                RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                    .strokeBorder(Color.filumaFaint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .opacity(interval.end <= now ? 0.55 : 1)
        }
    }

    private var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return "\(formatter.string(from: timelineInterval.start))-\(formatter.string(from: timelineInterval.end))"
    }

    private var accessibilityDescription: String {
        [label, "Blocked", rangeLabel, continuityLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

// MARK: - Busy Event Card (imported from a calendar)

private struct BusyEventCard: View {
    let event: BusyEvent
    let now: Date
    let timelineInterval: DateInterval
    let continuityLabel: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimeGutter(date: timelineInterval.start, dimmed: event.endTime <= now)

            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.filumaFaint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(event.title) — busy from \(event.calendarName ?? "Calendar")")
                        .font(AppFont.bodySemibold(14))
                        .foregroundStyle(Color.filumaSubtle)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                Text(rangeLabel)
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.filumaFaint)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .overlay(
                RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                    .strokeBorder(Color.filumaFaint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .opacity(event.endTime <= now ? 0.55 : 1)
        }
    }

    private var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return "\(formatter.string(from: timelineInterval.start))-\(formatter.string(from: timelineInterval.end))"
    }

    private var accessibilityDescription: String {
        [event.title, "Busy from \(event.calendarName ?? "Calendar")", rangeLabel, continuityLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

// MARK: - Reminder card (point-in-time)

private struct ReminderScheduleCard: View {
    let reminder: Reminder
    let now: Date
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimeGutter(date: reminder.dueDate, dimmed: reminder.isComplete)

            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brand300)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(reminder.title)
                        .font(AppFont.cardTitle(15))
                        .strikethrough(reminder.isComplete)
                        .foregroundStyle(reminder.isComplete ? Color.filumaFaint : Color.filumaText)
                        .lineLimit(1)
                    Text("Reminder")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.brand300)
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 6)

                Button(action: onToggle) {
                    Image(systemName: reminder.isComplete ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(reminder.isComplete ? Color.personalColor : Color.filumaFaint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reminder.isComplete ? "Mark incomplete" : "Mark complete")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.filumaSurface.opacity(reminder.isComplete ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                    .stroke(Color.filumaBorder, lineWidth: 1)
            )
        }
    }
}

// MARK: - Block progress prompt

/// After checking off a block: the time is logged, but only the user knows how
/// far the task actually moved. Saving 100% completes the task; skipping keeps
/// progress untouched.
private struct BlockProgressPrompt: View {
    let task: FilumaTask
    let workedMinutes: Int
    /// The saved overall percentage, or nil when progress was skipped.
    var onDismiss: (Int?) -> Void

    @State private var progressValue: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            Text("Time logged")
                .font(AppFont.display(20))
                .foregroundStyle(Color.filumaText)
                .padding(.top, 28)
            Text("\(CountdownFormatter.effortString(minutes: workedMinutes)) on \u{201C}\(task.title)\u{201D}")
                .font(AppFont.body(14))
                .foregroundStyle(Color.filumaSubtle)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Text("How much of this task is done overall?")
                    .font(AppFont.body(13))
                    .foregroundStyle(Color.filumaSubtle)
                Text("\(Int(progressValue))%")
                    .font(AppFont.display(32))
                    .foregroundStyle(task.context.color)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                Slider(value: $progressValue, in: sliderRange, step: 5)
                    .tint(task.context.color)
                    .frame(minHeight: 44)
            }
            .padding(.top, 6)

            Button {
                let reported = Int(progressValue)
                onDismiss(reported)
            } label: {
                Text("Save Progress")
                    .primaryButtonStyle(fill: task.context.color)
            }

            Button {
                onDismiss(nil)
            } label: {
                Text("Skip")
                    .font(AppFont.caption(14))
                    .foregroundStyle(Color.filumaSubtle)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.filumaBackground)
        .presentationDetents([.fraction(0.5)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(FilumaRadius.sheet)
        .onAppear {
            progressValue = Double(task.progressPercent)
        }
    }

    private var sliderRange: ClosedRange<Double> {
        let minimum = Double(min(task.progressPercent, 95))
        return minimum...100
    }
}
