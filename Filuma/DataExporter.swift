import Foundation
import SwiftData

/// The user's portable Filuma record as JSON. A trust feature: authored plan,
/// history, reminders, blocked time, and settings are exportable any time and
/// readable by anything. Imported calendar copies and authentication secrets
/// are deliberately not a backup payload.
enum DataExporter {

    struct Export: Codable {
        var version = 4
        var exportedAt = Date()
        var settings: SettingsRecord?
        var tasks: [TaskRecord] = []
        var templates: [TemplateRecord] = []
        var blocks: [BlockRecord] = []
        var workSessions: [SessionRecord] = []
        var reminders: [ReminderRecord] = []
        var blockedTimes: [BlockedTimeRecord] = []
    }

    /// User-authored preferences and connection state. OAuth credentials and
    /// opaque sync cursors are deliberately excluded: an honest portable
    /// export should describe the user's choices without copying secrets.
    struct SettingsRecord: Codable {
        let id: UUID
        let wakeHour: Int
        let wakeMinute: Int
        let sleepHour: Int
        let sleepMinute: Int
        let minBlockMinutes: Int
        let maxBlockMinutes: Int
        let deadlineBufferMinutes: Int
        let startBufferMinutes: Int
        let dailyFocusMinutes: Int
        let planningRebuildPending: Bool
        let exportToAppleCalendar: Bool
        let importFromAppleCalendar: Bool
        let excludedCalendarIds: [String]
        let importFromGoogleCalendar: Bool
        let exportToGoogleCalendar: Bool
        let googleAccountEmail: String?
        let googleNeedsReconnect: Bool
        let hasCompletedOnboarding: Bool
        let blockRemindersEnabled: Bool
        let blockReminderLeadMinutes: Int
        let morningPreviewEnabled: Bool
        let eveningReviewEnabled: Bool
        let eveningReviewHour: Int
        let eveningReviewMinute: Int
        let hearthAccent: String
    }

    struct TaskRecord: Codable {
        let id: UUID
        let title: String
        let context: String
        let deadline: Date
        let effortMinutes: Int
        let isComplete: Bool
        let completedAt: Date?
        let manualProgressPercent: Int
        let firstStep: String?
        let source: String
        let templateId: UUID?
    }

    struct TemplateRecord: Codable {
        let id: UUID
        let title: String
        let context: String
        let effortMinutes: Int
        let firstStep: String?
        let nextDeadline: Date
        let repeatUntil: Date
    }

    struct BlockRecord: Codable {
        let id: UUID
        let taskId: UUID?
        let startTime: Date
        let durationMinutes: Int
        let isComplete: Bool
        let isLocked: Bool
    }

    struct SessionRecord: Codable {
        let id: UUID
        let taskId: UUID?
        let scheduledBlockId: UUID?
        let startedAt: Date
        let durationSeconds: Int
    }

    struct ReminderRecord: Codable {
        let id: UUID
        let title: String
        let dueDate: Date
        let isComplete: Bool
    }

    struct BlockedTimeRecord: Codable {
        let id: UUID
        let label: String
        let weekdays: [Int]
        let startHour: Int
        let startMinute: Int
        let durationMinutes: Int
    }

    static func exportJSON(context: ModelContext) throws -> Data {
        var export = Export()

        if let settings = try context.fetch(FetchDescriptor<UserSettings>()).first {
            export.settings = SettingsRecord(
                id: settings.id,
                wakeHour: settings.wakeHour,
                wakeMinute: settings.wakeMinute,
                sleepHour: settings.sleepHour,
                sleepMinute: settings.sleepMinute,
                minBlockMinutes: settings.minBlockMinutes,
                maxBlockMinutes: settings.maxBlockMinutes,
                deadlineBufferMinutes: settings.deadlineBufferMinutes,
                startBufferMinutes: settings.startBufferMinutes,
                dailyFocusMinutes: settings.dailyFocusMinutes,
                planningRebuildPending: settings.planningRebuildPending,
                exportToAppleCalendar: settings.exportToAppleCalendar,
                importFromAppleCalendar: settings.importFromAppleCalendar,
                excludedCalendarIds: settings.excludedCalendarIds,
                importFromGoogleCalendar: settings.importFromGoogleCalendar,
                exportToGoogleCalendar: settings.exportToGoogleCalendar,
                googleAccountEmail: settings.googleAccountEmail,
                googleNeedsReconnect: settings.googleNeedsReconnect,
                hasCompletedOnboarding: settings.hasCompletedOnboarding,
                blockRemindersEnabled: settings.blockRemindersEnabled,
                blockReminderLeadMinutes: settings.blockReminderLeadMinutes,
                morningPreviewEnabled: settings.morningPreviewEnabled,
                eveningReviewEnabled: settings.eveningReviewEnabled,
                eveningReviewHour: settings.eveningReviewHour,
                eveningReviewMinute: settings.eveningReviewMinute,
                hearthAccent: HearthAccent.current.rawValue
            )
        }

        export.tasks = try context.fetch(FetchDescriptor<FilumaTask>()).map { task in
            TaskRecord(
                id: task.id,
                title: task.title,
                context: task.context.rawValue,
                deadline: task.deadline,
                effortMinutes: task.effortMinutes,
                isComplete: task.isComplete,
                completedAt: task.completedAt,
                manualProgressPercent: task.manualProgressPercent,
                firstStep: task.firstStep,
                source: task.source.rawValue,
                templateId: task.templateId
            )
        }
        export.templates = try context.fetch(FetchDescriptor<TaskTemplate>()).map { template in
            TemplateRecord(
                id: template.id,
                title: template.title,
                context: template.context.rawValue,
                effortMinutes: template.effortMinutes,
                firstStep: template.firstStep,
                nextDeadline: template.nextDeadline,
                repeatUntil: template.repeatUntil
            )
        }
        export.blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).map { block in
            BlockRecord(
                id: block.id,
                taskId: block.task?.id,
                startTime: block.startTime,
                durationMinutes: block.durationMinutes,
                isComplete: block.isComplete,
                isLocked: block.isLocked
            )
        }
        export.workSessions = try context.fetch(FetchDescriptor<WorkSession>()).map { session in
            SessionRecord(
                id: session.id,
                taskId: session.task?.id,
                scheduledBlockId: session.scheduledBlockId,
                startedAt: session.startedAt,
                durationSeconds: session.durationSeconds
            )
        }
        export.reminders = try context.fetch(FetchDescriptor<Reminder>()).map { reminder in
            ReminderRecord(
                id: reminder.id,
                title: reminder.title,
                dueDate: reminder.dueDate,
                isComplete: reminder.isComplete
            )
        }
        export.blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>()).map { blocked in
            BlockedTimeRecord(
                id: blocked.id,
                label: blocked.label,
                weekdays: blocked.weekdays,
                startHour: blocked.startHour,
                startMinute: blocked.startMinute,
                durationMinutes: blocked.durationMinutes
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    /// Write the export to a shareable temp file, named by date.
    static func writeExportFile(context: ModelContext) throws -> URL {
        let data = try exportJSON(context: context)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Filuma Export \(formatter.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
