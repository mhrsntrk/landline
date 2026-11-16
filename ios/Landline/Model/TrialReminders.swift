import Foundation
import UserNotifications

// The trial is a free non-consumable, not a subscription, so nothing on Apple's
// side tells anyone it is about to end. These two local notifications are the
// only reminder there is. They are scheduled from the verified trial start, so
// they move with a restore and vanish with an unlock.

/// One local notification, planned as plain data so the schedule can be tested
/// without a notification center.
struct TrialReminder: Equatable {
    let id: String
    let fireDate: Date
    let title: String
    let body: String
}

enum TrialReminders {
    /// Fixed identifiers, so rescheduling replaces rather than stacks.
    static let ids = ["landline.trial.end-48h", "landline.trial.end-24h"]
    static let defaultsKey = "trialRemindersEnabled"

    /// Two reminders, 48 and 24 hours before the trial ends. Any that would
    /// fire in the past is dropped, so a restore late in the trial never sends
    /// a stale one.
    static func plan(trialEnd: Date, now: Date, price: String?) -> [TrialReminder] {
        let keep = price.map { "Keep Landline for \($0), paid once. No subscription." }
            ?? "Keep Landline with a one-time purchase. No subscription."
        let offsets: [(id: String, hours: Double, title: String)] = [
            (ids[0], 48, "Your Landline trial ends in 2 days"),
            (ids[1], 24, "Your Landline trial ends tomorrow"),
        ]
        return offsets.compactMap { offset in
            let fire = trialEnd.addingTimeInterval(-offset.hours * 3600)
            guard fire > now else { return nil }
            return TrialReminder(id: offset.id, fireDate: fire, title: offset.title,
                                 body: "\(keep) Your hosts and settings stay saved.")
        }
    }
}

/// Time left in the trial, in the words the host list and the paywall print.
/// Rounded up, so the label never claims less time than there is.
enum TrialCountdown {
    static func remaining(until end: Date, now: Date) -> String {
        let seconds = end.timeIntervalSince(now)
        if seconds <= 0 { return "ENDED" }
        if seconds >= 86_400 {
            let days = Int((seconds / 86_400).rounded(.up))
            return "\(days) \(days == 1 ? "DAY" : "DAYS") LEFT"
        }
        if seconds >= 3600 {
            let hours = Int((seconds / 3600).rounded(.up))
            return "\(hours) \(hours == 1 ? "HOUR" : "HOURS") LEFT"
        }
        return "UNDER AN HOUR LEFT"
    }
}

@MainActor protocol TrialReminderScheduler {
    /// Asks for permission if never asked; otherwise reports the answer
    /// already given. Returns whether alerts are allowed.
    func requestAuthorization() async -> Bool
    /// Removes every trial reminder, then adds these.
    func replace(with reminders: [TrialReminder]) async
    func cancelAll()
}

@MainActor final class NotificationTrialReminderScheduler: TrialReminderScheduler {
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func replace(with reminders: [TrialReminder]) async {
        cancelAll()
        // Without permission `add` fails quietly, which is the right outcome.
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let parts = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }

    func cancelAll() {
        center.removePendingNotificationRequests(withIdentifiers: TrialReminders.ids)
    }
}

/// For tests and previews: records what would have been scheduled.
@MainActor final class RecordingTrialReminderScheduler: TrialReminderScheduler {
    var authorizationRequests = 0
    var grantsAuthorization = true
    private(set) var scheduled: [TrialReminder] = []

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return grantsAuthorization
    }
    func replace(with reminders: [TrialReminder]) async { scheduled = reminders }
    func cancelAll() { scheduled = [] }
}
