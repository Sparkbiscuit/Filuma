import SwiftUI
import SwiftData
import EventKit
import UIKit

struct SettingsView: View {
    private enum CalendarSettingRetry: Equatable {
        case setAppleExport(Bool)
        case reconcileAppleExport(Bool)
    }

    private enum GoogleSyncOperation: Equatable {
        case importBusyTimes
        case exportBlocks

        var retryLabel: String {
            switch self {
            case .importBusyTimes: "Retry Google import"
            case .exportBlocks: "Retry Google export"
            }
        }

        var failureAnnouncement: String {
            switch self {
            case .importBusyTimes:
                "Google Calendar couldn't refresh busy times. Your preference is still on; retry when you're ready."
            case .exportBlocks:
                "Google Calendar couldn't refresh exported blocks. Your preference is still on; retry when you're ready."
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var settingsArray: [UserSettings]
    @State private var showCalendarDeniedAlert = false
    @State private var showNotificationsDeniedAlert = false
    @State private var didPushNow = false
    @State private var showPushNowError = false
    @State private var exportFileURL: URL?
    @State private var isConnectingGoogle = false
    @State private var showGoogleConnectFailed = false
    @State private var showExportFailed = false
    @State private var googleSyncIssue: GoogleSyncOperation?
    @State private var googleSyncInFlight: GoogleSyncOperation?
    @State private var googleSyncRequestID: UUID?
    @State private var googleSyncTask: Task<Void, Never>?
    @State private var confirmGoogleDisconnect = false
    @State private var planningPreferencesDirty = false
    @State private var planningRebuildTask: Task<Void, Never>?
    @State private var showPlanningRefreshFailed = false
    @State private var calendarSettingIssue: String?
    @State private var calendarSettingRetry: CalendarSettingRetry?
    @State private var notificationSettingIssue: BlockNotificationService.PreferenceUpdate?
    @State private var appleExportRequestID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if let settings = settingsArray.first {
                    settingsList(settings)
                } else {
                    // MainTabView creates the row on appear; this is a one-frame fallback.
                    ProgressView()
                        .onAppear { _ = UserSettings.fetchOrCreate(in: modelContext) }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onDisappear(perform: flushPlanningRebuild)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase == .active, newPhase != .active else { return }
            flushPlanningRebuild()
        }
    }

    private func settingsList(_ settings: UserSettings) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsHeader

                hearthSection
                dailyScheduleSection(settings)
                planningSection(settings)
                nudgeSection(settings)
                calendarSection(settings)
                googleCalendarSection(settings)
                aboutSection

                Text("Filuma \(appVersion) · woven with care")
                    .font(AppFont.monoMedium(11))
                    .foregroundStyle(Color.filumaFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(.bottom, 110)
            .frame(maxWidth: FilumaLayout.readableContentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .hearthScreen(topGlow: 0.18, bottomGlow: 0.24)
        .alert("Calendar access needed", isPresented: $showCalendarDeniedAlert) {
            Button("Open System Settings", action: openSystemSettings)
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Enable calendar access so Filuma can schedule around your events and, if you choose, export work blocks.")
        }
        .alert("Notifications are off", isPresented: $showNotificationsDeniedAlert) {
            Button("Open System Settings", action: openSystemSettings)
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Enable notifications for Filuma in Settings to get block start nudges.")
        }
        .alert("Couldn't connect Google", isPresented: $showGoogleConnectFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong signing in to Google. Check your connection and try again.")
        }
        .alert("Couldn't create the export", isPresented: $showExportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your data is still safe in Filuma. Try Export my data again in a moment.")
        }
        .alert("Plan not refreshed yet", isPresented: $showPlanningRefreshFailed) {
            Button("Retry") {
                performPlanningRebuild()
            }
            Button("Not now", role: .cancel) { }
        } message: {
            Text("Your preference is still here, but Filuma couldn’t safely rebuild the plan yet. The existing schedule is unchanged; retry when you’re ready.")
        }
        .alert(
            "Calendar needs attention",
            isPresented: Binding(
                get: { calendarSettingIssue != nil },
                set: {
                    if !$0 {
                        calendarSettingIssue = nil
                        calendarSettingRetry = nil
                    }
                }
            )
        ) {
            if let retry = calendarSettingRetry {
                Button("Retry") {
                    calendarSettingIssue = nil
                    calendarSettingRetry = nil
                    Task { @MainActor in
                        await Task.yield()
                        retryCalendarSetting(retry, settings: settings)
                    }
                }
            }
            Button("Not now", role: .cancel) {
                calendarSettingIssue = nil
                calendarSettingRetry = nil
            }
        } message: {
            Text(calendarSettingIssue ?? "")
        }
        .alert(
            "Notification setting not changed",
            isPresented: Binding(
                get: { notificationSettingIssue != nil },
                set: { if !$0 { notificationSettingIssue = nil } }
            )
        ) {
            if let update = notificationSettingIssue {
                Button("Retry") {
                    notificationSettingIssue = nil
                    Task { @MainActor in
                        await Task.yield()
                        setNotificationPreference(update, settings: settings)
                    }
                }
            }
            Button("Not now", role: .cancel) {
                notificationSettingIssue = nil
            }
        } message: {
            Text(notificationSettingIssue?.failureMessage ?? "")
        }
    }

    // MARK: - Hearth (accent hue)

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Your space")
                .font(AppFont.heading(12))
                .foregroundStyle(Color.brand300)

            HearthTitle(text: "Settings", size: 28)
                .accessibilityAddTraits(.isHeader)

            Text("Shape the plan around the way your days actually work.")
                .font(AppFont.body(13))
                .foregroundStyle(Color.filumaSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    /// The hearth itself: which color the flame burns. Every glow, ring,
    /// ember, and gradient in the app follows this choice live.
    private var hearthSection: some View {
        HearthAccentPanel(selectedAccent: HearthTheme.shared.accent) { accent in
            guard HearthTheme.shared.accent != accent else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
                HearthTheme.shared.accent = accent
            }
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(accent.displayName) hearth selected."
            )
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.bottom, 22)
    }

    // MARK: - Daily Schedule

    private func dailyScheduleSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Daily Schedule",
            footer: "Tasks are scheduled between these hours. A sleep time past midnight is fine; Filuma treats it as the next day."
        ) {
            SettingsRow(icon: "sunrise.fill", tint: .workDisplay, label: "Wake time") {
                timePicker(
                    hour: planningPreferenceBinding(
                        settings: settings,
                        get: { settings.wakeHour },
                        set: { settings.wakeHour = $0 }
                    ),
                    minute: planningPreferenceBinding(
                        settings: settings,
                        get: { settings.wakeMinute },
                        set: { settings.wakeMinute = $0 }
                    )
                )
                .accessibilityLabel("Wake time")
            }
            SettingsRow(icon: "moon.fill", tint: .schoolDisplay, label: "Sleep time") {
                timePicker(
                    hour: planningPreferenceBinding(
                        settings: settings,
                        get: { settings.sleepHour },
                        set: { settings.sleepHour = $0 }
                    ),
                    minute: planningPreferenceBinding(
                        settings: settings,
                        get: { settings.sleepMinute },
                        set: { settings.sleepMinute = $0 }
                    )
                )
                .accessibilityLabel("Sleep time")
            }
        }
    }

    private func timePicker(hour: Binding<Int>, minute: Binding<Int>) -> some View {
        let date = Binding<Date>(
            get: {
                var components = DateComponents()
                components.hour = hour.wrappedValue
                components.minute = minute.wrappedValue
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                hour.wrappedValue = comps.hour ?? 8
                minute.wrappedValue = comps.minute ?? 0
            }
        )

        return DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    // MARK: - Planning

    private func planningSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Planning",
            footer: "Tasks are split into blocks within the size range. The focus limit caps how much work lands on any single day; buffers keep plans honest around deadlines and fresh starts."
        ) {
            stepperRow(
                icon: "gauge.with.needle", tint: .brand300, label: "Daily focus limit",
                value: planningPreferenceBinding(
                    settings: settings,
                    get: { settings.dailyFocusMinutes },
                    set: { settings.dailyFocusMinutes = $0 }
                ),
                range: 0...720, step: 30,
                display: settings.dailyFocusMinutes == 0
                    ? "Off"
                    : CountdownFormatter.effortString(minutes: settings.dailyFocusMinutes)
            )
            stepperRow(
                icon: "rectangle.compress.vertical", tint: .schoolDisplay, label: "Minimum block",
                value: planningPreferenceBinding(
                    settings: settings,
                    get: { settings.minBlockMinutes },
                    set: { settings.minBlockMinutes = $0 }
                ),
                range: 15...60, step: 15,
                display: CountdownFormatter.effortString(minutes: settings.minBlockMinutes)
            )
            stepperRow(
                icon: "rectangle.expand.vertical", tint: .schoolDisplay, label: "Maximum block",
                value: planningPreferenceBinding(
                    settings: settings,
                    get: { settings.maxBlockMinutes },
                    set: { settings.maxBlockMinutes = $0 }
                ),
                range: 60...180, step: 30,
                display: CountdownFormatter.effortString(minutes: settings.maxBlockMinutes)
            )
            stepperRow(
                icon: "shield.fill", tint: .personalDisplay, label: "Deadline buffer",
                value: planningPreferenceBinding(
                    settings: settings,
                    get: { settings.deadlineBufferMinutes },
                    set: { settings.deadlineBufferMinutes = $0 }
                ),
                range: 0...480, step: 30,
                display: CountdownFormatter.effortString(minutes: settings.deadlineBufferMinutes)
            )
            stepperRow(
                icon: "hourglass.bottomhalf.filled", tint: .personalDisplay, label: "Start buffer",
                value: planningPreferenceBinding(
                    settings: settings,
                    get: { settings.startBufferMinutes },
                    set: { settings.startBufferMinutes = $0 }
                ),
                range: 0...60, step: 5,
                display: settings.startBufferMinutes == 0
                    ? "None"
                    : CountdownFormatter.effortString(minutes: settings.startBufferMinutes)
            )
        }
    }

    private func stepperRow(
        icon: String,
        tint: Color,
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        display: String
    ) -> some View {
        SettingsRow(icon: icon, tint: tint, label: label) {
            HStack(spacing: 10) {
                // Word values ("Off", "None") read badly in mono ("0ff");
                // only numeric values get the tabular treatment.
                Text(display)
                    .font(display.contains(where: \.isNumber) ? AppFont.mono(13) : AppFont.caption(13))
                    .foregroundStyle(Color.filumaSubtle)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(label)
                    .accessibilityValue(display)
            }
        }
    }

    /// Planning controls can emit several values while a wheel or stepper is
    /// moving. A single trailing rebuild keeps those edits responsive while
    /// still committing the final preference promptly.
    private func planningPreferenceBinding(
        settings: UserSettings,
        get: @escaping () -> Int,
        set: @escaping (Int) -> Void
    ) -> Binding<Int> {
        Binding(
            get: get,
            set: { newValue in
                guard newValue != get() else { return }
                set(newValue)
                settings.planningRebuildPending = true
                queuePlanningRebuild()
            }
        )
    }

    private func queuePlanningRebuild() {
        planningPreferencesDirty = true
        planningRebuildTask?.cancel()
        planningRebuildTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            planningRebuildTask = nil
            performPlanningRebuild()
        }
    }

    private func flushPlanningRebuild() {
        planningRebuildTask?.cancel()
        planningRebuildTask = nil
        performPlanningRebuild()
    }

    private func performPlanningRebuild() {
        guard planningPreferencesDirty else { return }
        do {
            try PlanCoordinator.rebuildAfterPlanningPreferencesChange(
                context: modelContext
            )
            planningPreferencesDirty = false
            showPlanningRefreshFailed = false
        } catch {
            // Keep the dirty bit as a durable retry intent. The coordinator
            // leaves the old plan untouched and publishes nothing.
            planningPreferencesDirty = true
            showPlanningRefreshFailed = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: - Nudges

    private func nudgeSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Nudges",
            footer: "Block nudges fire when each work block begins. The morning preview (30 minutes after wake time) lists the day's blocks; the evening wrap-up reviews what got done and shows where tomorrow starts."
        ) {
            SettingsRow(icon: "bell.badge.fill", tint: .brand300, label: "Block start nudges") {
                Toggle("Block start nudges", isOn: Binding(
                    get: { settings.blockRemindersEnabled },
                    set: { enabled in setBlockReminders(enabled, settings: settings) }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            if settings.blockRemindersEnabled {
                stepperRow(
                    icon: "clock.badge", tint: .brand300, label: "Early heads-up",
                    value: Binding(
                        get: { settings.blockReminderLeadMinutes },
                        set: { minutes in
                            setNotificationPreference(
                                .blockReminderLeadMinutes(minutes),
                                settings: settings
                            )
                        }
                    ),
                    range: 0...15, step: 5,
                    display: settings.blockReminderLeadMinutes == 0
                        ? "Off"
                        : "\(settings.blockReminderLeadMinutes) min"
                )
            }

            SettingsRow(icon: "sun.horizon.fill", tint: .workDisplay, label: "Morning preview") {
                Toggle("Morning preview", isOn: notificationToggleBinding(
                    settings: settings,
                    get: { settings.morningPreviewEnabled },
                    update: { .morningPreviewEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            SettingsRow(icon: "moon.stars.fill", tint: .schoolDisplay, label: "Evening wrap-up") {
                Toggle("Evening wrap-up", isOn: notificationToggleBinding(
                    settings: settings,
                    get: { settings.eveningReviewEnabled },
                    update: { .eveningReviewEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            if settings.eveningReviewEnabled {
                SettingsRow(icon: "clock.fill", tint: .filumaSubtle, label: "Wrap-up time") {
                    eveningReviewTimePicker(settings: settings)
                        .accessibilityLabel("Wrap-up time")
                }
            }
        }
    }

    /// A notification-backed toggle. Authorization finishes before the local
    /// mutation; the preference transaction finishes before system resync.
    private func notificationToggleBinding(
        settings: UserSettings,
        get: @escaping () -> Bool,
        update: @escaping (Bool) -> BlockNotificationService.PreferenceUpdate
    ) -> Binding<Bool> {
        Binding(
            get: get,
            set: { enabled in
                setNotificationPreference(update(enabled), settings: settings)
            }
        )
    }

    private func setBlockReminders(_ enabled: Bool, settings: UserSettings) {
        setNotificationPreference(.blockRemindersEnabled(enabled), settings: settings)
    }

    private func setNotificationPreference(
        _ update: BlockNotificationService.PreferenceUpdate,
        settings: UserSettings
    ) {
        if update.requiresAuthorization {
            Task { @MainActor in
                let granted = await NotificationService.requestAuthorization()
                if granted {
                    commitNotificationPreference(update, settings: settings)
                } else {
                    notificationSettingIssue = nil
                    showNotificationsDeniedAlert = true
                }
            }
        } else {
            commitNotificationPreference(update, settings: settings)
        }
    }

    private func commitNotificationPreference(
        _ update: BlockNotificationService.PreferenceUpdate,
        settings: UserSettings
    ) {
        do {
            try BlockNotificationService.updatePreference(
                update,
                settings: settings,
                context: modelContext
            )
            if notificationSettingIssue == update {
                notificationSettingIssue = nil
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            notificationSettingIssue = update
        }
    }

    private func eveningReviewTimePicker(settings: UserSettings) -> some View {
        let date = Binding<Date>(
            get: {
                var components = DateComponents()
                components.hour = settings.eveningReviewHour
                components.minute = settings.eveningReviewMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                setNotificationPreference(
                    .eveningReviewTime(
                        hour: components.hour ?? settings.eveningReviewHour,
                        minute: components.minute ?? settings.eveningReviewMinute
                    ),
                    settings: settings
                )
            }
        )

        return DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    // MARK: - Calendar

    private func calendarSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Calendar",
            footer: "Blocked times are recurring windows (classes, meetings, commutes) Filuma schedules around. Export mirrors your blocks into a dedicated \u{201C}Filuma\u{201D} calendar; import treats other calendars' events as busy time. They never become tasks."
        ) {
            NavigationLink {
                BlockedTimeView()
            } label: {
                SettingsRow(icon: "lock.fill", tint: .filumaSubtle, label: "Blocked Times") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.filumaFaint)
                }
            }
            .buttonStyle(.plain)

            SettingsRow(icon: "calendar.badge.clock", tint: .schoolDisplay, label: "Import busy times") {
                Toggle("Import busy times from Apple Calendar", isOn: Binding(
                    get: { settings.importFromAppleCalendar },
                    set: { enabled in setCalendarImport(enabled, settings: settings) }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            if settings.importFromAppleCalendar {
                NavigationLink {
                    CalendarPickerView(settings: settings)
                } label: {
                    SettingsRow(icon: "list.bullet", tint: .schoolDisplay, label: "Calendars") {
                        HStack(spacing: 8) {
                            Text(includedCalendarsLabel(settings))
                                .font(AppFont.mono(13))
                                .foregroundStyle(Color.filumaSubtle)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.filumaFaint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            SettingsRow(icon: "arrow.up", tint: .schoolDisplay, label: "Export blocks to Calendar") {
                Toggle("Export blocks to Apple Calendar", isOn: Binding(
                    get: { settings.exportToAppleCalendar },
                    set: { enabled in setCalendarExport(enabled, settings: settings) }
                ))
                .labelsHidden()
                .toggleStyle(HearthToggleStyle())
            }

            Button {
                pushBlocksNow(settings: settings)
            } label: {
                SettingsRow(icon: "arrow.up.circle", tint: .brand300, label: "Push blocks to Calendar now", labelTint: .brand300) {
                    if didPushNow {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.personalDisplay)
                    } else if showPushNowError {
                        Text("Couldn't reach Calendar")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.filumaRed)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func setCalendarExport(_ enabled: Bool, settings: UserSettings) {
        let requestID = UUID()
        appleExportRequestID = requestID
        calendarSettingIssue = nil
        calendarSettingRetry = nil

        if enabled {
            Task { @MainActor in
                let granted = await CalendarExportService.requestAccess()
                guard appleExportRequestID == requestID else { return }
                if granted {
                    commitCalendarExportPreference(
                        true,
                        settings: settings,
                        requestID: requestID
                    )
                } else {
                    showCalendarDeniedAlert = true
                }
            }
        } else {
            commitCalendarExportPreference(
                false,
                settings: settings,
                requestID: requestID
            )
        }
    }

    private func commitCalendarExportPreference(
        _ enabled: Bool,
        settings: UserSettings,
        requestID: UUID
    ) {
        guard appleExportRequestID == requestID else { return }
        do {
            try CalendarExportService.setExportEnabled(
                enabled,
                settings: settings,
                context: modelContext
            )
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            calendarSettingIssue = enabled
                ? "Filuma couldn’t save Apple Calendar export, so the setting stayed off. Try again."
                : "Filuma couldn’t turn Apple Calendar export off, so the setting stayed on. Try again."
            calendarSettingRetry = .setAppleExport(enabled)
            return
        }

        reconcileAppleCalendarExport(
            enabled,
            settings: settings,
            requestID: requestID
        )
    }

    private func reconcileAppleCalendarExport(
        _ enabled: Bool,
        settings: UserSettings,
        requestID: UUID
    ) {
        // Authorization and alert presentation can yield. Both the request and
        // the durable toggle must still own this operation immediately before
        // any EventKit change begins.
        guard CalendarExportService.isReconciliationCurrent(
            expectedEnabled: enabled,
            durableEnabled: settings.exportToAppleCalendar,
            requestID: requestID,
            currentRequestID: appleExportRequestID
        ) else { return }
        do {
            if enabled {
                try CalendarExportService.syncNow(context: modelContext, settings: settings)
            } else {
                try CalendarExportService.removeExportedEvents(
                    context: modelContext,
                    settings: settings
                )
            }
        } catch {
            // The preference is already durable. Never roll it back over an
            // EventKit or identifier-mirror result that cannot be rolled back
            // with it; report the exact retained state and offer reconciliation.
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            calendarSettingIssue = enabled
                ? "Apple Calendar export is on, but Filuma couldn’t finish refreshing its calendar yet. Your blocks are safe here; retry the export."
                : "Apple Calendar export is off, but Filuma couldn’t finish removing its calendar yet. Retry the cleanup when Calendar is available."
            calendarSettingRetry = .reconcileAppleExport(enabled)
        }
    }

    private func retryCalendarSetting(
        _ retry: CalendarSettingRetry,
        settings: UserSettings
    ) {
        switch retry {
        case .setAppleExport(let enabled):
            setCalendarExport(enabled, settings: settings)
        case .reconcileAppleExport(let enabled):
            let requestID = UUID()
            appleExportRequestID = requestID
            Task { @MainActor in
                let granted = await CalendarExportService.requestAccess()
                guard CalendarExportService.isReconciliationCurrent(
                    expectedEnabled: enabled,
                    durableEnabled: settings.exportToAppleCalendar,
                    requestID: requestID,
                    currentRequestID: appleExportRequestID
                ) else { return }
                if granted {
                    reconcileAppleCalendarExport(
                        enabled,
                        settings: settings,
                        requestID: requestID
                    )
                } else {
                    showCalendarDeniedAlert = true
                    calendarSettingIssue = enabled
                        ? "Apple Calendar export is on, but Calendar access is needed to finish refreshing it."
                        : "Apple Calendar export is off, but Calendar access is needed to remove Filuma’s calendar."
                    calendarSettingRetry = .reconcileAppleExport(enabled)
                }
            }
        }
    }

    private func setCalendarImport(_ enabled: Bool, settings: UserSettings) {
        if enabled {
            Task { @MainActor in
                let granted = await CalendarExportService.requestAccess()
                if granted {
                    do {
                        try CalendarImportService.enableImport(
                            settings: settings,
                            context: modelContext
                        )
                        // Scheduled work moves out of the way of the imported events.
                        if !replanAfterBusyChange(context: modelContext) {
                            calendarSettingRetry = nil
                            calendarSettingIssue = "Apple Calendar import is on and your events are safe, but Filuma couldn’t refresh the plan yet. The next foreground refresh will retry."
                        }
                    } catch {
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        calendarSettingRetry = nil
                        calendarSettingIssue = "Filuma couldn’t read the existing calendar mirror safely, so Apple Calendar import stayed off. Try again."
                    }
                } else {
                    settings.importFromAppleCalendar = false
                    showCalendarDeniedAlert = true
                }
            }
        } else {
            do {
                try CalendarImportService.disableImport(
                    settings: settings,
                    context: modelContext
                )
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                calendarSettingRetry = nil
                calendarSettingIssue = "Filuma couldn’t turn Apple Calendar import off yet, so the setting and imported busy times are unchanged. Try again."
            }
        }
    }

    private func includedCalendarsLabel(_ settings: UserSettings) -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return "" }
        let total = CalendarImportService.availableCalendars(settings: settings).count
        let excluded = Set(settings.excludedCalendarIds)
        let included = CalendarImportService.availableCalendars(settings: settings)
            .filter { !excluded.contains($0.calendarIdentifier) }
            .count
        return included == total ? "All" : "\(included) of \(total)"
    }

    private func pushBlocksNow(settings: UserSettings) {
        withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
            didPushNow = false
            showPushNowError = false
        }
        Task { @MainActor in
            let granted = await CalendarExportService.requestAccess()
            if granted {
                do {
                    try CalendarExportService.syncNow(context: modelContext, settings: settings)
                    withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
                        showPushNowError = false
                        didPushNow = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
                            didPushNow = false
                        }
                    }
                } catch {
                    withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
                        didPushNow = false
                        showPushNowError = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
                            showPushNowError = false
                        }
                    }
                }
            } else {
                showCalendarDeniedAlert = true
            }
        }
    }

    // MARK: - Google Calendar

    /// Google Calendar, treated the same as the Apple pair: one connect
    /// button, then the identical import/export toggles. Connection state
    /// lives in the Keychain; `googleAccountEmail` mirrors it for display.
    private func googleCalendarSection(_ settings: UserSettings) -> some View {
        SettingsGroup(
            title: "Google Calendar",
            footer: settings.googleAccountEmail == nil
                ? "Sign in once and Google Calendar joins the loom: its events become busy time Filuma schedules around, and export mirrors your blocks into your primary Google calendar. Events never become tasks."
                : "Import treats Google events as busy time; export mirrors your blocks into your primary Google calendar, marked so they're never re-imported."
        ) {
            if let email = settings.googleAccountEmail {
                SettingsRow(icon: "person.crop.circle.fill", tint: .personalDisplay, label: email) {
                    Button("Disconnect") {
                        confirmGoogleDisconnect = true
                    }
                    .font(AppFont.caption(13))
                    .foregroundStyle(Color.filumaRed)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Disconnect Google Calendar")
                }
                .alert("Disconnect Google Calendar?", isPresented: $confirmGoogleDisconnect) {
                    Button("Stay connected", role: .cancel) { }
                        .accessibilityIdentifier("settings.google.disconnect.cancel")
                    Button("Disconnect", role: .destructive) {
                        disconnectGoogle(settings)
                    }
                    .accessibilityIdentifier("settings.google.disconnect.confirm")
                } message: {
                    Text("Imported Google events are removed, and future scheduling stops treating them as busy. Work blocks Filuma already exported stay in Google Calendar after disconnecting.")
                }

                if settings.googleNeedsReconnect {
                    Button {
                        connectGoogle(settings)
                    } label: {
                        SettingsRow(
                            icon: "exclamationmark.arrow.circlepath",
                            tint: .filumaRed,
                            label: "Reconnect Google",
                            labelTint: .filumaRed
                        ) {
                            if isConnectingGoogle {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.filumaFaint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnectingGoogle)
                }

                SettingsRow(icon: "calendar.badge.clock", tint: .workDisplay, label: "Import busy times") {
                    Toggle("Import busy times from Google Calendar", isOn: Binding(
                        get: { settings.importFromGoogleCalendar },
                        set: { enabled in setGoogleImport(enabled, settings: settings) }
                    ))
                    .labelsHidden()
                    .toggleStyle(HearthToggleStyle())
                }

                SettingsRow(icon: "arrow.up", tint: .workDisplay, label: "Export blocks to Google") {
                    Toggle("Export blocks to Google Calendar", isOn: Binding(
                        get: { settings.exportToGoogleCalendar },
                        set: { enabled in setGoogleExport(enabled, settings: settings) }
                    ))
                    .labelsHidden()
                    .toggleStyle(HearthToggleStyle())
                }

                if let syncIssue = googleSyncIssue {
                    Button {
                        performGoogleSync(syncIssue, settings: settings)
                    } label: {
                        SettingsRow(
                            icon: "arrow.clockwise.circle.fill",
                            tint: .filumaRed,
                            label: syncIssue.retryLabel,
                            labelTint: .filumaRed
                        ) {
                            if googleSyncInFlight == syncIssue {
                                ProgressView()
                                    .tint(Color.brand300)
                            } else {
                                Text("Retry")
                                    .font(AppFont.caption(12))
                                    .foregroundStyle(Color.brand300)
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(googleSyncInFlight != nil)
                    .accessibilityLabel(syncIssue.retryLabel)
                    .accessibilityHint("Attempts this Google Calendar sync again")
                }
            } else {
                Button {
                    connectGoogle(settings)
                } label: {
                    SettingsRow(
                        icon: "link",
                        tint: .brand300,
                        label: "Connect Google Calendar",
                        labelTint: .brand300
                    ) {
                        if isConnectingGoogle {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isConnectingGoogle)
            }
        }
    }

    private func connectGoogle(_ settings: UserSettings) {
        guard !isConnectingGoogle else { return }
        isConnectingGoogle = true
        Task { @MainActor in
            defer { isConnectingGoogle = false }
            do {
                let tokens = try await GoogleOAuth.shared.connect()
                do {
                    try GoogleCalendarService.commitConnection(
                        email: tokens.email ?? "Google account",
                        settings: settings,
                        context: modelContext
                    )
                } catch {
                    // OAuth has already written these credentials. Do not
                    // leave them orphaned if the account row cannot commit.
                    GoogleOAuth.disconnect()
                    throw error
                }
                performGoogleSync(.importBusyTimes, settings: settings)
            } catch GoogleAuthError.cancelled {
                // The user backed out of the consent screen — not an error.
            } catch {
                showGoogleConnectFailed = true
            }
        }
    }

    private func disconnectGoogle(_ settings: UserSettings) {
        do {
            try GoogleCalendarService.disconnect(
                settings: settings,
                context: modelContext
            )
            googleSyncIssue = nil
            cancelGoogleSyncUI()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            calendarSettingRetry = nil
            calendarSettingIssue = "Filuma couldn’t finish disconnecting yet, so your Google account and imported busy times are unchanged. Try Disconnect again."
        }
    }

    private func setGoogleImport(_ enabled: Bool, settings: UserSettings) {
        if enabled {
            do {
                try GoogleCalendarService.enableImport(
                    settings: settings,
                    context: modelContext
                )
                performGoogleSync(.importBusyTimes, settings: settings)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                calendarSettingRetry = nil
                calendarSettingIssue = "Filuma couldn’t turn Google import on yet, so the setting stayed off. Try again."
            }
        } else {
            do {
                try GoogleCalendarService.disableImport(
                    settings: settings,
                    context: modelContext
                )
                cancelGoogleSyncUI(.importBusyTimes)
                if googleSyncIssue == .importBusyTimes { googleSyncIssue = nil }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                calendarSettingRetry = nil
                calendarSettingIssue = "Filuma couldn’t turn Google import off yet, so the setting and imported busy times are unchanged. Try again."
            }
        }
    }

    private func setGoogleExport(_ enabled: Bool, settings: UserSettings) {
        do {
            try GoogleCalendarService.setExportEnabled(
                enabled,
                settings: settings,
                context: modelContext
            )
            if enabled {
                performGoogleSync(.exportBlocks, settings: settings)
            } else {
                cancelGoogleSyncUI(.exportBlocks)
                if googleSyncIssue == .exportBlocks { googleSyncIssue = nil }
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            calendarSettingRetry = nil
            calendarSettingIssue = enabled
                ? "Filuma couldn’t turn Google export on yet, so the setting stayed off. Try again."
                : "Filuma couldn’t turn Google export off yet, so the setting stayed on. Try again."
        }
    }

    private func performGoogleSync(
        _ operation: GoogleSyncOperation,
        settings: UserSettings
    ) {
        // A fresh explicit choice supersedes the Settings presentation for an
        // older request. The service serializes/coalesces imports internally;
        // this request ID only prevents a stale completion from clearing or
        // replacing feedback for the newer choice.
        googleSyncTask?.cancel()
        let requestID = UUID()
        googleSyncRequestID = requestID
        googleSyncInFlight = operation
        if googleSyncIssue == operation { googleSyncIssue = nil }

        googleSyncTask = Task { @MainActor in
            let result: GoogleCalendarService.SyncResult
            switch operation {
            case .importBusyTimes:
                result = await GoogleCalendarService.importNow(
                    context: modelContext,
                    settings: settings
                )
            case .exportBlocks:
                result = await GoogleCalendarService.exportNow(
                    context: modelContext,
                    settings: settings
                )
            }

            guard googleSyncRequestID == requestID else { return }
            googleSyncTask = nil
            googleSyncRequestID = nil
            googleSyncInFlight = nil
            handleGoogleSyncResult(result, operation: operation)
        }
    }

    private func cancelGoogleSyncUI(_ operation: GoogleSyncOperation? = nil) {
        guard operation == nil || googleSyncInFlight == operation else { return }
        googleSyncTask?.cancel()
        googleSyncTask = nil
        googleSyncRequestID = nil
        googleSyncInFlight = nil
    }

    private func handleGoogleSyncResult(
        _ result: GoogleCalendarService.SyncResult,
        operation: GoogleSyncOperation
    ) {
        switch result {
        case .success:
            if googleSyncIssue == operation { googleSyncIssue = nil }
        case .needsReconnect:
            if googleSyncIssue == operation { googleSyncIssue = nil }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .failed:
            googleSyncIssue = operation
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            UIAccessibility.post(
                notification: .announcement,
                argument: operation.failureAnnouncement
            )
        case .queued, .disabled, .cancelled:
            break
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsGroup(
            title: "About",
            footer: "Export writes your tasks, blocks, sessions, reminders, blocked times, and preferences to a plain JSON file. OAuth credentials are never included. Your data is yours."
        ) {
            SettingsRow(icon: "info.circle", tint: .filumaSubtle, label: "Version") {
                Text(appVersion)
                    .font(AppFont.monoMedium(13))
                    .foregroundStyle(Color.filumaSubtle)
            }

            Link(destination: URL(string: "https://sparkbiscuit.me/privacy")!) {
                SettingsRow(icon: "hand.raised.fill", tint: .filumaSubtle, label: "Privacy Policy") {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.filumaFaint)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Privacy Policy, opens in browser")

            Link(destination: URL(string: "https://sparkbiscuit.me/")!) {
                SettingsRow(icon: "questionmark.circle.fill", tint: .filumaSubtle, label: "Help & Support") {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.filumaFaint)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Help and Support, opens in browser")

            if let url = exportFileURL {
                ShareLink(item: url) {
                    SettingsRow(icon: "square.and.arrow.up", tint: .brand300, label: "Share the export", labelTint: .brand300) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    prepareExport()
                } label: {
                    SettingsRow(icon: "shippingbox", tint: .brand300, label: "Export my data", labelTint: .brand300) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func prepareExport() {
        do {
            exportFileURL = try DataExporter.writeExportFile(context: modelContext)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            showExportFailed = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var appVersion: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Group container

/// A Hearthlight settings section: caption header, 18pt rounded container,
/// hairline dividers between rows, quiet footer.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppFont.heading(13))
                .foregroundStyle(Color.filumaSubtle)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        if index > 0 {
                            Divider()
                                .overlay(Color.filumaBorder)
                                .padding(.leading, 56)
                        }
                        subview
                    }
                }
            }
            .background(Color.filumaSurface)
            .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.group, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FilumaRadius.group, style: .continuous)
                    .stroke(Color.filumaBorder, lineWidth: 1)
            )

            if let footer {
                Text(footer)
                    .font(AppFont.body(12))
                    .foregroundStyle(Color.filumaFaint)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.bottom, 22)
    }
}

// MARK: - Row

/// Icon tile + label + trailing control, the Hearthlight settings row.
private struct SettingsRow<Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let icon: String
    let tint: Color
    let label: String
    var labelTint: Color = .filumaText
    @ViewBuilder var trailing: Trailing

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                iconAndLabel
                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .settingsRowChrome(verticalPadding: 10)
        } else {
            HStack(spacing: 12) {
                iconAndLabel
                Spacer(minLength: 8)
                trailing
            }
            .settingsRowChrome(verticalPadding: 5)
        }
    }

    private var iconAndLabel: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)

            Text(label)
                .font(AppFont.settingsRowLabel())
                .foregroundStyle(labelTint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    func settingsRowChrome(verticalPadding: CGFloat) -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
    }
}

// MARK: - Signature hearth panel

/// Settings gets one authored surface rather than another generic row group:
/// the live accent choice is the visible source of the app's warmth. It stays
/// still, responds immediately, and lets the rest of the screen remain quiet.
private struct HearthAccentPanel: View {
    let selectedAccent: HearthAccent
    let onSelect: (HearthAccent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.brand500.opacity(0.16))
                        .frame(width: 54, height: 54)
                    Circle()
                        .stroke(Color.brand300.opacity(0.34), lineWidth: 1)
                        .frame(width: 54, height: 54)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(LinearGradient.hearth)
                        .hearthGlow(.brand500, radius: 10, opacity: 0.5)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Hearth")
                        .font(AppFont.heading(12))
                        .foregroundStyle(Color.brand300)
                        .accessibilityIdentifier("settings.hearth.title")
                    Text(selectedAccent.displayName)
                        .font(AppFont.heading(19))
                        .foregroundStyle(Color.filumaText)
                    Text("This warmth follows every active thread.")
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.filumaSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Rectangle()
                .fill(Color.filumaBorder)
                .frame(height: 1)
                .accessibilityHidden(true)

            HStack(spacing: 4) {
                ForEach(HearthAccent.allCases) { accent in
                    AccentSwatch(
                        accent: accent,
                        isSelected: selectedAccent == accent,
                        action: { onSelect(accent) }
                    )
                }
                Spacer(minLength: 0)
                Text("Choose a flame")
                    .font(AppFont.caption(11))
                    .foregroundStyle(Color.filumaFaint)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: FilumaRadius.hero, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.brand500.opacity(0.13), Color.filumaSurface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.hero, style: .continuous)
                .stroke(Color.brand500.opacity(0.24), lineWidth: 1)
        }
        .hearthGlow(.brand500, radius: 22, opacity: 0.09)
    }
}

// MARK: - Accent swatch

private struct AccentSwatch: View {
    let accent: HearthAccent
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent.hi, accent.soft],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? accent.hi : Color.filumaBorder, lineWidth: 2)
                    )
                    .shadow(color: isSelected ? accent.color.opacity(0.6) : .clear, radius: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color.filumaControlInk)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel("\(accent.displayName) flame")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("settings.hearth.\(accent.rawValue)")
    }
}

// MARK: - Calendar picker

/// Per-calendar include/exclude for Apple Calendar import. Toggling off a
/// calendar (say, a family calendar full of events that shouldn't block work
/// time) removes its imported events and frees those slots.
private struct CalendarPickerView: View {
    @Environment(\.modelContext) private var modelContext
    let settings: UserSettings

    @State private var calendarsBySource: [(source: String, calendars: [EKCalendar])] = []
    @State private var updateIssue: String?

    var body: some View {
        List {
            ForEach(calendarsBySource, id: \.source) { group in
                Section {
                    ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: inclusionBinding(for: calendar)) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(calendarDotColor(calendar))
                                    .frame(width: 10, height: 10)
                                Text(calendar.title)
                                    .font(AppFont.settingsRowLabel())
                                    .foregroundStyle(Color.filumaText)
                            }
                        }
                        .toggleStyle(HearthToggleStyle())
                    }
                } header: {
                    Text(group.source)
                        .font(AppFont.heading(13))
                        .foregroundStyle(Color.filumaSubtle)
                }
                .listRowBackground(Color.filumaSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.filumaBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Calendars")
                    .font(AppFont.heading(16))
                    .foregroundStyle(Color.filumaText)
            }
        }
        .onAppear(perform: loadCalendars)
        .alert(
            "Calendar update needs attention",
            isPresented: Binding(
                get: { updateIssue != nil },
                set: { if !$0 { updateIssue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                updateIssue = nil
            }
        } message: {
            Text(updateIssue ?? "")
        }
    }

    private func calendarDotColor(_ calendar: EKCalendar) -> Color {
        if let cgColor = calendar.cgColor {
            return Color(cgColor: cgColor)
        }
        return .filumaFaint
    }

    private func loadCalendars() {
        let all = CalendarImportService.availableCalendars(settings: settings)
        let grouped = Dictionary(grouping: all) { $0.source?.title ?? "Other" }
        calendarsBySource = grouped
            .map { (source: $0.key, calendars: $0.value) }
            .sorted { $0.source < $1.source }
    }

    private func inclusionBinding(for calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { !settings.excludedCalendarIds.contains(calendar.calendarIdentifier) },
            set: { included in
                var nextExcludedIds = settings.excludedCalendarIds
                if included {
                    nextExcludedIds.removeAll { $0 == calendar.calendarIdentifier }
                } else if !nextExcludedIds.contains(calendar.calendarIdentifier) {
                    nextExcludedIds.append(calendar.calendarIdentifier)
                }

                do {
                    try CalendarImportService.updateExcludedCalendars(
                        nextExcludedIds,
                        settings: settings,
                        context: modelContext
                    )
                    if !replanAfterBusyChange(context: modelContext) {
                        updateIssue = "Your calendar choice is saved, but Filuma couldn’t safely refresh the plan yet. The next foreground refresh will retry."
                    }
                } catch {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    updateIssue = "Filuma couldn’t safely refresh that calendar, so your choice and existing busy times are unchanged. Try again."
                }
            }
        )
    }
}
