import SwiftUI
import SwiftData

struct TaskRowView: View {
    private enum RetryableOperation {
        case delete
        case reschedule
        case stopRepeating
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let task: FilumaTask
    var onStartSession: () -> Void = {}
    var onComplete: () -> Void = {}
    var onEdit: () -> Void = {}

    @State private var confirmDelete = false
    @State private var operationIssue: String?
    @State private var retryableOperation: RetryableOperation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summarySection
            actionRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                onComplete()
            } label: {
                Label("Mark Complete", systemImage: "checkmark.circle")
            }
            Button {
                rescheduleTask()
            } label: {
                Label("Reschedule", systemImage: "arrow.clockwise")
            }
            if task.templateId != nil {
                Button {
                    stopRepeating()
                } label: {
                    Label("Stop Repeating", systemImage: "repeat.circle")
                }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteTask()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(task.title)\" and its scheduled blocks go away for good. This can't be undone.")
        }
        .alert(
            "Task not changed",
            isPresented: Binding(
                get: { operationIssue != nil },
                set: { if !$0 { operationIssue = nil } }
            )
        ) {
            if retryableOperation != nil {
                Button("Try Again") {
                    retryLastOperation()
                }
            }
            Button("OK", role: .cancel) {
                operationIssue = nil
                retryableOperation = nil
            }
        } message: {
            Text(operationIssue ?? "")
        }
    }

    // MARK: - Summary (title, deadline, next block, progress)

    /// Everything that just describes the task, read as one VoiceOver stop
    /// with the row's own edit action — the interactive Start/Complete
    /// controls below stay individually reachable instead of being folded in.
    private var summarySection: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 10) {
                // Top row: title + deadline pressure
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(AppFont.cardTitle(16))
                            .foregroundStyle(Color.filumaText)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)

                        HStack(spacing: 5) {
                            // Pace dot: how much of the free time left this task
                            // would eat — the early warning, days before red.
                            if let pace = PaceCache.entry(for: task.id, context: modelContext) {
                                Circle()
                                    .fill(paceColor(pace.level))
                                    .frame(width: 7, height: 7)
                                    .accessibilityHidden(true)
                            }
                            Text(CountdownFormatter.deadlineString(from: Date(), to: task.deadline))
                                .font(AppFont.caption(12))
                                .foregroundStyle(deadlineColor)
                            if task.templateId != nil {
                                Image(systemName: "repeat")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.filumaFaint)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                // Middle row: next block info or warning
                if let nextBlock = task.nextBlock {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(task.context.color)
                            .accessibilityHidden(true)
                        Text("Starts \(CountdownFormatter.string(from: Date(), to: nextBlock.startTime))")
                            .font(AppFont.body(12))
                            .foregroundStyle(Color.filumaSubtle)
                        Text("·")
                            .foregroundStyle(Color.filumaSubtle)
                        Text(CountdownFormatter.effortString(minutes: nextBlock.durationMinutes))
                            .font(AppFont.monoMedium(11))
                            .foregroundStyle(Color.filumaSubtle)
                    }
                } else if !task.isFullyScheduled && task.remainingMinutes > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.filumaRed)
                            .accessibilityHidden(true)
                        Text("Not blocked")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.filumaRed)
                        Text("·")
                            .foregroundStyle(Color.filumaSubtle)
                        Text("\(CountdownFormatter.effortString(minutes: task.remainingMinutes)) remaining")
                            .font(AppFont.body(12))
                            .foregroundStyle(Color.filumaSubtle)
                    }
                }

                // Progress bar + percent
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.filumaSurface3)
                            .frame(maxWidth: .infinity)
                            .frame(height: 4)
                        Capsule()
                            .fill(task.context.color)
                            .frame(maxWidth: .infinity)
                            .frame(height: 4)
                            .scaleEffect(x: task.progressFraction, anchor: .leading)
                            .animation(
                                reduceMotion ? nil : HearthMotion.selection,
                                value: task.progressFraction
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 4)
                    .accessibilityHidden(true)

                    Text("\(task.progressPercent)%")
                        .font(AppFont.monoMedium(11))
                        .foregroundStyle(task.context.color)
                        .frame(
                            width: dynamicTypeSize.isAccessibilitySize ? nil : 36,
                            alignment: .trailing
                        )
                        .fixedSize(
                            horizontal: dynamicTypeSize.isAccessibilitySize,
                            vertical: false
                        )
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Plain buttons otherwise inherit hit testing from only the
            // label's painted descendants. Claim the whole visible summary,
            // including the breathing room between metadata and progress.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pin the native Button host itself, not only its label. This keeps
        // XCUI/VoiceOver activation inside the visible summary when the row
        // grows or the surrounding disclosure animates.
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(summaryAccessibilityLabel)
        .accessibilityHint("Opens task details")
        .accessibilityIdentifier("task.summary")
    }

    // MARK: - Actions (time spent, start, complete)

    @ViewBuilder
    private var actionRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                timeSpentLabel
                startButton
                completeButton
            }
        } else {
            HStack(spacing: 10) {
                timeSpentLabel
                Spacer()
                startButton
                completeButton
            }
        }
    }

    private var timeSpentLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "stopwatch")
                .font(.system(size: 10))
            Text(CountdownFormatter.effortString(minutes: task.timeSpentMinutes))
            Text("/")
            Text(CountdownFormatter.effortString(minutes: task.effortMinutes))
            if task.isOverBudget {
                Text("over")
                    .font(AppFont.caption(10))
                    .foregroundStyle(Color.workColor)
            }
        }
        .font(AppFont.monoMedium(11))
        .foregroundStyle(Color.filumaSubtle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(timeSpentAccessibilityLabel)
    }

    private var startButton: some View {
        Button(action: onStartSession) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text(dynamicTypeSize.isAccessibilitySize ? "Start session" : "Start")
                    .font(AppFont.caption(12))
            }
            .foregroundStyle(task.context.color)
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 14 : 10)
            .frame(
                minWidth: 44,
                maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                minHeight: 44
            )
            .background(task.context.color.opacity(0.13), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hearthPressStyle(scale: 0.94, pressedOpacity: 0.8)
        .accessibilityLabel("Start work session for \(task.title)")
        .accessibilityIdentifier("task.start")
    }

    private var completeButton: some View {
        Button(action: onComplete) {
            if dynamicTypeSize.isAccessibilitySize {
                Label("Complete", systemImage: "circle")
                    .font(AppFont.caption(12))
                    .foregroundStyle(Color.filumaText)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.filumaSurface2, in: Capsule())
                    .overlay(Capsule().stroke(Color.filumaBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.filumaFaint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .hearthPressStyle(scale: 0.86, pressedOpacity: 0.72)
        .accessibilityLabel("Mark \(task.title) complete")
        .accessibilityIdentifier("task.complete")
    }

    private var timeSpentAccessibilityLabel: String {
        let spent = CountdownFormatter.effortString(minutes: task.timeSpentMinutes)
        let budget = CountdownFormatter.effortString(minutes: task.effortMinutes)
        return task.isOverBudget
            ? "\(spent) of \(budget) worked, over budget"
            : "\(spent) of \(budget) worked"
    }

    private var summaryAccessibilityLabel: String {
        var parts = [
            task.title,
            task.context.rawValue,
            CountdownFormatter.deadlineString(from: Date(), to: task.deadline)
        ]
        if let pace = PaceCache.entry(for: task.id, context: modelContext) {
            parts.append("\(paceAccessibilityLabel(pace.level)) pace")
        }
        if let nextBlock = task.nextBlock {
            let start = CountdownFormatter.string(from: Date(), to: nextBlock.startTime)
            let duration = CountdownFormatter.effortString(minutes: nextBlock.durationMinutes)
            parts.append("Starts \(start) for \(duration)")
        } else if !task.isFullyScheduled && task.remainingMinutes > 0 {
            let remaining = CountdownFormatter.effortString(minutes: task.remainingMinutes)
            parts.append("Not blocked, \(remaining) remaining")
        }
        parts.append("\(task.progressPercent) percent complete")
        return parts.joined(separator: ", ")
    }

    private func paceAccessibilityLabel(_ level: PaceLevel) -> String {
        switch level {
        case .comfortable: return "Comfortable"
        case .tightening: return "Tightening"
        case .critical: return "Critical"
        }
    }

    private var deadlineColor: Color {
        let hours = task.deadline.timeIntervalSince(Date()) / 3600
        if hours < 24 { return .filumaRed }
        if hours < 72 { return .workDisplay }
        return .filumaSubtle
    }

    private func paceColor(_ level: PaceLevel) -> Color {
        switch level {
        case .comfortable: return .personalColor
        case .tightening: return .workColor
        case .critical: return .filumaRed
        }
    }

    /// End the recurrence this task came from. Existing occurrences stay;
    /// no new copies get stamped out.
    private func stopRepeating() {
        guard let templateId = task.templateId else { return }
        do {
            try PlanCoordinator.stopRepeating(
                templateID: templateId,
                context: modelContext
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            retryableOperation = .stopRepeating
            operationIssue = "Filuma couldn’t stop this recurrence yet. Nothing changed—try again."
        }
    }

    private func rescheduleTask() {
        do {
            try PlanCoordinator.rescheduleTask(task, context: modelContext)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            retryableOperation = .reschedule
            operationIssue = "Filuma couldn’t rebuild this task’s plan yet. Its current schedule is unchanged—try again."
        }
    }

    private func deleteTask() {
        do {
            try PlanCoordinator.deleteTask(task, context: modelContext)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            retryableOperation = .delete
            operationIssue = "Filuma couldn’t remove this task yet. It is still safely in your plan—try again."
        }
    }

    private func retryLastOperation() {
        let operation = retryableOperation
        operationIssue = nil
        retryableOperation = nil

        switch operation {
        case .delete:
            deleteTask()
        case .reschedule:
            rescheduleTask()
        case .stopRepeating:
            stopRepeating()
        case nil:
            break
        }
    }
}
