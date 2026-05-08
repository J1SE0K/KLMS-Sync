import EventKit
import Foundation

enum VerifyCalendarError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        }
    }
}

do {
    try main()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let examCalendarName = parseStringArgument(arguments, prefix: "--exam-calendar=") ?? "시험"
    let helpDeskCalendarName = parseStringArgument(arguments, prefix: "--helpdesk-calendar=") ?? "기타"
    let lookbackDays = parseIntArgument(arguments, prefix: "--lookback-days=", defaultValue: 365)
    let lookaheadDays = parseIntArgument(arguments, prefix: "--lookahead-days=", defaultValue: 365)

    let store = EKEventStore()
    guard requestAccess(store: store) else {
        throw VerifyCalendarError.message("Calendar access was not granted.")
    }

    let calendars = store.calendars(for: .event)
    let calendarNames = Set(calendars.map(\.title))

    let examCount = eventCount(
        in: calendar(named: examCalendarName, calendars: calendars),
        titlePrefix: "[KLMS 시험]",
        store: store,
        lookbackDays: lookbackDays,
        lookaheadDays: lookaheadDays
    )
    let helpDeskCount = eventCount(
        in: calendar(named: helpDeskCalendarName, calendars: calendars),
        titlePrefix: "[KLMS 헬프데스크]",
        store: store,
        lookbackDays: lookbackDays,
        lookaheadDays: lookaheadDays
    )

    print("calendar_exam_count=\(examCount)")
    print("calendar_helpdesk_count=\(helpDeskCount)")
    print("legacy_calendar_assignment_exists=\(calendarNames.contains("KLMS 과제") ? "true" : "false")")
    print("legacy_calendar_alert_exists=\(calendarNames.contains("KLMS 알림") ? "true" : "false")")
}

func parseStringArgument(_ arguments: [String], prefix: String) -> String? {
    guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else {
        return nil
    }
    let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

func parseIntArgument(_ arguments: [String], prefix: String, defaultValue: Int) -> Int {
    guard let rawValue = parseStringArgument(arguments, prefix: prefix),
          let value = Int(rawValue)
    else {
        return defaultValue
    }
    return value
}

func requestAccess(store: EKEventStore) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false

    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { accessGranted, _ in
            granted = accessGranted
            semaphore.signal()
        }
    } else {
        store.requestAccess(to: .event) { accessGranted, _ in
            granted = accessGranted
            semaphore.signal()
        }
    }

    semaphore.wait()
    return granted
}

func calendar(named calendarName: String, calendars: [EKCalendar]) -> EKCalendar? {
    calendars.first(where: { $0.title == calendarName })
}

func eventCount(
    in calendar: EKCalendar?,
    titlePrefix: String,
    store: EKEventStore,
    lookbackDays: Int,
    lookaheadDays: Int
) -> Int {
    guard let calendar else {
        return 0
    }

    let now = Date()
    let dateCalendar = Calendar(identifier: .gregorian)
    let windowStart = dateCalendar.date(byAdding: .day, value: -max(1, lookbackDays), to: now) ?? now
    let windowEnd = dateCalendar.date(byAdding: .day, value: max(1, lookaheadDays), to: now) ?? now
    let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])

    return store.events(matching: predicate).filter { event in
        event.title?.hasPrefix(titlePrefix) == true
    }.count
}
