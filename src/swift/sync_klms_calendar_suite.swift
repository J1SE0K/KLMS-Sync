import AppKit
import EventKit
import Foundation

struct SyncState: Decodable {
    let status: String
    let content: SyncContent?
}

struct SyncContent: Decodable {
    let kind: String
    let examItems: [SyncItem]?
    let helpDeskItems: [SyncItem]?

    enum CodingKeys: String, CodingKey {
        case kind
        case examItems = "exam_items"
        case helpDeskItems = "help_desk_items"
    }
}

struct SyncItem: Decodable {
    let url: String
    let course: String
    let title: String
    let due: String
    let submission: String
    let instructions: String
    let category: String?
    let timingPrecision: String?
    let timeSource: String?
    let syncStart: String?
    let syncDue: String?
    let sourceTitle: String?
    let location: String?
    let coverage: String?
    let coverageSummary: String?

    enum CodingKeys: String, CodingKey {
        case url
        case course
        case title
        case due
        case submission
        case instructions
        case category
        case timingPrecision = "timing_precision"
        case timeSource = "time_source"
        case syncStart = "sync_start"
        case syncDue = "sync_due"
        case sourceTitle = "source_title"
        case location
        case coverage
        case coverageSummary = "coverage_summary"
    }
}

struct DesiredStandardEvent {
    let identifier: String
    let title: String
    let startDate: Date?
    let dueDate: Date
    let location: String
    let notes: String
}

enum StandardBucket: String {
    case exam
    case helpdesk
}

enum SuiteError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        }
    }
}

let currentSyncMarkerPrefix = "KLMS_SYNC_ITEM_ID:"
let legacySyncMarkerPrefixes = ["KLMS_ASSIGN_ID:"]
let syncMarkerPrefixes = [currentSyncMarkerPrefix] + legacySyncMarkerPrefixes

do {
    try main()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else {
        throw SuiteError.message(
            "Usage: sync_klms_calendar_suite.swift <state_json> [--duration-minutes=15] [--lookback-days=365] [--exam-calendar=...] [--helpdesk-calendar=...]"
        )
    }

    let statePath = arguments[0]
    let durationMinutes = parseIntArgument(arguments, prefix: "--duration-minutes=", defaultValue: 15)
    let lookbackDays = parseIntArgument(arguments, prefix: "--lookback-days=", defaultValue: 365)
    let examCalendarName = parseStringArgument(arguments, prefix: "--exam-calendar=")
    let helpDeskCalendarName = parseStringArgument(arguments, prefix: "--helpdesk-calendar=")

    guard examCalendarName != nil
        || helpDeskCalendarName != nil
    else {
        throw SuiteError.message("At least one calendar target must be provided.")
    }

    let store = EKEventStore()
    guard requestAccess(store: store) else {
        throw SuiteError.message("Calendar access was not granted.")
    }

    let stateURL = URL(fileURLWithPath: statePath)
    let decoder = JSONDecoder()

    let state: SyncState
    do {
        let data = try Data(contentsOf: stateURL)
        state = try decoder.decode(SyncState.self, from: data)
    } catch {
        throw SuiteError.message("Failed to load state JSON: \(error.localizedDescription)")
    }

    guard state.status == "ok", let content = state.content, content.kind == "success" else {
        throw SuiteError.message("State is not syncable.")
    }

    var summaries: [String] = []

    if let calendarName = examCalendarName {
        summaries.append(
            try syncStandardCalendar(
                named: calendarName,
                bucket: .exam,
                content: content,
                store: store,
                minimumSpanMinutes: durationMinutes,
                lookbackDays: lookbackDays
            )
        )
    }

    if let calendarName = helpDeskCalendarName {
        summaries.append(
            try syncStandardCalendar(
                named: calendarName,
                bucket: .helpdesk,
                content: content,
                store: store,
                minimumSpanMinutes: durationMinutes,
                lookbackDays: lookbackDays
            )
        )
    }

    do {
        try store.commit()
    } catch {
        throw SuiteError.message("Failed to commit calendar changes: \(error.localizedDescription)")
    }

    print(summaries.joined(separator: "\n"))
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

func syncStandardCalendar(
    named calendarName: String,
    bucket: StandardBucket,
    content: SyncContent,
    store: EKEventStore,
    minimumSpanMinutes: Int,
    lookbackDays: Int
) throws -> String {
    guard let calendar = resolveStandardCalendar(named: calendarName, store: store) else {
        throw SuiteError.message("Could not resolve or create calendar: \(calendarName)")
    }

    let desiredEvents = buildDesiredStandardEvents(items: standardSyncableItems(from: content, bucket: bucket))
    let desiredByID = Dictionary(uniqueKeysWithValues: desiredEvents.map { ($0.identifier, $0) })
    let existingEvents = managedEvents(
        in: calendar,
        store: store,
        markerPrefixes: syncMarkerPrefixes,
        lookbackDays: lookbackDays
    )

    var created = 0
    var updated = 0
    var deleted = 0

    for event in existingEvents {
        guard let identifier = extractIdentifier(from: event.notes, markerPrefixes: syncMarkerPrefixes) else {
            continue
        }
        guard let desired = desiredByID[identifier] else {
            do {
                try store.remove(event, span: .thisEvent, commit: false)
                deleted += 1
            } catch {
                throw SuiteError.message("Failed to delete event for \(identifier): \(error.localizedDescription)")
            }
            continue
        }

        if applyStandardEventIfNeeded(
            event: event,
            desired: desired,
            minimumSpanMinutes: minimumSpanMinutes
        ) {
            do {
                try store.save(event, span: .thisEvent, commit: false)
                updated += 1
            } catch {
                throw SuiteError.message("Failed to update event for \(identifier): \(error.localizedDescription)")
            }
        }
    }

    let existingIDs = Set(existingEvents.compactMap { extractIdentifier(from: $0.notes, markerPrefixes: syncMarkerPrefixes) })
    for desired in desiredEvents where !existingIDs.contains(desired.identifier) {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = desired.title
        event.startDate =
            desired.startDate
            ?? resolvedStartDate(
                existingStart: nil,
                existingCreationDate: nil,
                dueDate: desired.dueDate,
                minimumSpanMinutes: minimumSpanMinutes
            )
        event.endDate = desired.dueDate
        event.location = desired.location
        event.notes = desired.notes
        event.timeZone = TimeZone(identifier: "Asia/Seoul")
        event.availability = .free
        event.alarms = buildRelativeAlarms(dueDate: desired.dueDate)

        do {
            try store.save(event, span: .thisEvent, commit: false)
            created += 1
        } catch {
            throw SuiteError.message("Failed to create event for \(desired.identifier): \(error.localizedDescription)")
        }
    }

    return "calendar=\(calendar.title) bucket=\(bucket.rawValue) created=\(created) updated=\(updated) deleted=\(deleted) total=\(desiredEvents.count)"
}

func buildDesiredStandardEvents(items: [SyncItem]) -> [DesiredStandardEvent] {
    items.compactMap { item in
        guard let dueDate = parseDueDate(for: item) else { return nil }
        if !isCalendarNoticeItem(item) {
            guard dueDate > Date() else { return nil }
        }

        let explicitStartDate = parseStartDate(for: item)
        let calendarNotice = isCalendarNoticeItem(item)
        let identifier = itemIdentifier(for: item)
        let kindLabel = eventKindLabel(for: item)
        let scheduleLabel = calendarNotice ? "일정" : "마감"
        let sourceLine = (item.sourceTitle ?? "").isEmpty ? "" : "\n출처: \(item.sourceTitle!)"
        let timingLine = calendarNotice ? calendarTimingLine(for: item) : ""
        let location = item.category == "exam" ? resolvedExamLocation(for: item) : ""
        let coverage = item.category == "exam" ? resolvedExamCoverageSummary(for: item) : ""
        let coverageLine = calendarCoverageLine(coverage)
        let notes = """
\(currentSyncMarkerPrefix)\(identifier)
종류: \(kindLabel)
과목: \(item.course)
\(kindLabel): \(item.title)
\(scheduleLabel): \(item.due)\(timingLine)\(sourceLine)\(coverageLine)
제출 상태: \(item.submission)
메모: \(item.instructions)
링크: \(item.url)
"""
        let titlePrefix = calendarTitlePrefix(for: item)
        let title = item.course.isEmpty
            ? "\(titlePrefix) \(item.title)"
            : "\(titlePrefix) \(item.course) - \(item.title)"

        return DesiredStandardEvent(
            identifier: identifier,
            title: title,
            startDate: explicitStartDate,
            dueDate: dueDate,
            location: location,
            notes: notes
        )
    }
}

func standardSyncableItems(from content: SyncContent, bucket: StandardBucket) -> [SyncItem] {
    let items = (content.examItems ?? []) + (content.helpDeskItems ?? [])
    switch bucket {
    case .exam:
        return items.filter(isExamCalendarItem)
    case .helpdesk:
        return items.filter(isHelpDeskCalendarItem)
    }
}

func syncItemBaseIdentifier(from url: String) -> String {
    if let components = URLComponents(string: url),
       let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
       !id.isEmpty {
        return id
    }
    return url
}

func itemIdentifier(for item: SyncItem) -> String {
    let base = syncItemBaseIdentifier(from: item.url)
    if item.category == "exam" {
        let titlePart = identifierFragment(item.title)
        let duePart = identifierFragment(item.syncDue ?? item.due)
        return "exam:\(base):\(titlePart):\(duePart)"
    }

    if item.category == "help_desk" {
        let titlePart = identifierFragment(item.title)
        let duePart = identifierFragment(item.syncDue ?? item.due)
        return "helpdesk:\(base):\(titlePart):\(duePart)"
    }

    return base
}

func parseDueDate(for item: SyncItem) -> Date? {
    if let syncDue = item.syncDue, let isoDate = parseISODate(syncDue) {
        return isoDate
    }
    return parseDueDate(item.due)
}

func parseStartDate(for item: SyncItem) -> Date? {
    guard let syncStart = item.syncStart else { return nil }
    return parseISODate(syncStart)
}

func isCalendarNoticeItem(_ item: SyncItem) -> Bool {
    isExamCalendarItem(item) || isHelpDeskCalendarItem(item)
}

func isExamCalendarItem(_ item: SyncItem) -> Bool {
    item.category == "exam"
}

func isHelpDeskCalendarItem(_ item: SyncItem) -> Bool {
    item.category == "help_desk"
}

func eventKindLabel(for item: SyncItem) -> String {
    if item.category == "exam" {
        return "시험 일정"
    }
    if item.category == "help_desk" {
        return "헬프데스크 안내"
    }
    return "과제"
}

func calendarTitlePrefix(for item: SyncItem) -> String {
    if item.category == "exam" {
        return "[KLMS 시험]"
    }
    if item.category == "help_desk" {
        return "[KLMS 헬프데스크]"
    }
    return "[KLMS]"
}

func calendarTimingLine(for item: SyncItem) -> String {
    if item.timeSource == "class_time" {
        return "\n시간: 공지에 시간이 없어 수업 시간으로 반영됨"
    }
    if item.timingPrecision == "date" {
        return "\n시간: KLMS에서 날짜만 확인됨"
    }
    return ""
}

func extractExamLocation(from text: String) -> String {
    firstCapture(
        in: normalizeSpaces(text),
        patterns: [
            #"(?:시험\s*)?(?:장소|고사장)\s*[:：]\s*(.+?)(?=\s*(?:시험\s*범위|범위|Date\s*&\s*Time|Coverage|Range|Time|Place|Location|$))"#,
            #"\b(?:Location|Place|Venue|Room)\s*:\s*(.+?)(?=\s*(?:Range|Coverage|Exam\s*Range|Time|Date\s*&\s*Time|시험\s*범위|시험\s*일시|$))"#,
        ]
    )
}

func resolvedExamLocation(for item: SyncItem) -> String {
    if let location = item.location, !normalizeSpaces(location).isEmpty {
        return normalizeSpaces(location)
    }
    let explicitLocation = extractExamLocation(from: item.instructions)
    if !explicitLocation.isEmpty {
        return explicitLocation
    }
    if isOnlineKlmsExamURL(item.url) {
        return item.url
    }
    return ""
}

func isOnlineKlmsExamURL(_ url: String) -> Bool {
    url.range(of: #"/mod/(assign|quiz)/view\.php"#, options: [.regularExpression, .caseInsensitive]) != nil
}

func extractExamCoverage(from text: String) -> String {
    firstCapture(
        in: normalizeSpaces(text),
        patterns: [
            #"(?:시험\s*)?범위\s*[:：]\s*(.+?)(?=\s*(?:Date\s*&\s*Time|Location|Place|Venue|Room|Coverage|Range|Time|시험\s*일시|시험\s*장소|$))"#,
            #"\b(?:Coverage|Range|Exam\s*Range)\s*:\s*(.+?)(?=\s*(?:[•⦁]|Time|Date\s*&\s*Time|Location|Place|Venue|Room|시험\s*일시|시험\s*장소|$))"#,
        ]
    )
}

func resolvedExamCoverage(for item: SyncItem) -> String {
    if let coverage = item.coverage, !normalizeSpaces(coverage).isEmpty {
        return normalizeSpaces(coverage)
    }
    return extractExamCoverage(from: item.instructions)
}

func resolvedExamCoverageSummary(for item: SyncItem) -> String {
    if let coverageSummary = item.coverageSummary {
        let normalized = normalizeMultilineField(coverageSummary)
        if !normalized.isEmpty {
            return normalized
        }
    }
    let coverage = resolvedExamCoverage(for: item)
    if coverage.isEmpty {
        return ""
    }
    if coverageNeedsManualCheck(coverage) {
        return "확인 필요 - 원문 참고"
    }
    return coverage.count <= 140 ? coverage : "확인 필요 - 원문 참고"
}

func calendarCoverageLine(_ coverage: String) -> String {
    let normalized = normalizeMultilineField(coverage)
    if normalized.isEmpty {
        return ""
    }
    if normalized.contains("\n") || normalized.hasPrefix("- ") {
        return "\n시험 범위:\n\(normalized)"
    }
    return "\n시험 범위: \(normalized)"
}

func coverageNeedsManualCheck(_ text: String) -> Bool {
    normalizeSpaces(text).range(
        of: #"\b(?:tba|tbd|to be announced|will be announced|to be determined)\b|추후\s*공지|별도\s*공지|공지\s*예정|미정|확인\s*필요"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}

func firstCapture(in text: String, patterns: [String]) -> String {
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            continue
        }
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            continue
        }
        return cleanupExtractedField(nsText.substring(with: match.range(at: 1)))
    }
    return ""
}

func cleanupExtractedField(_ text: String) -> String {
    normalizeSpaces(text).trimmingCharacters(in: CharacterSet(charactersIn: " .;,"))
}

func normalizeSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizeMultilineField(_ text: String) -> String {
    text.components(separatedBy: .newlines)
        .map { normalizeSpaces($0) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

func parseDueDate(_ text: String) -> Date? {
    if let koreanDue = parseKoreanDueDate(text) {
        return koreanDue
    }
    if let rangeDue = parseDottedRangeDueDate(text) {
        return rangeDue
    }
    return parseDottedDateDueDate(text)
}

func parseKoreanDueDate(_ text: String) -> Date? {
    let pattern = #"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일.*?(오전|오후)\s*(\d{1,2}):(\d{2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 7 else {
        return nil
    }

    let year = Int(nsText.substring(with: match.range(at: 1))) ?? 0
    let month = Int(nsText.substring(with: match.range(at: 2))) ?? 0
    let day = Int(nsText.substring(with: match.range(at: 3))) ?? 0
    let meridiem = nsText.substring(with: match.range(at: 4))
    var hour = Int(nsText.substring(with: match.range(at: 5))) ?? 0
    let minute = Int(nsText.substring(with: match.range(at: 6))) ?? 0

    hour = hour % 12
    if meridiem == "오후" {
        hour += 12
    }

    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(identifier: "Asia/Seoul")
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return components.date
}

func parseDottedRangeDueDate(_ text: String) -> Date? {
    let pattern = #"(\d{4})\.(\d{1,2})\.(\d{1,2})\s*~\s*(\d{4})\.(\d{1,2})\.(\d{1,2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 7 else {
        return nil
    }

    let year = Int(nsText.substring(with: match.range(at: 4))) ?? 0
    let month = Int(nsText.substring(with: match.range(at: 5))) ?? 0
    let day = Int(nsText.substring(with: match.range(at: 6))) ?? 0
    return buildSeoulDate(year: year, month: month, day: day, hour: 23, minute: 59)
}

func parseDottedDateDueDate(_ text: String) -> Date? {
    let pattern = #"(\d{4})\.(\d{1,2})\.(\d{1,2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 4 else {
        return nil
    }

    let year = Int(nsText.substring(with: match.range(at: 1))) ?? 0
    let month = Int(nsText.substring(with: match.range(at: 2))) ?? 0
    let day = Int(nsText.substring(with: match.range(at: 3))) ?? 0
    return buildSeoulDate(year: year, month: month, day: day, hour: 23, minute: 59)
}

func parseISODate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}

func identifierFragment(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
}

func buildSeoulDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(identifier: "Asia/Seoul")
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return components.date
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

func resolveStandardCalendar(named calendarName: String, store: EKEventStore) -> EKCalendar? {
    if let existing = findCalendar(named: calendarName, store: store) {
        applyCalendarAppearance(calendar: existing, store: store)
        return existing
    }

    let calendar = EKCalendar(for: .event, eventStore: store)
    calendar.title = calendarName

    if let source = store.defaultCalendarForNewEvents?.source
        ?? store.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .mobileMe || $0.sourceType == .local }) {
        calendar.source = source
    } else {
        return nil
    }

    applyCalendarAppearance(calendar: calendar, store: store)
    do {
        try store.saveCalendar(calendar, commit: true)
        return calendar
    } catch {
        return nil
    }
}

func applyCalendarAppearance(calendar: EKCalendar, store: EKEventStore) {
    let desiredColor = desiredCalendarColor(named: calendar.title)
    if calendar.cgColor != desiredColor.cgColor {
        calendar.cgColor = desiredColor.cgColor
    }

    do {
        try store.saveCalendar(calendar, commit: false)
    } catch {
        // Ignore appearance-only failures.
    }
}

func desiredCalendarColor(named calendarName: String) -> NSColor {
    switch calendarName {
    case "시험":
        return NSColor(
            calibratedRed: 185.0 / 255.0,
            green: 70.0 / 255.0,
            blue: 54.0 / 255.0,
            alpha: 1
        )
    case "기타", "헬프데스크":
        return NSColor(
            calibratedRed: 148.0 / 255.0,
            green: 163.0 / 255.0,
            blue: 184.0 / 255.0,
            alpha: 1
        )
    default:
        return NSColor(
            calibratedRed: 79.0 / 255.0,
            green: 70.0 / 255.0,
            blue: 229.0 / 255.0,
            alpha: 1
        )
    }
}

func findCalendar(named calendarName: String, store: EKEventStore) -> EKCalendar? {
    store.calendars(for: .event).first(where: { $0.title == calendarName })
}

func managedEvents(
    in calendar: EKCalendar,
    store: EKEventStore,
    markerPrefixes: [String],
    lookbackDays: Int
) -> [EKEvent] {
    let normalizedLookbackDays = max(1, lookbackDays)
    let windowStart = Calendar.current.date(byAdding: .day, value: -normalizedLookbackDays, to: Date()) ?? Date()
    let windowEnd = Calendar.current.date(byAdding: .day, value: 365, to: Date()) ?? Date()
    let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])
    return store.events(matching: predicate).filter { event in
        guard let notes = event.notes else { return false }
        return markerPrefixes.contains(where: { notes.contains($0) })
    }
}

func extractIdentifier(from notes: String?, markerPrefixes: [String]) -> String? {
    guard let notes else { return nil }
    for line in notes.split(separator: "\n") {
        for markerPrefix in markerPrefixes where line.hasPrefix(markerPrefix) {
            return String(line.dropFirst(markerPrefix.count))
        }
    }
    return nil
}

func applyStandardEventIfNeeded(
    event: EKEvent,
    desired: DesiredStandardEvent,
    minimumSpanMinutes: Int
) -> Bool {
    var changed = false
    let desiredStartDate =
        desired.startDate
        ?? resolvedStartDate(
            existingStart: event.startDate,
            existingCreationDate: event.creationDate,
            dueDate: desired.dueDate,
            minimumSpanMinutes: minimumSpanMinutes
        )

    if event.title != desired.title {
        event.title = desired.title
        changed = true
    }
    if abs(event.startDate.timeIntervalSince(desiredStartDate)) > 1 {
        event.startDate = desiredStartDate
        changed = true
    }
    if abs(event.endDate.timeIntervalSince(desired.dueDate)) > 1 {
        event.endDate = desired.dueDate
        changed = true
    }
    if event.notes != desired.notes {
        event.notes = desired.notes
        changed = true
    }
    if (event.location ?? "") != desired.location {
        event.location = desired.location
        changed = true
    }

    let desiredAlarms = buildRelativeAlarms(dueDate: desired.dueDate)
    if !sameRelativeAlarms(lhs: event.alarms ?? [], rhs: desiredAlarms) {
        event.alarms = desiredAlarms
        changed = true
    }

    event.timeZone = TimeZone(identifier: "Asia/Seoul")
    event.availability = .free
    return changed
}

func buildRelativeAlarms(dueDate: Date) -> [EKAlarm] {
    let now = Date()
    var alarms: [EKAlarm] = []

    if dueDate.timeIntervalSince(now) > 24 * 3600 {
        alarms.append(EKAlarm(relativeOffset: -24 * 3600))
    }
    if dueDate.timeIntervalSince(now) > 2 * 3600 {
        alarms.append(EKAlarm(relativeOffset: -2 * 3600))
    } else if dueDate.timeIntervalSince(now) > 15 * 60 {
        alarms.append(EKAlarm(relativeOffset: -15 * 60))
    }

    return alarms
}

func resolvedStartDate(
    existingStart: Date?,
    existingCreationDate: Date?,
    dueDate: Date,
    minimumSpanMinutes: Int
) -> Date {
    let minimumSpan = TimeInterval(max(minimumSpanMinutes, 1) * 60)
    let fallbackStart = max(Date(), dueDate.addingTimeInterval(-minimumSpan))

    guard let existingStart else {
        return fallbackStart
    }

    if dueDate.timeIntervalSince(existingStart) <= minimumSpan + 1,
       let existingCreationDate,
       existingCreationDate < dueDate {
        return existingCreationDate
    }

    if existingStart < dueDate {
        return existingStart
    }

    return fallbackStart
}

func sameRelativeAlarms(lhs: [EKAlarm], rhs: [EKAlarm]) -> Bool {
    let left = lhs.compactMap(\.relativeOffset).sorted()
    let right = rhs.compactMap(\.relativeOffset).sorted()
    return left == right
}
