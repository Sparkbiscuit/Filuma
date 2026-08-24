import Foundation
import UserNotifications

/// Local notifications for one-off reminders.
@MainActor
enum NotificationService {

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func schedule(receipt: ReminderCaptureReceipt) {
        schedule(
            title: receipt.title,
            dueDate: receipt.dueDate,
            notificationID: receipt.notificationID
        )
    }

    /// Re-arm a restored reminder from post-commit scalar facts. The caller
    /// never needs to keep a SwiftData model alive across the save boundary.
    static func schedule(receipt: ReminderMutationReceipt) {
        schedule(
            title: receipt.title,
            dueDate: receipt.dueDate,
            notificationID: receipt.notificationID
        )
    }

    private static func schedule(
        title: String,
        dueDate: Date,
        notificationID: String
    ) {
        guard dueDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Reminder from Filuma"
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: dueDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: trigger
        )
        BlockNotificationService.addDirectRequestMakingRoom(request)
    }

    /// Cancel from a durable receipt, including after the source row has been
    /// deleted from SwiftData.
    static func cancel(notificationID: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
    }
}
