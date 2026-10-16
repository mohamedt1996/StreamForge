import Foundation
import Observation
#if os(iOS)
import UserNotifications
#endif

struct ProgrammeReminder: Codable, Identifiable, Hashable {
    var id: String
    var channelID: Int
    var channelName: String
    var title: String
    var start: Date
    var end: Date

    static func makeID(channelID: Int, start: Date) -> String { "\(channelID)-\(Int(start.timeIntervalSince1970))" }

    var deepLink: URL { URL(string: "streamforge://channel?id=\(channelID)")! }
    var isOver: Bool { end < Date() }
}

/// "Remind me" for guide programmes. iOS uses local notifications (tapping one tunes the
/// channel); tvOS can't show notification alerts, so the app shows an in-app banner instead.
@MainActor
@Observable
final class ReminderCenter {
    static let shared = ReminderCenter()

    private(set) var reminders: [ProgrammeReminder] = []
    /// tvOS (and iOS when notifications are off): the reminder to show as a banner.
    var activeAlert: ProgrammeReminder?
    private(set) var permissionDenied = false

    @ObservationIgnored private var firedIDs = Set<String>()
    @ObservationIgnored private var loop: Task<Void, Never>?

    private init() {
        reminders = (FileStore.load([ProgrammeReminder].self, "reminders.json") ?? []).filter { !$0.isOver }
        startLoop()
    }

    private func save() { FileStore.save(reminders, "reminders.json", mirrorToDefaults: true) }

    func has(channelID: Int, programme: XCEPGListing) -> Bool {
        let id = ProgrammeReminder.makeID(channelID: channelID, start: programme.start)
        return reminders.contains { $0.id == id }
    }

    func toggle(channel: XCChannel, programme: XCEPGListing) {
        if has(channelID: channel.id, programme: programme) {
            remove(ProgrammeReminder.makeID(channelID: channel.id, start: programme.start))
        } else {
            add(channel: channel, programme: programme)
        }
    }

    func add(channel: XCChannel, programme: XCEPGListing) {
        guard programme.start > Date() else { return }
        let r = ProgrammeReminder(id: ProgrammeReminder.makeID(channelID: channel.id, start: programme.start),
                                  channelID: channel.id, channelName: channel.name, title: programme.title,
                                  start: programme.start, end: programme.end)
        guard !reminders.contains(where: { $0.id == r.id }) else { return }
        reminders.append(r)
        reminders.sort { $0.start < $1.start }
        save()
        #if os(iOS)
        Task { await scheduleNotification(r) }
        #endif
    }

    func remove(_ id: String) {
        reminders.removeAll { $0.id == id }
        save()
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["reminder.\(id)"])
        #endif
    }

    func importReminders(_ list: [ProgrammeReminder]) {
        for r in list where !r.isOver && !reminders.contains(where: { $0.id == r.id }) {
            reminders.append(r)
            #if os(iOS)
            Task { await scheduleNotification(r) }
            #endif
        }
        reminders.sort { $0.start < $1.start }
        save()
    }

    func watch(_ reminder: ProgrammeReminder) {
        activeAlert = nil
        AppRouter.shared.tuneChannel(id: reminder.channelID)
    }

    // MARK: In-app banner

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func tick() {
        let now = Date()
        let before = reminders.count
        reminders.removeAll { $0.isOver }
        if reminders.count != before { save() }
        #if os(iOS)
        // iOS shows system notifications; only fall back to the banner when they're denied.
        guard permissionDenied else { return }
        #endif
        if let due = reminders.first(where: { $0.start <= now.addingTimeInterval(60) && !firedIDs.contains($0.id) }) {
            firedIDs.insert(due.id)
            activeAlert = due
        }
    }

    // MARK: iOS notifications

    #if os(iOS)
    private func scheduleNotification(_ r: ProgrammeReminder) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if settings.authorizationStatus == .notDetermined {
            allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        permissionDenied = !allowed
        guard allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = "Starting now on \(r.channelName). Tap to watch."
        content.sound = .default
        content.userInfo = ["url": r.deepLink.absoluteString]
        let interval = max(1, r.start.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: "reminder.\(r.id)", content: content, trigger: trigger)
        try? await center.add(request)
    }
    #endif
}

#if os(iOS)
/// Routes taps on reminder notifications to the deep link, and shows them while the app is open.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let link = response.notification.request.content.userInfo["url"] as? String
        if let link, let url = URL(string: link) {
            Task { @MainActor in AppRouter.shared.handle(url) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
#endif
