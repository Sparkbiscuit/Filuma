import SwiftUI
import SwiftData
import UIKit

/// Multi-row task entry, reached from Quick Capture's Bulk action. The whole
/// batch crosses one persistence boundary, so a failed save never leaves half
/// a syllabus in the plan.
struct BulkEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Called after the user has seen the durable summary and wants to return
    /// to Tasks. CaptureSheetView uses the receipt for the same app-level handoff
    /// as a single capture.
    var onFinished: ((BulkCaptureReceipt) -> Void)? = nil

    @State private var rows: [BulkRow] = [BulkRow()]
    @State private var receipt: BulkCaptureReceipt?
    @State private var issue: String?
    @State private var isSubmitting = false
    @State private var showDiscardConfirmation = false
    @State private var isDirty = false
    @State private var pendingRowFocusID: UUID?
    @FocusState private var focusedRowID: UUID?
    @AccessibilityFocusState private var accessibilityFocusedRowID: UUID?
    @AccessibilityFocusState private var issueFocused: Bool

    private var scrollAnimation: Animation? {
        reduceMotion ? nil : HearthMotion.reduced
    }

    private var validRows: [BulkRow] {
        rows.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        ZStack {
            HearthScreenBackground(
                topGlow: 0.16,
                bottomGlow: 0.26,
                embers: reduceMotion ? 0 : 8,
                emberIntensity: 0.62
            )

            VStack(spacing: 0) {
                header

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let issue {
                                issueBanner(issue)
                            }

                            if let receipt {
                                successSummary(receipt)
                            } else {
                                intro
                                rowList
                            }
                        }
                        .frame(maxWidth: FilumaLayout.onboardingContentMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, FilumaSpacing.screen)
                        .padding(.top, 4)
                        .padding(.bottom, 36)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollIndicators(.hidden)
                    .onChange(of: pendingRowFocusID) { _, targetID in
                        guard let targetID else { return }
                        focusAddedRow(targetID, using: proxy)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(
            "Discard this batch?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("The tasks in this batch have not been saved yet.")
        }
        // Once the batch is durable, the fixed Review action is the one exit so
        // the app-level Tasks handoff cannot be skipped by a sheet drag.
        .interactiveDismissDisabled(isSubmitting || receipt != nil || isDirty)
        .onChange(of: rows) { oldRows, newRows in
            guard receipt == nil, oldRows != newRows else { return }
            isDirty = true
        }
        .onAppear {
            guard !voiceOverEnabled, let firstID = rows.first?.id else { return }
            Task { @MainActor in
                await Task.yield()
                focusedRowID = firstID
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if receipt == nil {
                    Button(action: requestBack) {
                        Label("Back", systemImage: "chevron.left")
                            .font(AppFont.bodySemibold(13))
                            .foregroundStyle(Color.filumaSubtle)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .background(Color.filumaSurface2, in: Capsule())
                            .contentShape(Rectangle())
                    }
                    .bulkQuietPressStyle(pressedOpacity: 0.78)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.48 : 1)
                    .accessibilityIdentifier("bulk.back")
                }

                Spacer(minLength: 8)

                if receipt == nil {
                    Text(readyCountLabel)
                        .font(AppFont.caption(11))
                        .foregroundStyle(validRows.isEmpty ? Color.filumaFaint : Color.brand300)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 32)
                        .background(Color.brand500.opacity(0.1), in: Capsule())
                        .accessibilityIdentifier("bulk.readyCount")
                }
            }

            Text("BATCH CAPTURE")
                .font(AppFont.caption(10))
                .foregroundStyle(Color.brand300)
                .kerning(1.7)

            Text(receipt == nil ? "A handful at once" : "The threads are placed")
                .font(AppFont.title(26))
                .foregroundStyle(Color.filumaText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("bulk.title")
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: FilumaLayout.onboardingContentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var readyCountLabel: String {
        let count = validRows.count
        return count == 1 ? "1 ready" : "\(count) ready"
    }

    private func requestBack() {
        focusedRowID = nil
        guard receipt == nil else { return }
        if isDirty {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    // MARK: - Entry

    private var intro: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("From list to living plan")
                .font(AppFont.heading(17))
                .foregroundStyle(Color.filumaText)
            Text("Add the essentials. Filuma will place each task in order without double-booking the next one.")
                .font(AppFont.body(13))
                .foregroundStyle(Color.filumaSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    private var rowList: some View {
        VStack(spacing: 12) {
            ForEach($rows) { $row in
                let number = (rows.firstIndex { $0.id == row.id } ?? 0) + 1
                BulkRowCard(
                    number: number,
                    row: $row,
                    focusedRowID: $focusedRowID,
                    canRemove: rows.count > 1
                ) {
                    removeRow(row.id)
                }
                .id(row.id)
                .accessibilityFocused($accessibilityFocusedRowID, equals: row.id)
            }
        }
    }

    private func addRow() {
        let row = BulkRow()
        UISelectionFeedbackGenerator().selectionChanged()
        rows.append(row)
        pendingRowFocusID = row.id
    }

    private func removeRow(_ id: UUID) {
        guard rows.count > 1 else { return }
        let removedIndex = rows.firstIndex { $0.id == id } ?? 0
        let neighborID = rows.indices
            .filter { rows[$0].id != id }
            .min { abs($0 - removedIndex) < abs($1 - removedIndex) }
            .map { rows[$0].id }
        UISelectionFeedbackGenerator().selectionChanged()
        if focusedRowID == id { focusedRowID = nil }
        rows.removeAll { $0.id == id }
        guard voiceOverEnabled else { return }
        Task { @MainActor in
            await Task.yield()
            accessibilityFocusedRowID = neighborID
            UIAccessibility.post(notification: .announcement, argument: "Task removed.")
        }
    }

    private func focusAddedRow(
        _ id: UUID,
        using proxy: ScrollViewProxy
    ) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(scrollAnimation) {
                proxy.scrollTo(id, anchor: .center)
            }
            await Task.yield()
            if voiceOverEnabled {
                accessibilityFocusedRowID = id
                let number = (rows.firstIndex { $0.id == id } ?? 0) + 1
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Task \(number) added."
                )
            } else {
                focusedRowID = id
            }
            pendingRowFocusID = nil
        }
    }

    // MARK: - Durable commit

    private func scheduleAll() {
        guard !validRows.isEmpty, !isSubmitting else { return }
        focusedRowID = nil
        issueFocused = false
        issue = nil
        isSubmitting = true

        let drafts = validRows.map {
            BulkTaskCaptureDraft(
                title: $0.name,
                context: $0.context,
                // The control intentionally asks for a day rather than a
                // precise time. Treat that promise literally so a task picked
                // for Tuesday can use all of Tuesday.
                deadline: BulkRow.endOfDay($0.deadline),
                effortMinutes: $0.effortMinutes
            )
        }

        do {
            let receipt = try CaptureCoordinator.commitBulk(
                drafts,
                context: modelContext
            )
            isSubmitting = false
            isDirty = false
            self.receipt = receipt
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(
                notification: .announcement,
                argument: bulkAnnouncement(receipt)
            )
        } catch {
            isSubmitting = false
            let message = "Filuma couldn't save this batch yet. Every row is still here—try again."
            issue = message
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            Task { @MainActor in
                await Task.yield()
                issueFocused = true
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }

    private func bulkAnnouncement(_ receipt: BulkCaptureReceipt) -> String {
        let saved = taskCountPhrase(receipt.taskReceipts.count)
        if receipt.needsAttentionCount == 0 {
            return "\(saved) added to your plan."
        }
        let attention = taskCountPhrase(receipt.needsAttentionCount)
        let verb = receipt.needsAttentionCount == 1 ? "needs" : "need"
        return "\(saved) saved. \(attention) still \(verb) time."
    }

    private func taskCountPhrase(_ count: Int) -> String {
        count == 1 ? "1 task" : "\(count) tasks"
    }

    private func completeBulk() {
        guard let receipt else { return }
        if let onFinished {
            onFinished(receipt)
        } else {
            dismiss()
        }
    }

    // MARK: - Summary

    private func successSummary(_ receipt: BulkCaptureReceipt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: summarySymbol(receipt))
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(
                        receipt.needsAttentionCount == 0
                            ? Color.brand300
                            : Color.workDisplay
                    )
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(summaryTitle(receipt))
                        .font(AppFont.heading(21))
                        .foregroundStyle(Color.filumaText)
                    Text(summaryMessage(receipt))
                        .font(AppFont.body(13))
                        .foregroundStyle(Color.filumaSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)

            Divider()
                .overlay(Color.filumaBorder)

            ForEach(Array(receipt.taskReceipts.enumerated()), id: \.element.id) { index, task in
                if index > 0 {
                    Divider()
                        .overlay(Color.filumaBorder)
                        .padding(.leading, 56)
                }
                receiptRow(task)
            }
        }
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.group, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.group, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        }
        .accessibilityIdentifier("bulk.success")
    }

    private func summarySymbol(_ receipt: BulkCaptureReceipt) -> String {
        receipt.needsAttentionCount == 0
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
    }

    private func summaryTitle(_ receipt: BulkCaptureReceipt) -> String {
        receipt.taskReceipts.count == 1
            ? "One thread joined the plan"
            : "\(receipt.taskReceipts.count) threads joined the plan"
    }

    private func summaryMessage(_ receipt: BulkCaptureReceipt) -> String {
        guard receipt.needsAttentionCount > 0 else {
            return "Every task has time reserved before its deadline."
        }
        let noun = receipt.needsAttentionCount == 1 ? "task needs" : "tasks need"
        return "\(receipt.fullyScheduledCount) fully scheduled. \(receipt.needsAttentionCount) \(noun) a little more room, and stay visible in Tasks."
    }

    private func receiptRow(_ receipt: TaskCaptureReceipt) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: receipt.unscheduledMinutes == 0
                    ? "checkmark.circle"
                    : "clock.badge.exclamationmark"
            )
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    receipt.unscheduledMinutes == 0
                        ? Color.brand300
                        : Color.workDisplay
                )
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(receipt.title)
                    .font(AppFont.bodySemibold(14))
                    .foregroundStyle(Color.filumaText)
                    .fixedSize(horizontal: false, vertical: true)

                receiptDetails(receipt)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(receipt.title), \(receipt.context.rawValue), \(receiptTiming(receipt))"
        )
    }

    @ViewBuilder
    private func receiptDetails(_ receipt: TaskCaptureReceipt) -> some View {
        let context = Label(receipt.context.rawValue, systemImage: receipt.context.icon)
            .contextTag(receipt.context)
        let timing = Text(receiptTiming(receipt))
            .font(AppFont.body(12))
            .foregroundStyle(
                receipt.unscheduledMinutes > 0
                    ? Color.workDisplay
                    : Color.filumaSubtle
            )
            .fixedSize(horizontal: false, vertical: true)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                context
                timing
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                context
                timing
            }
        }
    }

    private func receiptTiming(_ receipt: TaskCaptureReceipt) -> String {
        if let firstBlockStart = receipt.firstBlockStart {
            let start = firstBlockStart.formatted(date: .abbreviated, time: .shortened)
            if receipt.unscheduledMinutes == 0 {
                return "Starts \(start) · \(CountdownFormatter.effortString(minutes: receipt.scheduledMinutes)) reserved"
            }
            return "Starts \(start) · \(CountdownFormatter.effortString(minutes: receipt.unscheduledMinutes)) still to place"
        }
        return "Saved · \(CountdownFormatter.effortString(minutes: receipt.unscheduledMinutes)) still to place"
    }

    private func issueBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.filumaRed)
                .accessibilityHidden(true)
            Text(message)
                .font(AppFont.body(13))
                .foregroundStyle(Color.filumaText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.filumaRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                .stroke(Color.filumaRed.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityFocused($issueFocused)
        .accessibilityIdentifier("bulk.issue")
    }

    // MARK: - Fixed action boundary

    @ViewBuilder
    private var actionBar: some View {
        if let receipt {
            VStack(spacing: 0) {
                Button(action: completeBulk) {
                    Label("Review in Tasks", systemImage: "arrow.right")
                        .primaryButtonStyle(enabled: true)
                }
                .bulkQuietPressStyle(pressedOpacity: 0.88)
                .accessibilityLabel(
                    "Review \(taskCountPhrase(receipt.taskReceipts.count))"
                )
                .accessibilityIdentifier("bulk.finish")
                .bulkActionBarChrome()
            }
        } else {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        scheduleButton
                        addRowButton
                    }
                } else {
                    HStack(spacing: 10) {
                        addRowButton
                        scheduleButton
                    }
                }
            }
            .bulkActionBarChrome()
        }
    }

    private var addRowButton: some View {
        Button(action: addRow) {
            Label("Add another", systemImage: "plus")
                .font(AppFont.bodySemibold(13))
                .foregroundStyle(Color.brand300)
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    minHeight: 50
                )
                .padding(.horizontal, 14)
                .background(Color.brand500.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.button, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FilumaRadius.button, style: .continuous)
                        .stroke(Color.brand500.opacity(0.3), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .bulkQuietPressStyle(pressedOpacity: 0.84)
        .disabled(isSubmitting)
        .accessibilityIdentifier("bulk.addRow")
    }

    private var scheduleButton: some View {
        Button(action: scheduleAll) {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                        .tint(Color.filumaBackground)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 15, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(scheduleActionTitle)
                    .lineLimit(1)
            }
            .primaryButtonStyle(enabled: !validRows.isEmpty && !isSubmitting)
        }
        .disabled(validRows.isEmpty || isSubmitting)
        .bulkQuietPressStyle(pressedOpacity: 0.88)
        .accessibilityIdentifier("bulk.scheduleAll")
    }

    private var scheduleActionTitle: String {
        if isSubmitting { return "Saving…" }
        let count = validRows.count
        if count == 0 { return "Schedule tasks" }
        return count == 1 ? "Schedule 1 task" : "Schedule \(count) tasks"
    }
}

// MARK: - Row data

struct BulkRow: Identifiable, Equatable {
    let id = UUID()
    var name: String = ""
    var deadline: Date = Self.defaultDeadline()
    var effortMinutes: Int = 60
    var context: TaskContext = .school

    static func defaultDeadline(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let proposed = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return endOfDay(proposed)
    }

    static func endOfDay(_ date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) else {
            return date
        }
        return calendar.date(byAdding: .second, value: -1, to: tomorrow) ?? date
    }
}

// MARK: - Row card

private struct BulkRowCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var row: BulkRow
    let number: Int
    let focusedRowID: FocusState<UUID?>.Binding
    let canRemove: Bool
    let onDelete: () -> Void

    private let effortOptions = [30, 60, 120, 180]

    init(
        number: Int,
        row: Binding<BulkRow>,
        focusedRowID: FocusState<UUID?>.Binding,
        canRemove: Bool,
        onDelete: @escaping () -> Void
    ) {
        self.number = number
        _row = row
        self.focusedRowID = focusedRowID
        self.canRemove = canRemove
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("TASK \(number)")
                    .font(AppFont.caption(10))
                    .foregroundStyle(Color.filumaFaint)
                    .kerning(1.2)

                Spacer(minLength: 8)

                if canRemove {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.filumaFaint)
                            .frame(width: 44, height: 44)
                            .background(Color.filumaSurface3, in: Circle())
                            .contentShape(Circle())
                    }
                    .bulkQuietPressStyle(pressedOpacity: 0.72)
                    .accessibilityLabel("Remove task \(number)")
                    .accessibilityIdentifier("bulk.row.\(number).remove")
                }
            }

            TextField("What needs to get done?", text: $row.name)
                .font(AppFont.heading(17))
                .foregroundStyle(Color.filumaText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .focused(focusedRowID, equals: row.id)
                .submitLabel(.done)
                .onSubmit {
                    focusedRowID.wrappedValue = nil
                }
                .accessibilityLabel("Task \(number) name")
                .accessibilityIdentifier("bulk.row.\(number).title")

            Divider().overlay(Color.filumaBorder)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        contextMenu
                        effortMenu
                        deadlinePicker
                    }
                } else {
                    HStack(spacing: 8) {
                        contextMenu
                        effortMenu
                        Spacer(minLength: 4)
                        deadlinePicker
                    }
                }
            }
        }
        .padding(16)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        }
    }

    private var contextMenu: some View {
        Menu {
            ForEach(TaskContext.allCases) { context in
                Button {
                    row.context = context
                } label: {
                    Label(context.rawValue, systemImage: context.icon)
                }
            }
        } label: {
            Label(row.context.rawValue, systemImage: row.context.icon)
                .font(AppFont.caption(11))
                .foregroundStyle(row.context.displayColor)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    minHeight: 44,
                    alignment: .leading
                )
                .background(row.context.color.opacity(0.1), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(row.context.color.opacity(0.18), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Task \(number) context, \(row.context.rawValue)")
        .accessibilityIdentifier("bulk.row.\(number).context")
    }

    private var effortMenu: some View {
        Menu {
            ForEach(effortOptions, id: \.self) { minutes in
                Button(CountdownFormatter.effortString(minutes: minutes)) {
                    row.effortMinutes = minutes
                }
            }
        } label: {
            Label(
                CountdownFormatter.effortString(minutes: row.effortMinutes),
                systemImage: "hourglass"
            )
            .font(AppFont.monoMedium(11))
            .foregroundStyle(Color.filumaText)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(
                maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                minHeight: 44,
                alignment: .leading
            )
            .background(Color.filumaSurface3, in: Capsule())
            .contentShape(Rectangle())
        }
        .accessibilityLabel(
            "Task \(number) effort, \(CountdownFormatter.effortString(minutes: row.effortMinutes))"
        )
        .accessibilityIdentifier("bulk.row.\(number).effort")
    }

    private var deadlinePicker: some View {
        DatePicker(
            "",
            selection: $row.deadline,
            in: Date()...,
            displayedComponents: [.date]
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .tint(Color.brand500)
        .frame(
            maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
            minHeight: 44,
            alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center
        )
        .contentShape(Rectangle())
        .accessibilityLabel("Task \(number) deadline, end of day")
        .accessibilityHint("Filuma may schedule this task through the end of the selected day.")
        .accessibilityIdentifier("bulk.row.\(number).deadline")
    }
}

private extension View {
    func bulkQuietPressStyle(pressedOpacity: Double) -> some View {
        buttonStyle(BulkQuietPressButtonStyle(pressedOpacity: pressedOpacity))
    }

    func bulkActionBarChrome() -> some View {
        self
            .padding(.horizontal, FilumaSpacing.screen)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: FilumaLayout.onboardingContentMaxWidth)
            .frame(maxWidth: .infinity)
            .background(Color.filumaBackground.opacity(0.98).ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.filumaBorder)
                    .frame(height: 1)
            }
    }
}

private struct BulkQuietPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let pressedOpacity: Double

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(
                configuration.isPressed || reduceMotion ? nil : HearthMotion.reduced,
                value: configuration.isPressed
            )
    }
}
