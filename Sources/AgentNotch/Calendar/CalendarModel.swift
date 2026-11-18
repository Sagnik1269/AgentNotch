import AppKit
import EventKit

/// Upcoming events from the Calendar app's accounts (iCloud, Google, Exchange… whatever macOS has).
/// Nothing is read until you grant access from the Home tab or Settings.
@MainActor
final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()

    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: NSColor
        let location: String?
        let joinURL: URL?

        func isHappening(at date: Date = Date()) -> Bool { start <= date && date < end }
    }

    enum Access: Equatable { case notDetermined, granted, denied }

    @Published private(set) var access: Access = .notDetermined
    /// Remaining events today and tomorrow, timed events first by start.
    @Published private(set) var events: [Event] = []

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var alerted: Set<String> = []
    private var changeObserver: NSObjectProtocol?

    private init() {
        access = Self.currentAccess()
    }

    func start() {
        guard access == .granted, refreshTimer == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    /// Shows the macOS permission prompt (only when you ask for it).
    func requestAccess() {
        if access == .denied {
            openPrivacySettings()
            return
        }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.access = granted ? .granted : .denied
                    if granted { self.start() }
                }
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func open(_ event: Event) {
        if let url = event.joinURL {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
    }

    // MARK: - Loading

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func refresh() {
        access = Self.currentAccess()
        guard access == .granted else { events = []; return }
        let now = Date()
        let cal = Calendar.current
        let endOfTomorrow = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(172_800)
        let predicate = store.predicateForEvents(withStart: cal.startOfDay(for: now), end: endOfTomorrow, calendars: nil)
        let loaded = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled && !Self.declined($0) }
            .map { e in
                Event(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                      title: e.title?.isEmpty == false ? e.title! : "Untitled event",
                      start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                      color: e.calendar.color ?? .systemBlue,
                      location: e.location?.isEmpty == false ? e.location : nil,
                      joinURL: Self.joinURL(for: e))
            }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return !a.isAllDay }
                return a.start < b.start
            }
        if loaded != events { events = loaded }
        postUpcomingAlerts(now: now)
    }

    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    /// Video-call link from the event's URL, location or notes.
    private static func joinURL(for e: EKEvent) -> URL? {
        let pattern = #"https://[^\s<>"]*(meet\.google\.com|zoom\.us|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|meet\.jit\.si|facetime\.apple\.com)[^\s<>"]*"#
        for text in [e.url?.absoluteString, e.location, e.notes].compactMap({ $0 }) {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
               let url = URL(string: String(text[range])) {
                return url
            }
        }
        return nil
    }

    // MARK: - Alerts

    private func postUpcomingAlerts(now: Date) {
        let settings = AppSettings.shared
        guard settings.showCalendar, settings.calendarAlerts else { return }
        let lead = TimeInterval(max(settings.calendarAlertMinutes, 1) * 60)
        for event in events where !event.isAllDay && !alerted.contains(event.id) {
            let untilStart = event.start.timeIntervalSince(now)
            // The 30 s refresh means we land inside the window once; skip events already well underway.
            guard untilStart <= lead, untilStart > -60 else { continue }
            alerted.insert(event.id)
            let minutes = Int((untilStart / 60).rounded())
            let when = minutes <= 0 ? "Starting now" : "In \(minutes) min"
            let time = event.start.formatted(date: .omitted, time: .shortened)
            AlertCenter.shared.post(NotchAlert(
                icon: event.joinURL != nil ? "video.fill" : "calendar",
                tint: .blue, title: event.title,
                subtitle: "\(when) · \(time)\(event.location.map { " · \($0)" } ?? "")",
                tab: .home))
        }
        if alerted.count > 200 { alerted.removeAll() }
    }
}
