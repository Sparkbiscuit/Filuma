import SwiftUI
import SwiftData

/// Manage recurring windows the scheduler must leave alone.
struct BlockedTimeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \BlockedTime.startHour) private var blockedTimes: [BlockedTime]
    @State private var showingAdd = false
    @State private var operationIssue: String?

    var body: some View {
        Group {
            if blockedTimes.isEmpty {
                ScrollView {
                    EmptyStateView(
                        icon: "lock",
                        title: "No blocked times",
                        subtitle: "Add classes, meetings, or commutes so Filuma schedules around them.",
                        actionLabel: "Add blocked time",
                        action: { showingAdd = true },
                        actionIdentifier: "blockedTime.add"
                    )
                    .padding(.top, 60)
                    // The custom navigation dock overlays the root content.
                    // Leave enough scrollable runway for the first action to
                    // become fully reachable at the largest text size.
                    .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 180 : 120)
                }
                .hearthScreen(topGlow: 0.18, bottomGlow: 0.24)
            } else {
                List {
                    Section {
                        ForEach(blockedTimes) { blocked in
                            BlockedTimeRow(blocked: blocked)
                                .listRowBackground(Color.filumaSurface)
                        }
                        .onDelete(perform: delete)
                    } header: {
                        Text("Recurring")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.filumaSubtle)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.filumaBackground)
            }
        }
        .navigationTitle("Blocked Times")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !blockedTimes.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Color.brand500)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add blocked time")
                    .accessibilityIdentifier("blockedTime.add")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddBlockedTimeSheet()
                // Presentations can be hosted outside the root test/accessibility
                // environment. Keep the editor's detent and control layout in
                // lockstep with the invoking Settings screen.
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .alert(
            "Blocked time not changed",
            isPresented: Binding(
                get: { operationIssue != nil },
                set: { if !$0 { operationIssue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                operationIssue = nil
            }
        } message: {
            Text(operationIssue ?? "")
        }
    }

    private func delete(at offsets: IndexSet) {
        // Each delete is durably saved and can refresh the @Query immediately.
        // Resolve the user's original selection before the first mutation so
        // later offsets cannot drift onto a different row.
        let selectedBlockedTimes = offsets.compactMap { index in
            blockedTimes.indices.contains(index) ? blockedTimes[index] : nil
        }

        for blockedTime in selectedBlockedTimes {
            do {
                try PlanCoordinator.deleteBlockedTime(
                    blockedTime,
                    context: modelContext
                )
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                operationIssue = "Filuma couldn’t remove that blocked time yet. It is still protecting your plan—try again."
                return
            }
        }
    }
}

/// Move any already-scheduled work out of the way of the current blocked times
/// and imported calendar events.
@MainActor
@discardableResult
func replanAfterBusyChange(context: ModelContext) -> Bool {
    do {
        try PlanCoordinator.replanBusyTimeConflicts(context: context)
        return true
    } catch {
        // The coordinator rolls its planning mutation back and publishes
        // nothing. Callers with their own feedback surface may react to this
        // Boolean; background integrations simply remain on the durable plan.
        return false
    }
}

// MARK: - Row

private struct BlockedTimeRow: View {
    let blocked: BlockedTime

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.filumaFaint)
                .frame(width: 4, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(blocked.label)
                    .font(AppFont.bodySemibold(14))
                    .foregroundStyle(Color.filumaText)
                HStack(spacing: 4) {
                    Text(timeRange)
                        .font(AppFont.monoMedium(11))
                        .foregroundStyle(Color.filumaSubtle)
                    Text("· \(blocked.repeatLabel)")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.workColor)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        guard let start = calendar.date(
            bySettingHour: blocked.startHour, minute: blocked.startMinute, second: 0, of: base
        ) else { return "" }
        let end = start.addingTimeInterval(TimeInterval(blocked.durationMinutes * 60))
        return "\(TimeFormatter.clock.string(from: start)) – \(TimeFormatter.clock.string(from: end))"
    }
}

// MARK: - Add sheet

private struct AddBlockedTimeSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var label = ""
    @State private var selectedWeekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var startTime = defaultStart()
    @State private var endTime = defaultEnd()
    @State private var saveIssue: String?
    @State private var initialDraft: BlockedTimeDraft?
    @State private var showDiscardConfirmation = false

    private struct BlockedTimeDraft: Equatable {
        let label: String
        let weekdays: Set<Int>
        let startTime: Date
        let endTime: Date
    }

    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1] // Mon…Sun

    private var weekdayColumnCount: Int {
        if dynamicTypeSize.isAccessibilitySize { return 2 }
        return horizontalSizeClass == .regular ? 7 : 4
    }

    private var weekdayColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 44), spacing: 8),
            count: weekdayColumnCount
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. CS 101 Lecture", text: $label)
                        .font(AppFont.bodySemibold(15))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Blocked time name")
                        .accessibilityIdentifier("blockedTime.name")
                } header: {
                    Text("Name")
                } footer: {
                    Text(
                        trimmedLabel.isEmpty
                            ? "Add a short name so you can recognize this time later."
                            : "This name appears in your recurring blocked-time list."
                    )
                    .foregroundStyle(Color.filumaSubtle)
                }

                Section {
                    LazyVGrid(columns: weekdayColumns, spacing: 8) {
                        ForEach(weekdayOrder, id: \.self) { weekday in
                            let dayName = Calendar.current.shortWeekdaySymbols[weekday - 1]
                            let isOn = selectedWeekdays.contains(weekday)
                            Button {
                                if isOn {
                                    selectedWeekdays.remove(weekday)
                                } else {
                                    selectedWeekdays.insert(weekday)
                                }
                            } label: {
                                Text(dayName)
                                    .font(AppFont.caption(11))
                                    .foregroundStyle(
                                        isOn ? Color.filumaControlInk : Color.filumaText
                                    )
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(
                                        Capsule().fill(isOn ? Color.brand100 : Color.filumaSurface2)
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(
                                                isOn ? Color.brand300.opacity(0.7) : Color.filumaBorder,
                                                lineWidth: 1
                                            )
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
                            .accessibilityAddTraits(isOn ? [.isSelected] : [])
                            .accessibilityIdentifier("blockedTime.weekday.\(weekday)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                } header: {
                    Text("Repeats on")
                } footer: {
                    if selectedWeekdays.isEmpty {
                        Text("Choose at least one day.")
                            .foregroundStyle(Color.filumaRed)
                    }
                }

                Section {
                    timePickerRow(
                        label: "Starts",
                        selection: $startTime,
                        identifier: "blockedTime.starts"
                    )
                    timePickerRow(
                        label: "Ends",
                        selection: $endTime,
                        identifier: "blockedTime.ends"
                    )
                } header: {
                    Text("Time")
                } footer: {
                    if durationMinutes <= 0 {
                        Text("End time must be after start time.")
                            .foregroundStyle(Color.filumaRed)
                    }
                }
            }
            .navigationTitle("Blocked Time")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(action: save) {
                    Label("Add blocked time", systemImage: "plus")
                        .primaryButtonStyle(enabled: isValid)
                }
                .disabled(!isValid)
                .accessibilityHint(isValid ? "Saves this time and refreshes the plan" : validationHint)
                .accessibilityIdentifier("blockedTime.save")
                .padding(.horizontal, FilumaSpacing.screen)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .background(Color.filumaBackground.opacity(0.98).ignoresSafeArea(edges: .bottom))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.filumaBorder)
                        .frame(height: 1)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: requestDismiss) {
                        Text("Cancel")
                            .foregroundStyle(Color.filumaSubtle)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
        }
        .onAppear {
            if initialDraft == nil {
                initialDraft = currentDraft
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(isDraftDirty)
        .alert(
            "Blocked time not saved yet",
            isPresented: Binding(
                get: { saveIssue != nil },
                set: { if !$0 { saveIssue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                saveIssue = nil
            }
        } message: {
            Text(saveIssue ?? "")
        }
        .alert("Discard blocked time draft?", isPresented: $showDiscardConfirmation) {
            Button("Keep Editing", role: .cancel) { }
            Button("Discard Changes", role: .destructive) { dismiss() }
        } message: {
            Text("Your blocked time has not been saved. The current plan is unchanged.")
        }
    }

    private func timePickerRow(
        label: String,
        selection: Binding<Date>,
        identifier: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            // A labeled compact DatePicker exposes only its 36-point UIKit
            // control as the semantic element. Keep the visible row label
            // native, then give the picker itself an honest 44-point host.
            DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        }
        .frame(minHeight: 44)
    }

    private var durationMinutes: Int {
        let calendar = Calendar.current
        let start = calendar.dateComponents([.hour, .minute], from: startTime)
        let end = calendar.dateComponents([.hour, .minute], from: endTime)
        let startTotal = (start.hour ?? 0) * 60 + (start.minute ?? 0)
        let endTotal = (end.hour ?? 0) * 60 + (end.minute ?? 0)
        return endTotal - startTotal
    }

    private var isValid: Bool {
        !trimmedLabel.isEmpty
            && !selectedWeekdays.isEmpty
            && durationMinutes > 0
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentDraft: BlockedTimeDraft {
        BlockedTimeDraft(
            label: label,
            weekdays: selectedWeekdays,
            startTime: startTime,
            endTime: endTime
        )
    }

    private var isDraftDirty: Bool {
        guard let initialDraft else { return false }
        return currentDraft != initialDraft
    }

    private var validationHint: String {
        if trimmedLabel.isEmpty { return "Add a name before saving" }
        if selectedWeekdays.isEmpty { return "Choose at least one day before saving" }
        if durationMinutes <= 0 { return "Choose an end time after the start time" }
        return "Complete the blocked time details before saving"
    }

    private func requestDismiss() {
        if isDraftDirty {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let blocked = BlockedTime(
            label: trimmedLabel,
            weekdays: Array(selectedWeekdays).sorted(),
            startHour: components.hour ?? 9,
            startMinute: components.minute ?? 0,
            durationMinutes: durationMinutes
        )
        do {
            // The new recurring boundary and every block moved around it are
            // accepted together. A failed save keeps this complete draft open.
            try PlanCoordinator.addBlockedTime(blocked, context: modelContext)
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            saveIssue = "Filuma couldn’t save this blocked time or refresh the plan yet. Nothing was added—your draft is still here so you can try again."
        }
    }

    private static func defaultStart() -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private static func defaultEnd() -> Date {
        Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
