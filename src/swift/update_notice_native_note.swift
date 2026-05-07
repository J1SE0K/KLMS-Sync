import ApplicationServices
import AppKit
import CryptoKit
import Foundation

func parseArgs() -> (
    mode: String,
    target: String,
    skipNoteActivation: Bool,
    notesPID: pid_t?,
    noteTitle: String,
    noteID: String?,
    archiveNoteTitle: String,
    archiveNoteID: String?,
    digestPath: String,
    noticeStatePath: String,
    renderStatePath: String,
    archiveRenderStatePath: String
) {
    var mode = "all"
    var target = "both"
    var skipNoteActivation = false
    var notesPID: pid_t?
    var noteTitle = defaultNoteTitle
    var noteID: String?
    var archiveNoteTitle = defaultArchiveNoteTitle
    var archiveNoteID: String?
    var digestPath: String?
    var noticeStatePath: String?
    var renderStatePath: String?
    var archiveRenderStatePath: String?
    var index = 1
    let arguments = CommandLine.arguments

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--capture-only":
            mode = "capture"
        case "--render-only":
            mode = "render"
        case "--primary-only":
            target = "primary"
        case "--archive-only":
            target = "archive"
        case "--skip-note-activation":
            skipNoteActivation = true
        case "--notes-pid":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --notes-pid")
            }
            guard let parsed = Int32(arguments[index]) else {
                fail("Invalid value for --notes-pid: \(arguments[index])")
            }
            notesPID = parsed
        case "--note-title":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --note-title")
            }
            noteTitle = arguments[index]
        case "--note-id":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --note-id")
            }
            noteID = arguments[index]
        case "--archive-note-title":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --archive-note-title")
            }
            archiveNoteTitle = arguments[index]
        case "--archive-note-id":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --archive-note-id")
            }
            archiveNoteID = arguments[index]
        case "--notice-state-json":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --notice-state-json")
            }
            noticeStatePath = arguments[index]
        case "--render-state-json":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --render-state-json")
            }
            renderStatePath = arguments[index]
        case "--archive-render-state-json":
            index += 1
            guard index < arguments.count else {
                fail("Missing value for --archive-render-state-json")
            }
            archiveRenderStatePath = arguments[index]
        default:
            if digestPath == nil {
                digestPath = argument
            } else {
                fail("Unexpected argument: \(argument)")
            }
        }
        index += 1
    }

    guard let digestPath else {
        fail(
            "Usage: update_notice_native_note.swift [--capture-only|--render-only] "
                + "[--primary-only|--archive-only] [--skip-note-activation] "
                + "[--notes-pid <pid>] "
                + "[--note-title \"KLMS 공지\"] "
                + "[--note-id <id>] "
                + "[--archive-note-title \"KLMS 확인한 공지\"] "
                + "[--archive-note-id <id>] "
                + "[--notice-state-json <path>] [--render-state-json <path>] "
                + "[--archive-render-state-json <path>] <notice_digest.json>"
        )
    }

    return (
        mode,
        target,
        skipNoteActivation,
        notesPID,
        noteTitle,
        noteID,
        archiveNoteTitle,
        archiveNoteID,
        digestPath,
        noticeStatePath ?? defaultPath(near: digestPath, fileName: "notice_user_state.json"),
        renderStatePath ?? defaultPath(near: digestPath, fileName: "notice_note_render_state.json"),
        archiveRenderStatePath
            ?? defaultPath(near: digestPath, fileName: "notice_archive_note_render_state.json")
    )
}

func nsLength(_ text: String) -> Int {
    (text as NSString).length
}

func canonicalText(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping
}

func substring(_ text: String, range: LineRange) -> String? {
    let nsText = text as NSString
    let upperBound = range.location + range.length
    guard range.location >= 0, range.length >= 0, upperBound <= nsText.length else {
        return nil
    }
    return nsText.substring(with: NSRange(location: range.location, length: range.length))
}

func oneLine(_ text: String) -> String {
    canonicalText(text)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func truncated(_ text: String, maxLength: Int) -> String {
    let normalized = oneLine(text)
    let nsText = normalized as NSString
    if nsText.length <= maxLength {
        return normalized
    }
    let clipped = nsText.substring(to: max(0, maxLength - 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    return clipped.isEmpty ? String(normalized.prefix(1)) : "\(clipped)…"
}

func attachmentDisplayName(_ item: NoticeAttachmentItem) -> String {
    let explicitName = oneLine(item.name ?? "")
    if !explicitName.isEmpty {
        return explicitName
    }

    let fallbackPath = oneLine(item.relativePath ?? item.absolutePath ?? "")
    guard !fallbackPath.isEmpty else {
        return "(이름 없음)"
    }
    return URL(fileURLWithPath: fallbackPath).lastPathComponent
}

func attachmentDisplayPath(_ item: NoticeAttachmentItem) -> String? {
    let relativePath = oneLine(item.relativePath ?? "")
    if !relativePath.isEmpty {
        return relativePath.hasPrefix("course_files/") ? relativePath : "course_files/\(relativePath)"
    }

    let absolutePath = oneLine(item.absolutePath ?? "")
    guard !absolutePath.isEmpty else {
        return nil
    }

    let homePath = NSHomeDirectory()
    if absolutePath.hasPrefix(homePath + "/") {
        return "~" + String(absolutePath.dropFirst(homePath.count))
    }
    return absolutePath
}

func fallbackAttachmentNames(_ names: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []

    for rawName in names {
        let decodedName = rawName.removingPercentEncoding ?? rawName
        let normalizedName = oneLine(decodedName)
        guard !normalizedName.isEmpty else {
            continue
        }
        if seen.insert(normalizedName).inserted {
            result.append(normalizedName)
        }
    }

    return result
}

func splitDisplayChunks(_ text: String) -> [String] {
    let normalized = oneLine(text)
    guard !normalized.isEmpty else {
        return []
    }

    let pattern = #"(?<=[.!?])\s+|(?<=다\.)\s+|(?<=요\.)\s+"#
    let regex = try? NSRegularExpression(pattern: pattern, options: [])
    let range = NSRange(location: 0, length: nsLength(normalized))
    let matches = regex?.matches(in: normalized, options: [], range: range) ?? []

    if matches.isEmpty {
        return [normalized]
    }

    var pieces: [String] = []
    var cursor = 0
    let nsText = normalized as NSString
    for match in matches {
        let sentenceRange = NSRange(location: cursor, length: match.range.location - cursor)
        let sentence = nsText.substring(with: sentenceRange).trimmingCharacters(in: .whitespacesAndNewlines)
        if !sentence.isEmpty {
            pieces.append(sentence)
        }
        cursor = match.range.location + match.range.length
    }
    let tail = nsText.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty {
        pieces.append(tail)
    }

    if pieces.count < 2 {
        return [normalized]
    }

    var chunks: [String] = []
    var current: [String] = []
    var currentLength = 0

    for piece in pieces {
        let extra = piece.count + (current.isEmpty ? 0 : 1)
        if !current.isEmpty && (currentLength + extra > 180 || current.count >= 2) {
            chunks.append(current.joined(separator: " "))
            current = [piece]
            currentLength = piece.count
            continue
        }
        current.append(piece)
        currentLength += extra
    }

    if !current.isEmpty {
        chunks.append(current.joined(separator: " "))
    }

    return chunks
}

func displayParagraphs(_ notice: NoticeDigestEntry) -> [String] {
    let bodyText = String(notice.bodyText ?? "")
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(
            of: #"(?im)^\s*-{20,}\s*$"#,
            with: "----------",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"(?i)\((\d+)\s*\n\s*-\s*(\d+[^)]*)\)"#,
            with: "($1-$2)",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"(?i)(Time:\s*[^\n]+)\n{2,}-\s+(\d{1,2}:\d{2}\s*(?:am|pm)?)"#,
            with: "$1 - $2",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\s+(?=#{1,6}\s+)"#, with: "\n\n", options: .regularExpression)
        .replacingOccurrences(
            of: #"\s+(?=(?:[1-9]|1\d|20)\.\s+[A-Z가-힣])"#,
            with: "\n\n",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"(?<!## )\s+(?=(?:Requirements|Best regards|Thank you|감사합니다|문의|클레임은|Original date|Original due date|New date|New due date|VPN 접속 링크|VPN 메뉴얼|KiteBoard 링크|Nano Quiz Link|Link:)\b)"#,
            with: "\n\n",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\s+(?=(?:Date(?:\s*&\s*Time)?|Time|Location|Place|Venue|Room|Range|Coverage|Exam\s*Range)\s*:)"#,
            with: "\n\n",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(
            of: #"(?i)\b(Original\s+due|New\s+due|Original|New|Due)\n\n(date\s*:)"#,
            with: "$1 $2",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\s+(?=[•⦁]\s*)"#,
            with: "\n\n",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\s+(?=-{20,})"#,
            with: "\n\n",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    let paragraphs = bodyText
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

    var grouped: [String] = []
    var current: [String] = []

    func flush() {
        guard !current.isEmpty else { return }
        let joined = current.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            grouped.append(joined)
        }
        current.removeAll(keepingCapacity: true)
    }

    for line in paragraphs {
        if line.isEmpty {
            flush()
            continue
        }
        current.append(line)
    }
    flush()

    if grouped.isEmpty {
        let fallback = truncated(notice.summary ?? "", maxLength: 400)
        return fallback.isEmpty ? [] : [fallback]
    }

    var expanded: [String] = []
    for paragraph in grouped {
        if paragraph.count >= 180 {
            expanded.append(contentsOf: splitDisplayChunks(paragraph))
        } else {
            expanded.append(paragraph)
        }
    }
    return expanded
}

func lineEntries(in text: String) -> [(range: LineRange, text: String)] {
    let nsText = text as NSString
    var result: [(range: LineRange, text: String)] = []
    var cursor = 0

    while cursor <= nsText.length {
        let searchRange = NSRange(location: cursor, length: max(0, nsText.length - cursor))
        let newlineRange = nsText.range(of: "\n", options: [], range: searchRange)
        let lineEnd = newlineRange.location == NSNotFound ? nsText.length : newlineRange.location
        let lineRange = NSRange(location: cursor, length: max(0, lineEnd - cursor))
        let textRange = LineRange(location: lineRange.location, length: lineRange.length)
        result.append((textRange, nsText.substring(with: lineRange)))
        if newlineRange.location == NSNotFound {
            break
        }
        cursor = newlineRange.location + newlineRange.length
    }

    return result
}

func lineLabel(_ text: String) -> String {
    oneLine(text).trimmingCharacters(in: .whitespacesAndNewlines)
}

func lineRange(
    start: Int,
    endExclusive: Int
) -> LineRange? {
    guard start >= 0, endExclusive >= start else {
        return nil
    }
    return LineRange(location: start, length: endExclusive - start)
}

func containsLineStart(
    searchRange: LineRange,
    lineRange: LineRange
) -> Bool {
    let searchEnd = searchRange.location + searchRange.length
    return lineRange.location >= searchRange.location && lineRange.location < searchEnd
}

func resolvedNoticeTitleRanges(
    currentText: String,
    titles: [String]
) -> [LineRange?] {
    var titleCursor = 0
    return titles.map { title in
        findNoticeTitleRange(
            currentText: currentText,
            title: title,
            cursor: &titleCursor
        )
    }
}

func noticeBlockSearchRange(
    titleRanges: [LineRange?],
    noticeIndex: Int,
    textLength: Int
) -> LineRange? {
    guard noticeIndex >= 0, noticeIndex < titleRanges.count,
          let titleRange = titleRanges[noticeIndex] else {
        return nil
    }

    let start = titleRange.location + titleRange.length
    let nextTitleStart = titleRanges
        .dropFirst(noticeIndex + 1)
        .compactMap { $0?.location }
        .first ?? textLength
    return lineRange(start: start, endExclusive: nextTitleStart)
}

func checklistRangeInNoticeBlock(
    currentText: String,
    searchRange: LineRange,
    label: String
) -> LineRange? {
    for entry in lineEntries(in: currentText) {
        guard containsLineStart(searchRange: searchRange, lineRange: entry.range) else {
            continue
        }
        if checklistLineMatchesLabel(lineLabel(entry.text), expectedLabel: label) {
            return entry.range
        }
    }
    return nil
}

func renderChunks(from lines: [RenderLine]) -> [RenderChunk] {
    guard let first = lines.first else {
        return []
    }

    var chunks: [RenderChunk] = []
    var currentLines = [first.text]
    var currentIsChecklist = first.isChecklist

    for line in lines.dropFirst() {
        if line.isChecklist == currentIsChecklist && !currentIsChecklist {
            currentLines.append(line.text)
            continue
        }
        chunks.append(RenderChunk(text: currentLines.joined(separator: "\n"), isChecklist: currentIsChecklist))
        currentLines = [line.text]
        currentIsChecklist = line.isChecklist
    }

    chunks.append(RenderChunk(text: currentLines.joined(separator: "\n"), isChecklist: currentIsChecklist))
    return chunks
}

func paragraphSelectionRange(
    in currentText: String,
    lineRange: LineRange
) -> LineRange {
    let nsText = currentText as NSString
    let upperBound = lineRange.location + lineRange.length
    guard upperBound >= 0, upperBound <= nsText.length else {
        return lineRange
    }
    guard upperBound < nsText.length else {
        return lineRange
    }
    let trailingCharacter = nsText.substring(with: NSRange(location: upperBound, length: 1))
    guard trailingCharacter == "\n" else {
        return lineRange
    }
    return LineRange(location: lineRange.location, length: lineRange.length + 1)
}

func uniqueLineRanges(_ ranges: [LineRange]) -> [LineRange] {
    var seen = Set<String>()
    var unique: [LineRange] = []
    unique.reserveCapacity(ranges.count)
    for range in ranges {
        let key = "\(range.location):\(range.length)"
        guard seen.insert(key).inserted else {
            continue
        }
        unique.append(range)
    }
    return unique
}

func resolvedPlanLineRanges(
    currentText: String,
    bodyLines: [RenderLine]
) -> [LineRange]? {
    let entries = lineEntries(in: currentText)
    var resolved: [LineRange] = []
    resolved.reserveCapacity(bodyLines.count)

    var searchIndex = 0
    for line in bodyLines {
        var matchedRange: LineRange?
        while searchIndex < entries.count {
            let candidate = entries[searchIndex]
            searchIndex += 1
            if canonicalText(candidate.text) == canonicalText(line.text) {
                matchedRange = candidate.range
                break
            }
        }
        guard let matchedRange else {
            return nil
        }
        resolved.append(matchedRange)
    }

    return resolved
}

func noticeIdentifier(course: String, notice: NoticeDigestEntry) -> String {
    let url = String(notice.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !url.isEmpty {
        return url
    }
    let articleId = String(notice.articleId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !articleId.isEmpty {
        return "article:\(articleId)"
    }
    return "\(course)|\(oneLine(notice.title))|\(oneLine(notice.postedAt ?? ""))"
}

func boolValue(_ value: Bool?) -> Bool {
    value ?? false
}

func loadDigest(path: String) -> NoticeDigest {
    let url = URL(fileURLWithPath: path)
    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(NoticeDigest.self, from: data)
    } catch {
        fail("Failed to read notice digest: \(error)")
    }
}

func loadOptionalJSON<T: Decodable>(_ type: T.Type, path: String) -> T? {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }

    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        return nil
    }
}

func writeJSON<T: Encodable>(_ value: T, path: String) {
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    } catch {
        fail("Failed to write JSON at \(path): \(error)")
    }
}

func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success, let value else {
        return nil
    }
    return value as? T
}

func setAttr(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) {
    let error = AXUIElementSetAttributeValue(element, name as CFString, value)
    if error != .success {
        fail("Failed to set accessibility attribute \(name): \(error.rawValue)")
    }
}

func findFirst(_ element: AXUIElement, role targetRole: String) -> AXUIElement? {
    let role: String = attr(element, kAXRoleAttribute) ?? ""
    if role == targetRole {
        return element
    }
    let children: [AXUIElement] = attr(element, kAXChildrenAttribute) ?? []
    for child in children {
        if let found = findFirst(child, role: targetRole) {
            return found
        }
    }
    return nil
}

func findFirst(_ element: AXUIElement, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(element) {
        return element
    }

    let children: [AXUIElement] = attr(element, kAXChildrenAttribute) ?? []
    for child in children {
        if let found = findFirst(child, where: predicate) {
            return found
        }
    }
    return nil
}

func collectElements(_ element: AXUIElement, where predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    var matches: [AXUIElement] = []
    if predicate(element) {
        matches.append(element)
    }

    let children: [AXUIElement] = attr(element, kAXChildrenAttribute) ?? []
    for child in children {
        matches.append(contentsOf: collectElements(child, where: predicate))
    }

    return matches
}

func checklistToolbarButton(in element: AXUIElement) -> AXUIElement? {
    findFirst(element) { element in
        let role: String = attr(element, kAXRoleAttribute) ?? ""
        let description: String = attr(element, kAXDescriptionAttribute) ?? ""
        let title: String = attr(element, kAXTitleAttribute) ?? ""
        let normalized = "\(description) \(title)"
        return role == kAXButtonRole as String && normalized.contains("체크리스트")
    }
}

func findMenuItem(named target: String, in element: AXUIElement) -> AXUIElement? {
    if let title: String = attr(element, kAXTitleAttribute), title == target {
        let role: String = attr(element, kAXRoleAttribute) ?? ""
        if role == kAXMenuItemRole as String {
            return element
        }
    }

    let children: [AXUIElement] = attr(element, kAXChildrenAttribute) ?? []
    for child in children {
        if let found = findMenuItem(named: target, in: child) {
            return found
        }
    }
    return nil
}

func findMenuItem(containing target: String, in element: AXUIElement) -> AXUIElement? {
    if let title: String = attr(element, kAXTitleAttribute), title.contains(target) {
        let role: String = attr(element, kAXRoleAttribute) ?? ""
        if role == kAXMenuItemRole as String {
            return element
        }
    }

    let children: [AXUIElement] = attr(element, kAXChildrenAttribute) ?? []
    for child in children {
        if let found = findMenuItem(containing: target, in: child) {
            return found
        }
    }
    return nil
}

func menuItem(_ app: AXUIElement, _ titles: [String]) -> (title: String, item: AXUIElement)? {
    guard let menuBar: AXUIElement = attr(app, kAXMenuBarAttribute) else {
        fail("Could not locate Notes menu bar.")
    }

    var matchedTitle: String?
    var matchedItem: AXUIElement?
    for title in titles {
        if let exact = findMenuItem(named: title, in: menuBar) {
            matchedTitle = title
            matchedItem = exact
            break
        }
    }
    if matchedItem == nil {
        for title in titles {
            if let fuzzy = findMenuItem(containing: title, in: menuBar) {
                matchedTitle = title
                matchedItem = fuzzy
                break
            }
        }
    }

    guard let menuItem = matchedItem, let matchedTitle else {
        return nil
    }

    return (matchedTitle, menuItem)
}

func menuItemMarkChar(_ app: AXUIElement, _ titles: [String]) -> String? {
    guard let resolved = menuItem(app, titles) else {
        return nil
    }
    let markChar: String? = attr(resolved.item, kAXMenuItemMarkCharAttribute)
    guard let markChar else {
        return nil
    }
    let normalized = markChar.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}

@discardableResult
func pressMenuIfAvailable(_ app: AXUIElement, _ titles: [String]) -> Bool {
    guard let resolved = menuItem(app, titles) else {
        return false
    }

    let enabled: Bool = attr(resolved.item, kAXEnabledAttribute) ?? true
    guard enabled else {
        return false
    }

    let error = AXUIElementPerformAction(resolved.item, kAXPressAction as CFString)
    return error == .success
}

func pressMenu(_ app: AXUIElement, _ titles: [String]) {
    guard let resolved = menuItem(app, titles) else {
        fail("Could not find Notes menu item: \(titles.joined(separator: ", "))")
    }

    let error = AXUIElementPerformAction(resolved.item, kAXPressAction as CFString)
    if error != .success {
        fail("Failed to press Notes menu item \(resolved.title): \(error.rawValue)")
    }
}

@discardableResult
func selectRange(_ textArea: AXUIElement, location: Int, length: Int) -> Bool {
    guard length > 0 else {
        return false
    }
    var range = CFRange(location: location, length: length)
    guard let axRange = AXValueCreate(.cfRange, &range) else {
        return false
    }
    _ = AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let error = AXUIElementSetAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, axRange)
    return error == .success
}

@discardableResult
func placeCaret(_ textArea: AXUIElement, location: Int) -> Bool {
    guard location >= 0 else {
        return false
    }
    var range = CFRange(location: location, length: 0)
    guard let axRange = AXValueCreate(.cfRange, &range) else {
        return false
    }
    _ = AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let error = AXUIElementSetAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, axRange)
    return error == .success
}

func selectedRange(_ textArea: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, &value)
    guard error == .success, let value else {
        return nil
    }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cfRange else {
        return nil
    }
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else {
        return nil
    }
    return range
}

func rangeMatches(_ selected: CFRange?, _ range: LineRange) -> Bool {
    guard let selected else {
        return false
    }
    return selected.location == range.location && selected.length == range.length
}

@discardableResult
func selectRangeForFormatting(
    context: NotesEditorContext,
    range: LineRange,
    noteTitle: String,
    noteID: String?,
    retries: Int = 4
) -> Bool {
    guard range.length > 0 else {
        return false
    }

    for attempt in 0..<retries {
        if attempt == 0 {
            _ = AXUIElementSetAttributeValue(context.textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        } else {
            ensureTypingTargetReady(context: context, noteTitle: noteTitle, noteID: noteID)
        }
        if selectRange(context.textArea, location: range.location, length: range.length) {
            Thread.sleep(forTimeInterval: 0.035)
            if rangeMatches(selectedRange(context.textArea), range) {
                return true
            }
        }
        if attempt < retries - 1 {
            Thread.sleep(forTimeInterval: 0.06)
        }
    }

    return false
}

@discardableResult
func ensureEditableCaret(_ textArea: AXUIElement) -> Bool {
    let currentText: String = attr(textArea, kAXValueAttribute) ?? ""
    let textLength = nsLength(currentText)
    let currentRange = selectedRange(textArea) ?? CFRange(location: 0, length: 0)
    let clampedLocation = min(max(0, currentRange.location), textLength)
    return placeCaret(textArea, location: clampedLocation)
}

func cfRangeValue(_ range: LineRange) -> AXValue {
    var raw = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &raw) else {
        fail("Failed to create accessibility range value.")
    }
    return value
}

func htmlEscaped(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func cssFontSize(_ fontSize: CGFloat) -> String {
    let value = Double(fontSize)
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.1f", value)
}

func htmlStyle(for line: RenderLine) -> String {
    let fontWeight = line.isBold ? "700" : "400"
    return "font-size:\(cssFontSize(line.fontSize))pt;font-weight:\(fontWeight);line-height:1.42;"
}

func paste(_ app: AXUIElement, text: String, html: String? = nil, attributedText: NSAttributedString? = nil) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    if let html {
        pasteboard.setString(html, forType: .html)
    }
    if let attributedText,
       let rtf = try? attributedText.data(
           from: NSRange(location: 0, length: attributedText.length),
           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
       ) {
        pasteboard.setData(rtf, forType: .rtf)
    }
    usleep(pasteboardSettleUsec)
    pressMenu(app, ["붙여넣기", "Paste"])
    usleep(pasteSettleUsec)
}

func sendReturnKey(context: NotesEditorContext) {
    if let notesPID = runningNotesPID() {
        activateApplication(pid: notesPID)
    }
    _ = AXUIElementSetAttributeValue(context.textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    _ = ensureEditableCaret(context.textArea)
    let initialText: String = attr(context.textArea, kAXValueAttribute) ?? ""
    let initialLineCount = lineEntries(in: initialText).count
    let initialLength = nsLength(initialText)
    let initialRange = selectedRange(context.textArea)
    usleep(80_000)
    guard let source = CGEventSource(stateID: .hidSystemState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
        fail("Failed to synthesize Return key event.")
    }
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    for _ in 0..<20 {
        let updatedText: String = attr(context.textArea, kAXValueAttribute) ?? ""
        let updatedLineCount = lineEntries(in: updatedText).count
        let updatedLength = nsLength(updatedText)
        if let updatedRange = selectedRange(context.textArea),
           (updatedRange.location != initialRange?.location || updatedRange.length != initialRange?.length),
           updatedLineCount > initialLineCount,
           updatedLength > initialLength {
            usleep(40_000)
            return
        }
        usleep(35_000)
    }
    usleep(180_000)
}

func sendCommandKey(_ virtualKey: CGKeyCode, targetPID: pid_t? = nil) {
    if let targetPID {
        activateApplication(pid: targetPID)
        usleep(40_000)
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
        fail("Failed to synthesize Command key event.")
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    usleep(pasteSettleUsec)
}

func checklistModeEnabled(_ button: AXUIElement) -> Bool {
    let rawValue: String = attr(button, kAXValueAttribute) ?? ""
    let normalized = rawValue.lowercased()
    return normalized.contains("켬")
        || normalized.contains("on")
        || normalized.contains("true")
        || normalized == "1"
}

func checklistMenuModeEnabled(_ app: AXUIElement) -> Bool? {
    guard let markChar = menuItemMarkChar(app, checklistMenuTitles) else {
        if menuItem(app, checklistMenuTitles) == nil {
            return nil
        }
        return false
    }
    return !markChar.isEmpty
}

func resolvedChecklistButton(for context: NotesEditorContext) -> AXUIElement? {
    context.checklistButton
}

func waitForChecklistMode(
    _ button: AXUIElement,
    enabled: Bool,
    retries: Int = 18,
    retryDelayUsec: useconds_t = 25_000
) -> Bool {
    for _ in 0..<retries {
        if checklistModeEnabled(button) == enabled {
            return true
        }
        usleep(retryDelayUsec)
    }
    return false
}

func setChecklistMode(_ context: NotesEditorContext, enabled: Bool) {
    if var button = resolvedChecklistButton(for: context) {
        if waitForChecklistMode(button, enabled: enabled, retries: 1) {
            return
        }

        var lastError = AXError.success
        for attempt in 0..<3 {
            lastError = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if lastError == .success && waitForChecklistMode(button, enabled: enabled) {
                return
            }
            if attempt < 2 {
                button =
                    checklistToolbarButton(in: context.window)
                    ?? checklistToolbarButton(in: context.app)
                    ?? button
            }
        }

        fail("Failed to toggle checklist mode: \(lastError.rawValue)")
    }

    if let currentState = checklistMenuModeEnabled(context.app), currentState == enabled {
        return
    }

    for _ in 0..<3 {
        guard pressMenuIfAvailable(context.app, checklistMenuTitles) else {
            break
        }
        usleep(pasteSettleUsec)
        if let currentState = checklistMenuModeEnabled(context.app), currentState == enabled {
            return
        }
    }

    fail("Failed to toggle checklist mode: checklist control unavailable")
}

struct ProcessOutputResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

func preferredProcessOutput(stdout: String, stderr: String) -> String {
    if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return stdout
    }
    if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return stderr
    }
    return ""
}

func logProcessFailure(_ result: ProcessOutputResult) {
    automationDebugLog("failure status=\(result.status)")
    if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        automationDebugLog("stderr=\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        automationDebugLog("stdout=\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

func runProcessResult(_ launchPath: String, _ arguments: [String]) -> ProcessOutputResult {
    automationDebugLog("run: \(launchPath) \(arguments.joined(separator: " "))")
    let timingLabel = processTimingLabel(launchPath, arguments)
    let started = DispatchTime.now()
    timingLog("process_start \(timingLabel)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let outputDirectory = FileManager.default.temporaryDirectory
    let outputID = UUID().uuidString
    let stdoutURL = outputDirectory.appendingPathComponent("klms-notice-\(outputID)-stdout.txt")
    let stderrURL = outputDirectory.appendingPathComponent("klms-notice-\(outputID)-stderr.txt")
    _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
          let stderrHandle = try? FileHandle(forWritingTo: stderrURL)
    else {
        fail("Failed to create temporary process output files.")
    }
    defer {
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
    }

    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        stdoutHandle.closeFile()
        stderrHandle.closeFile()
        fail("Failed to launch \(launchPath): \(error)")
    }

    stdoutHandle.closeFile()
    stderrHandle.closeFile()
    let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
    let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
    timingLog("process_finish \(timingLabel) status=\(process.terminationStatus) duration_ms=\(elapsed / 1_000_000)")

    return ProcessOutputResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

@discardableResult
func runProcessOutput(_ launchPath: String, _ arguments: [String]) -> String {
    let result = runProcessResult(launchPath, arguments)

    if result.status != 0 {
        let message = [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        logProcessFailure(result)
        fail(message ?? "Command failed: \(launchPath) \(arguments.joined(separator: " "))")
    }

    return preferredProcessOutput(stdout: result.stdout, stderr: result.stderr)
}

@discardableResult
func runProcessOutputIfSuccessful(_ launchPath: String, _ arguments: [String]) -> String? {
    let result = runProcessResult(launchPath, arguments)
    guard result.status == 0 else {
        logProcessFailure(result)
        return nil
    }
    return preferredProcessOutput(stdout: result.stdout, stderr: result.stderr)
}

func processTimingLabel(_ launchPath: String, _ arguments: [String]) -> String {
    var summarized: [String] = []
    var skipNext = false
    for argument in arguments {
        if skipNext {
            summarized.append("<script>")
            skipNext = false
            continue
        }
        summarized.append(argument)
        if argument == "-e" {
            skipNext = true
        }
    }
    let joined = summarized.joined(separator: " ")
    return joined.isEmpty ? launchPath : "\(launchPath) \(joined)"
}

func runProcess(_ launchPath: String, _ arguments: [String]) {
    _ = runProcessOutput(launchPath, arguments)
}

@discardableResult
func runAppleScript(_ script: String) -> String {
    runProcessOutput("/usr/bin/osascript", ["-e", script])
}

@discardableResult
func runAppleScriptIfSuccessful(_ script: String) -> String? {
    runProcessOutputIfSuccessful("/usr/bin/osascript", ["-e", script])
}

@discardableResult
func focusNotesEditorViaSystemEvents() -> Bool {
    let script = """
tell application "System Events"
  tell process "Notes"
    set frontmost to true
    repeat with w in windows
      try
        set ta to text area 1 of scroll area 3 of splitter group 1 of w
        set value of attribute "AXFocused" of ta to true
        return "true"
      end try
    end repeat
  end tell
end tell
return "false"
"""
    guard let output = runAppleScriptIfSuccessful(script)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return false
    }
    return output == "true"
}

func jsStringLiteral(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [text], options: [])
    let encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
    return String(encoded.dropFirst().dropLast())
}

func appleScriptStringLiteral(_ text: String) -> String {
    "\""
        + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        + "\""
}

func selectedNoteIDs() -> [String] {
    let script = """
const notes = Application("/System/Applications/Notes.app");
let selectionItems = [];
try {
  selectionItems = notes.selection();
} catch (error) {}

const result = [];
if (selectionItems) {
  if (typeof selectionItems.length === "number") {
    for (let i = 0; i < selectionItems.length; i += 1) {
      try {
        result.push(String(selectionItems[i].id()));
      } catch (error) {}
    }
  } else {
    try {
      result.push(String(selectionItems.id()));
    } catch (error) {}
  }
}

console.log(result.join("\\n"));
"""

    let output = runProcessOutput("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
    return output
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

func waitForSelectedNote(
    noteID: String,
    retries: Int = 40,
    retryDelay: TimeInterval = 0.2
) -> Bool {
    let normalizedNoteID = noteID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedNoteID.isEmpty else {
        return false
    }

    for _ in 0..<retries {
        if selectedNoteIDs().contains(normalizedNoteID) {
            return true
        }
        Thread.sleep(forTimeInterval: retryDelay)
    }

    return false
}

func waitForVisibleNoteByAnchors(
    noteTitle: String,
    noteID: String,
    retries: Int = 6,
    retryDelay: TimeInterval = 0.1
) -> Bool {
    let anchors = noteAnchorTexts(noteTitle: noteTitle, noteID: noteID)
    guard !anchors.isEmpty else {
        return waitForSelectedNote(noteID: noteID, retries: 3, retryDelay: 0.05)
    }

    let notesPID = runningNotesPID()
    for _ in 0..<retries {
        if attemptResolveNotesEditorContext(
            notesPID: notesPID,
            expectedNoteID: noteID,
            expectedAnchorTexts: anchors,
            retries: 1,
            retryDelay: 0.0
        ) != nil {
            return true
        }
        Thread.sleep(forTimeInterval: retryDelay)
    }

    return waitForSelectedNote(noteID: noteID, retries: 3, retryDelay: 0.05)
}

func noteSnapshot(noteID: String) -> NoteSnapshot? {
    timed("noteSnapshot") {
        let noteLiteral = jsStringLiteral(noteID)
        let script = """
const noteId = \(noteLiteral);
const notes = Application("/System/Applications/Notes.app");
try {
  const note = notes.notes.byId(noteId);
  if (String(note.id() || "") === noteId) {
    console.log(JSON.stringify({
      id: noteId,
      name: String(note.name() || ""),
      plaintext: String(note.plaintext() || "")
    }));
  }
} catch (error) {
}
"""

        let output = runProcessOutput("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, let data = output.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(NoteSnapshot.self, from: data)
    }
}

func noteBodyHTMLByAppleScript(noteTitle: String) -> String? {
    timed("noteBodyHTML applescript title=\(noteTitle)") {
        let noteLiteral = appleScriptStringLiteral(noteTitle)
        let script = """
tell application "Notes"
  try
    return body of note \(noteLiteral)
  on error
    return ""
  end try
end tell
"""
        let output = runAppleScriptIfSuccessful(script) ?? ""
        return output.isEmpty ? nil : output
    }
}

func noteAnchorTexts(noteTitle: String, noteID: String?) -> [String] {
    var anchors: [String] = []

    let titleAnchor = truncated(noteTitle, maxLength: 160)
    if !titleAnchor.isEmpty {
        anchors.append(titleAnchor)
    }

    guard let noteID, let snapshot = noteSnapshot(noteID: noteID) else {
        return anchors
    }

    let snapshotName = truncated(snapshot.name, maxLength: 160)
    if !snapshotName.isEmpty, !anchors.contains(snapshotName) {
        anchors.append(snapshotName)
    }

    let lines = snapshot.plaintext
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n")
        .map { truncated(String($0), maxLength: 200) }
        .filter { !$0.isEmpty }

    for line in lines {
        if !anchors.contains(line) {
            anchors.append(line)
        }
        if anchors.count >= 5 {
            break
        }
    }

    return anchors
}

func elementPID(_ element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    let error = AXUIElementGetPid(element, &pid)
    guard error == .success else {
        return nil
    }
    return pid
}

func sameAXElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
    CFEqual(lhs, rhs)
}

func ancestorAXElement(
    _ element: AXUIElement,
    matching predicate: (AXUIElement) -> Bool,
    maxDepth: Int = 24
) -> AXUIElement? {
    if predicate(element) {
        return element
    }

    var current: AXUIElement? = element
    for _ in 0..<maxDepth {
        guard let node = current else {
            return nil
        }
        guard let parent: AXUIElement = attr(node, kAXParentAttribute) else {
            return nil
        }
        if predicate(parent) {
            return parent
        }
        current = parent
    }

    return nil
}

func isDescendantAXElement(
    _ element: AXUIElement,
    of ancestor: AXUIElement,
    maxDepth: Int = 24
) -> Bool {
    if sameAXElement(element, ancestor) {
        return true
    }

    var current: AXUIElement? = element
    for _ in 0..<maxDepth {
        guard let node = current else {
            return false
        }
        guard let parent: AXUIElement = attr(node, kAXParentAttribute) else {
            return false
        }
        if sameAXElement(parent, ancestor) {
            return true
        }
        current = parent
    }

    return false
}

func isEditableTextArea(_ element: AXUIElement) -> Bool {
    let role: String = attr(element, kAXRoleAttribute) ?? ""
    guard role == kAXTextAreaRole as String else {
        return false
    }

    let enabled: Bool = attr(element, kAXEnabledAttribute) ?? true
    guard enabled else {
        return false
    }

    let editable: Bool? = attr(element, "AXEditable")
    return editable ?? true
}

func candidateTextAreas(in window: AXUIElement, focusedElement: AXUIElement?) -> [AXUIElement] {
    var candidates: [AXUIElement] = []
    var seen: Set<String> = []

    func appendCandidate(_ element: AXUIElement?) {
        guard let element else {
            return
        }
        let key = "\(Unmanaged.passUnretained(element).toOpaque())"
        guard seen.insert(key).inserted else {
            return
        }
        candidates.append(element)
    }

    if let focusedElement {
        let focusedTextArea = ancestorAXElement(focusedElement, matching: isEditableTextArea)
        if let focusedTextArea, isDescendantAXElement(focusedTextArea, of: window) {
            appendCandidate(focusedTextArea)
        }
    }

    for textArea in collectElements(window, where: isEditableTextArea) {
        appendCandidate(textArea)
    }

    return candidates
}

var lastFrontmostActivationAtByPID: [pid_t: Date] = [:]

func activateApplication(pid: pid_t?) {
    guard let pid else {
        return
    }
    let app = NSRunningApplication(processIdentifier: pid)
    let wasActive = app?.isActive ?? false
    _ = app?.activate(options: [.activateAllWindows])
    guard !wasActive else {
        return
    }
    let now = Date()
    if let lastActivationAt = lastFrontmostActivationAtByPID[pid],
       now.timeIntervalSince(lastActivationAt) < 0.35 {
        return
    }
    lastFrontmostActivationAtByPID[pid] = now
    let script = """
tell application "System Events"
  try
    set frontmost of first process whose unix id is \(pid) to true
  end try
end tell
"""
    _ = runAppleScriptIfSuccessful(script)
}

func runningNotesPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")
        .first?
        .processIdentifier
}

var knownExistingNoteIDs: Set<String> = []

func normalizedNoteID(_ noteID: String?) -> String? {
    guard let noteID else {
        return nil
    }
    let trimmed = noteID.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func noteExists(noteID: String) -> Bool {
    timed("noteExists") {
        let noteLiteral = jsStringLiteral(noteID)
        let script = """
const noteId = \(noteLiteral);
const notes = Application("/System/Applications/Notes.app");
try {
  const note = notes.notes.byId(noteId);
  console.log(String(note.id() || "") === noteId ? "true" : "false");
} catch (error) {
  console.log("false");
}
"""

        let output = runProcessOutput("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "true"
    }
}

func matchesExpectedAnchors(_ currentText: String, anchors: [String]) -> Bool {
    guard !anchors.isEmpty else {
        return true
    }

    let normalizedCurrentText = oneLine(currentText)
    return anchors.contains { anchor in
        let normalizedAnchor = oneLine(anchor)
        guard normalizedAnchor.count >= 2 else {
            return false
        }
        return normalizedCurrentText.contains(normalizedAnchor)
    }
}

func typingTargetLooksReady(
    context: NotesEditorContext,
    systemWide: AXUIElement,
    notesPID: pid_t?
) -> Bool {
    if let focusedApp: AXUIElement = attr(systemWide, kAXFocusedApplicationAttribute),
       let focusedPID = elementPID(focusedApp),
       let notesPID,
       focusedPID != notesPID {
        return false
    }

    let currentText: String = attr(context.textArea, kAXValueAttribute) ?? ""
    let anchorsMatch =
        oneLine(currentText).isEmpty
        || matchesExpectedAnchors(currentText, anchors: context.anchorTexts)
    guard anchorsMatch else {
        return false
    }

    let textAreaFocused: Bool = attr(context.textArea, kAXFocusedAttribute) ?? false
    if let focusedElement: AXUIElement = attr(systemWide, kAXFocusedUIElementAttribute) {
        return isDescendantAXElement(focusedElement, of: context.textArea)
    }
    return textAreaFocused
}

func ensureTypingTargetReady(
    context: NotesEditorContext,
    noteTitle: String,
    noteID: String?
) {
    let resolvedNoteID = context.noteID ?? existingNoteID(noteTitle: noteTitle, noteID: noteID)
    let systemWide = AXUIElementCreateSystemWide()
    let notesPID = elementPID(context.app)

    if typingTargetLooksReady(context: context, systemWide: systemWide, notesPID: notesPID) {
        return
    }

    activateApplication(pid: notesPID)
    Thread.sleep(forTimeInterval: 0.02)

    if let focusedApp: AXUIElement = attr(systemWide, kAXFocusedApplicationAttribute),
       let focusedPID = elementPID(focusedApp),
       let notesPID,
       focusedPID != notesPID {
        _ = focusNotesEditorViaSystemEvents()
        Thread.sleep(forTimeInterval: 0.03)
    }

    if let focusedApp: AXUIElement = attr(systemWide, kAXFocusedApplicationAttribute),
       let focusedPID = elementPID(focusedApp),
       let notesPID,
       focusedPID != notesPID {
        if let resolvedNoteID, !selectedNoteIDs().contains(resolvedNoteID) {
            fail("Notes selection moved away from the target note before typing: \(noteTitle)")
        }
        fail("Typing target is not Notes. Refusing to type outside the target note: \(noteTitle)")
    }

    var caretReady = false
    for attempt in 0..<6 {
        activateApplication(pid: notesPID)
        _ = focusNotesEditorViaSystemEvents()
        _ = AXUIElementSetAttributeValue(context.textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if ensureEditableCaret(context.textArea) {
            caretReady = true
            break
        }
        if attempt < 5 {
            Thread.sleep(forTimeInterval: 0.08)
        }
    }
    guard caretReady else {
        fail("Could not place the cursor in the target Notes editor before typing: \(noteTitle)")
    }

    let textAreaFocused: Bool = attr(context.textArea, kAXFocusedAttribute) ?? false
    guard textAreaFocused else {
        fail("Notes editor lost focus before typing: \(noteTitle)")
    }

    if let focusedElement: AXUIElement = attr(systemWide, kAXFocusedUIElementAttribute),
       !isDescendantAXElement(focusedElement, of: context.textArea) {
        _ = focusNotesEditorViaSystemEvents()
        Thread.sleep(forTimeInterval: 0.03)
    }

    if let focusedElement: AXUIElement = attr(systemWide, kAXFocusedUIElementAttribute) {
        guard isDescendantAXElement(focusedElement, of: context.textArea) else {
            if let resolvedNoteID, !selectedNoteIDs().contains(resolvedNoteID) {
                fail("Notes selection moved away from the target note before typing: \(noteTitle)")
            }
            fail("Focused UI element is not inside the target Notes editor before typing: \(noteTitle)")
        }
    }

    let currentText: String = attr(context.textArea, kAXValueAttribute) ?? ""
    if !oneLine(currentText).isEmpty && !matchesExpectedAnchors(currentText, anchors: context.anchorTexts) {
        if let resolvedNoteID, !selectedNoteIDs().contains(resolvedNoteID) {
            fail("Notes selection moved away from the target note before typing: \(noteTitle)")
        }
        automationDebugLog("Proceeding despite anchor mismatch because the selected note id is still \(resolvedNoteID ?? "unknown")")
    }
}

func noteIDs(matching noteTitle: String) -> [String] {
    timed("noteIDs title=\(noteTitle)") {
        let noteLiteral = jsStringLiteral(noteTitle)
        let script = """
function noteModifiedAt(note) {
  try {
    const raw = note.modificationDate();
    const time = new Date(raw).getTime();
    return Number.isFinite(time) ? time : 0;
  } catch (error) {
    return 0;
  }
}

const noteName = \(noteLiteral);
const normalizedNoteName = String(noteName || "").normalize("NFC");
const notes = Application("/System/Applications/Notes.app");
const matches = [];
const allNotes = notes.notes();
for (let i = 0; i < allNotes.length; i += 1) {
  try {
    if (String(allNotes[i].name() || "").normalize("NFC") === normalizedNoteName) {
      matches.push({ id: String(allNotes[i].id()), modifiedAt: noteModifiedAt(allNotes[i]) });
    }
  } catch (error) {}
}
matches.sort((left, right) => right.modifiedAt - left.modifiedAt);
console.log(matches.map(item => item.id).join("\\n"));
"""

        let output = runProcessOutput("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
        let ids = output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for id in ids {
            knownExistingNoteIDs.insert(id)
        }
        return ids
    }
}

func createNote(noteTitle: String) {
    automationDebugLog("createNote(\(noteTitle))")
    let noteLiteral = jsStringLiteral(noteTitle)
    let script = """
function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function resolveTargetFolder(notesApp) {
  const folders = notesApp.folders();
  for (let i = 0; i < folders.length; i += 1) {
    try {
      if (String(folders[i].name() || "") === "Notes") {
        return folders[i];
      }
    } catch (error) {}
  }
  if (folders.length > 0) {
    return folders[0];
  }
  throw new Error("Could not find a Notes folder.");
}

const noteName = \(noteLiteral);
const notes = Application("/System/Applications/Notes.app");
notes.make({
  new: "note",
  at: resolveTargetFolder(notes),
  withProperties: { body: `<div>${escapeHtml(noteName)}</div>` },
});
"""

    runProcess("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
}

func showNote(noteID: String) {
    automationDebugLog("showNote(\(noteID))")
    let noteLiteral = jsStringLiteral(noteID)
    let script = """
const noteId = \(noteLiteral);
const notes = Application("/System/Applications/Notes.app");
try {
  const note = notes.notes.byId(noteId);
  if (String(note.id() || "") === noteId) {
    notes.activate();
    note.show();
    console.log("true");
  } else {
    console.log("false");
  }
} catch (error) {
  console.log("false");
}
"""

    _ = timed("showNote") {
        runProcessOutput("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
    }
}

func existingNoteID(noteTitle: String, noteID: String? = nil) -> String? {
    automationDebugLog("existingNoteID(title=\(noteTitle), explicit=\(noteID ?? "nil"))")
    if let trimmedNoteID = normalizedNoteID(noteID) {
        knownExistingNoteIDs.insert(trimmedNoteID)
        return trimmedNoteID
    }

    let matchingIDs = noteIDs(matching: noteTitle)
    return matchingIDs.first
}

@discardableResult
func ensureExistingNoteVisible(noteTitle: String, noteID: String? = nil) -> Bool {
    automationDebugLog("ensureExistingNoteVisible(\(noteTitle))")
    guard let resolvedNoteID = existingNoteID(noteTitle: noteTitle, noteID: noteID) else {
        return false
    }
    showNote(noteID: resolvedNoteID)
    activateApplication(pid: runningNotesPID())
    Thread.sleep(forTimeInterval: 0.35)
    let selected = waitForVisibleNoteByAnchors(noteTitle: noteTitle, noteID: resolvedNoteID)
    _ = focusNotesEditorViaSystemEvents()
    Thread.sleep(forTimeInterval: 0.15)
    return selected
}

func deleteNote(noteID: String) {
    automationDebugLog("deleteNote(\(noteID))")
    let noteLiteral = jsStringLiteral(noteID)
    let script = """
const noteId = \(noteLiteral);
const notes = Application("/System/Applications/Notes.app");
try {
  const note = notes.notes.byId(noteId);
  if (String(note.id() || "") === noteId) {
    note.delete();
  }
} catch (error) {
}
"""

    _ = timed("deleteNote") {
        runProcessOutput("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
    }
}

func ensureNoteVisible(noteTitle: String, noteID: String? = nil) {
    automationDebugLog("ensureNoteVisible(\(noteTitle))")
    if ensureExistingNoteVisible(noteTitle: noteTitle, noteID: noteID) {
        return
    }
    if normalizedNoteID(noteID) != nil {
        automationDebugLog("Proceeding with explicit note id after visibility check fallback: \(noteTitle)")
        return
    }

    var ids = noteIDs(matching: noteTitle)
    if ids.isEmpty {
        createNote(noteTitle: noteTitle)
        Thread.sleep(forTimeInterval: 0.4)
        ids = noteIDs(matching: noteTitle)
    }

    guard let keepID = ids.first else {
        fail("Could not create or locate note: \(noteTitle)")
    }

    for duplicateID in ids.dropFirst() {
        deleteNote(noteID: duplicateID)
        Thread.sleep(forTimeInterval: 0.15)
    }

    showNote(noteID: keepID)
    activateApplication(pid: runningNotesPID())
    Thread.sleep(forTimeInterval: 0.35)
    guard waitForVisibleNoteByAnchors(noteTitle: noteTitle, noteID: keepID) else {
        fail("Could not confirm Notes selection for note: \(noteTitle)")
    }
    _ = focusNotesEditorViaSystemEvents()
    Thread.sleep(forTimeInterval: 0.15)
}

func cleanupDuplicateNotes(noteTitle: String) {
    automationDebugLog("cleanupDuplicateNotes(\(noteTitle))")
    var ids = noteIDs(matching: noteTitle)
    for _ in 0..<5 {
        guard let keepID = ids.first, ids.count > 1 else {
            break
        }
        for duplicateID in ids.dropFirst() where duplicateID != keepID {
            deleteNote(noteID: duplicateID)
            Thread.sleep(forTimeInterval: 0.15)
        }
        Thread.sleep(forTimeInterval: 0.2)
        ids = noteIDs(matching: noteTitle)
    }
}

func attemptResolveNotesEditorContext(
    notesPID: pid_t? = nil,
    expectedNoteID: String? = nil,
    expectedAnchorTexts: [String] = [],
    retries: Int = 20,
    retryDelay: TimeInterval = 0.15,
    fallbackChecklistButton: AXUIElement? = nil
) -> NotesEditorContext? {
    let systemWide = AXUIElementCreateSystemWide()

    for _ in 0..<retries {
        let app: AXUIElement
        if let notesPID {
            app = AXUIElementCreateApplication(notesPID)
        } else if let runningNotesPID = runningNotesPID() {
            app = AXUIElementCreateApplication(runningNotesPID)
        } else {
            guard let focusedApp: AXUIElement = attr(systemWide, kAXFocusedApplicationAttribute) else {
                Thread.sleep(forTimeInterval: retryDelay)
                continue
            }
            app = focusedApp
        }

        let targetPID = elementPID(app)

        if let expectedNoteID, expectedAnchorTexts.isEmpty, !selectedNoteIDs().contains(expectedNoteID) {
            Thread.sleep(forTimeInterval: retryDelay)
            continue
        }

        if let targetPID,
           let focusedApp: AXUIElement = attr(systemWide, kAXFocusedApplicationAttribute),
           let focusedPID = elementPID(focusedApp),
           focusedPID != targetPID {
            _ = focusNotesEditorViaSystemEvents()
            Thread.sleep(forTimeInterval: retryDelay)
        }

        let focusedElement: AXUIElement? = attr(systemWide, kAXFocusedUIElementAttribute)
        var candidateWindows: [AXUIElement] = []
        if let focusedWindow: AXUIElement = attr(app, kAXFocusedWindowAttribute) {
            candidateWindows.append(focusedWindow)
        }
        let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        candidateWindows.append(contentsOf: windows)

        var seenWindowDescriptions: Set<String> = []
        var bestFallback: NotesEditorContext?
        var bestFallbackScore = Int.min
        for window in candidateWindows {
            let key = "\(Unmanaged.passUnretained(window).toOpaque())"
            guard seenWindowDescriptions.insert(key).inserted else {
                continue
            }
            let checklistButton =
                checklistToolbarButton(in: window)
                ?? fallbackChecklistButton
                ?? checklistToolbarButton(in: app)
            let textAreas = candidateTextAreas(in: window, focusedElement: focusedElement)
            for textArea in textAreas {
                _ = AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                let textAreaFocused: Bool = attr(textArea, kAXFocusedAttribute) ?? false
                guard textAreaFocused else {
                    continue
                }

                let currentText: String = attr(textArea, kAXValueAttribute) ?? ""
                let normalizedCurrentText = oneLine(currentText)
                let matchesAnchor = matchesExpectedAnchors(currentText, anchors: expectedAnchorTexts)

                let isFocusedBranch = focusedElement.map { isDescendantAXElement($0, of: textArea) } ?? false
                let score =
                    (isFocusedBranch ? 100 : 0)
                    + (matchesAnchor ? 20 : 0)
                    + (!normalizedCurrentText.isEmpty ? 5 : 0)

                let context = NotesEditorContext(
                    app: app,
                    window: window,
                    textArea: textArea,
                    checklistButton: checklistButton,
                    noteID: expectedNoteID,
                    anchorTexts: expectedAnchorTexts
                )

                if matchesAnchor {
                    return context
                }

                if score > bestFallbackScore {
                    bestFallback = context
                    bestFallbackScore = score
                }
            }
        }

        if let bestFallback,
           expectedNoteID != nil,
           expectedAnchorTexts.isEmpty
        {
            automationDebugLog("Falling back to the focused Notes text area without anchor match.")
            return bestFallback
        }

        if focusedElement == nil {
            _ = focusNotesEditorViaSystemEvents()
        }
        Thread.sleep(forTimeInterval: retryDelay)
    }

    return nil
}

func resolveNotesEditorContext(
    notesPID: pid_t? = nil,
    noteTitle: String,
    noteID: String?,
    fallbackChecklistButton: AXUIElement? = nil
) -> NotesEditorContext {
    let resolvedNoteID = existingNoteID(noteTitle: noteTitle, noteID: noteID)
    let anchors = noteAnchorTexts(noteTitle: noteTitle, noteID: resolvedNoteID)
    guard let context = attemptResolveNotesEditorContext(
        notesPID: notesPID,
        expectedNoteID: resolvedNoteID,
        expectedAnchorTexts: anchors,
        fallbackChecklistButton: fallbackChecklistButton
    ) else {
        fail("Could not confirm the cursor is in the target Notes note: \(noteTitle)")
    }
    guard ensureEditableCaret(context.textArea) else {
        fail("Could not place the cursor in the target Notes editor: \(noteTitle)")
    }
    return context
}

func attributedString(for textArea: AXUIElement, range: LineRange) -> NSAttributedString? {
    var value: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(
        textArea,
        kAXAttributedStringForRangeParameterizedAttribute as CFString,
        cfRangeValue(range),
        &value
    )
    guard error == .success, let value else {
        return nil
    }
    return value as? NSAttributedString
}

func checklistState(from prefix: String) -> Bool? {
    let normalized = prefix
        .lowercased()
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    if normalized.contains("완료되지 않")
        || normalized.contains("체크 해제")
        || normalized.contains("선택 해제")
        || normalized.contains("not completed")
        || normalized.contains("not checked")
        || normalized.contains("not selected")
        || normalized.contains("unchecked")
        || normalized.contains("unselected")
    {
        return false
    }
    if normalized.contains("완료됨")
        || normalized.range(of: #"\b(completed|checked|selected)\b"#, options: .regularExpression) != nil
    {
        return true
    }
    return nil
}

func attachmentElement(from attributes: [NSAttributedString.Key: Any], key: NSAttributedString.Key) -> AXUIElement? {
    guard let rawValue = attributes[key] else {
        return nil
    }
    let cfValue = rawValue as CFTypeRef
    guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(cfValue, to: AXUIElement.self)
}

func prefixText(from attributes: [NSAttributedString.Key: Any], key: NSAttributedString.Key) -> String? {
    if let prefix = attributes[key] as? String {
        return prefix
    }
    if let prefix = attributes[key] as? NSAttributedString {
        return prefix.string
    }
    return nil
}

func checklistLineMatchesLabel(
    _ capturedLabel: String,
    expectedLabel: String
) -> Bool {
    lineLabel(capturedLabel) == expectedLabel
}

func checklistInfo(
    textArea: AXUIElement,
    currentText: String,
    range: LineRange
) -> (label: String, info: ChecklistInfo)? {
    let label = lineLabel(substring(currentText, range: range) ?? "")
    guard !label.isEmpty else {
        return nil
    }
    guard let attributed = attributedString(for: textArea, range: range), attributed.length > 0 else {
        return nil
    }

    let attributes = attributed.attributes(at: 0, effectiveRange: nil)
    let prefixKey = NSAttributedString.Key("AXListItemPrefix")
    let attachmentKey = NSAttributedString.Key("AXAttachment")
    guard let prefix = prefixText(from: attributes, key: prefixKey),
          let isChecked = checklistState(from: prefix) else {
        return nil
    }

    return (
        label,
        ChecklistInfo(
            isChecked: isChecked,
            attachment: attachmentElement(from: attributes, key: attachmentKey)
        )
    )
}

func checklistInfo(
    textArea: AXUIElement,
    currentText: String,
    range: LineRange,
    expectedLabel: String
) -> ChecklistInfo? {
    guard let captured = checklistInfo(
        textArea: textArea,
        currentText: currentText,
        range: range
    ), checklistLineMatchesLabel(captured.label, expectedLabel: expectedLabel) else {
        return nil
    }
    return captured.info
}

func capturedChecklistLines(
    textArea: AXUIElement,
    currentText: String,
    searchRange: LineRange? = nil
) -> [CapturedChecklistLine] {
    let fullRange = LineRange(location: 0, length: nsLength(currentText))
    guard let attributedText = attributedString(for: textArea, range: fullRange) else {
        return []
    }

    return lineEntries(in: currentText).compactMap { entry in
        if let searchRange, !containsLineStart(searchRange: searchRange, lineRange: entry.range) {
            return nil
        }
        let label = lineLabel(entry.text)
        guard !label.isEmpty else {
            return nil
        }
        guard let prefix = checklistPrefix(attributedText: attributedText, range: entry.range),
              let isChecked = checklistState(from: prefix) else {
            return nil
        }
        return CapturedChecklistLine(
            label: label,
            isChecked: isChecked,
            range: entry.range
        )
    }
}

func captureChecklistValue(
    textArea: AXUIElement,
    range: LineRange,
    expectedLabel: String
) -> Bool? {
    let currentText: String = attr(textArea, kAXValueAttribute) ?? ""
    return checklistInfo(textArea: textArea, currentText: currentText, range: range, expectedLabel: expectedLabel)?.isChecked
}

func captureChecklistValue(
    attributedText: NSAttributedString,
    currentText: String,
    range: LineRange,
    expectedLabel: String
) -> Bool? {
    let label = lineLabel(substring(currentText, range: range) ?? "")
    guard checklistLineMatchesLabel(label, expectedLabel: expectedLabel),
          range.location >= 0,
          range.location < attributedText.length else {
        return nil
    }

    let attributes = attributedText.attributes(at: range.location, effectiveRange: nil)
    guard let prefix = prefixText(from: attributes, key: NSAttributedString.Key("AXListItemPrefix")) else {
        return nil
    }
    return checklistState(from: prefix)
}

func checklistPrefix(
    attributedText: NSAttributedString,
    range: LineRange
) -> String? {
    guard range.location >= 0, range.location < attributedText.length else {
        return nil
    }
    let attributes = attributedText.attributes(at: range.location, effectiveRange: nil)
    return prefixText(from: attributes, key: NSAttributedString.Key("AXListItemPrefix"))
}

func loadCaptureText(
    textArea: AXUIElement,
    expectedTitles: [String]
) -> String {
    let normalizedTitles = expectedTitles
        .map(oneLine)
        .filter { !$0.isEmpty }
    var lastText = ""

    for _ in 0..<40 {
        let currentText: String = attr(textArea, kAXValueAttribute) ?? ""
        lastText = currentText
        let normalizedText = oneLine(currentText)
        if normalizedTitles.isEmpty && !normalizedText.isEmpty {
            return currentText
        }
        let hasExpectedTitle = normalizedTitles.contains { normalizedText.contains($0) }
        let hasChecklistLabels = normalizedText.contains(readChecklistLabel) || normalizedText.contains(importantChecklistLabel)
        if hasExpectedTitle && (hasChecklistLabels || normalizedTitles.isEmpty) {
            return currentText
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    return lastText
}

func resolveRenderedNoticeRanges(
    currentText: String,
    renderedNotices: [RenderedNoticePlan]
) -> [ResolvedRenderedNotice] {
    let titleRanges = resolvedNoticeTitleRanges(
        currentText: currentText,
        titles: renderedNotices.map {
            let resolvedTitle = oneLine($0.renderedTitle)
            return resolvedTitle.isEmpty ? $0.title : $0.renderedTitle
        }
    )
    let textLength = nsLength(currentText)

    return renderedNotices.enumerated().map { index, notice in
        let searchRange = noticeBlockSearchRange(
            titleRanges: titleRanges,
            noticeIndex: index,
            textLength: textLength
        )
        let readRange = searchRange.flatMap {
            checklistRangeInNoticeBlock(
                currentText: currentText,
                searchRange: $0,
                label: readChecklistLabel
            )
        } ?? notice.readChecklistRange
        let importantRange = searchRange.flatMap {
            checklistRangeInNoticeBlock(
                currentText: currentText,
                searchRange: $0,
                label: importantChecklistLabel
            )
        } ?? notice.importantChecklistRange
        return ResolvedRenderedNotice(
            notice: notice,
            readRange: readRange,
            importantRange: importantRange
        )
    }
}

func resolveRenderedNoticeRanges(
    lineRanges: [LineRange],
    renderedNotices: [RenderedNoticePlan]
) -> [ResolvedRenderedNotice] {
    renderedNotices.compactMap { notice in
        guard notice.readLineIndex >= 0, notice.readLineIndex < lineRanges.count,
              notice.importantLineIndex >= 0, notice.importantLineIndex < lineRanges.count else {
            return nil
        }
        return ResolvedRenderedNotice(
            notice: notice,
            readRange: lineRanges[notice.readLineIndex],
            importantRange: lineRanges[notice.importantLineIndex]
        )
    }
}

func checklistLayoutIssues(
    textArea: AXUIElement,
    currentText: String,
    resolvedNotices: [ResolvedRenderedNotice]
) -> [String] {
    var expectedChecklistRanges: [Int: Set<String>] = [:]
    for resolved in resolvedNotices {
        expectedChecklistRanges[resolved.readRange.location, default: []].insert(readChecklistLabel)
        expectedChecklistRanges[resolved.importantRange.location, default: []].insert(importantChecklistLabel)
    }

    var issues: [String] = []
    let fullRange = LineRange(location: 0, length: nsLength(currentText))
    guard let attributedText = attributedString(for: textArea, range: fullRange) else {
        return ["missing attributed text for checklist validation"]
    }
    for (index, entry) in lineEntries(in: currentText).enumerated() {
        let lineText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = checklistPrefix(attributedText: attributedText, range: entry.range)
        let isChecklistLine = prefix.flatMap(checklistState(from:)) != nil
        let expectedLabels = expectedChecklistRanges[entry.range.location] ?? []

        if !expectedLabels.isEmpty {
            if !isChecklistLine {
                for expectedLabel in expectedLabels.sorted() {
                    issues.append("missing checklist line \(index + 1): \(expectedLabel)")
                }
            } else if !expectedLabels.contains(lineText) {
                let joinedLabels = expectedLabels.sorted().joined(separator: ",")
                issues.append("missing checklist line \(index + 1): \(joinedLabels)")
                issues.append("misplaced checklist line \(index + 1): \(truncated(lineText, maxLength: 80))")
            }
            continue
        }

        if isChecklistLine {
            issues.append("unexpected checklist line \(index + 1): \(truncated(lineText, maxLength: 80))")
        }
    }

    return issues
}

func checklistStateIssues(
    textArea: AXUIElement,
    currentText: String,
    resolvedNotices: [ResolvedRenderedNotice]
) -> [String] {
    let fullRange = LineRange(location: 0, length: nsLength(currentText))
    guard let attributedText = attributedString(for: textArea, range: fullRange) else {
        return ["missing attributed text for checklist state validation"]
    }

    var issues: [String] = []
    for resolved in resolvedNotices {
        let desiredReadState = resolved.notice.shouldCheckRead
        if captureChecklistValue(
            attributedText: attributedText,
            currentText: currentText,
            range: resolved.readRange,
            expectedLabel: readChecklistLabel
        ) != desiredReadState {
            let description = desiredReadState ? "not checked" : "unexpectedly checked"
            issues.append("read checklist \(description): \(resolved.notice.renderedTitle)")
        }

        let desiredImportantState = resolved.notice.shouldCheckImportant
        if captureChecklistValue(
            attributedText: attributedText,
            currentText: currentText,
            range: resolved.importantRange,
            expectedLabel: importantChecklistLabel
        ) != desiredImportantState {
            let description = desiredImportantState ? "not checked" : "unexpectedly checked"
            issues.append("important checklist \(description): \(resolved.notice.renderedTitle)")
        }
    }
    return issues
}

enum BoldInspectionResult {
    case bold
    case notBold
    case unknown
}

func fontDescriptionLooksBold(_ rawValue: String) -> Bool {
    let normalized = rawValue.lowercased()
    return normalized.contains("bold")
        || normalized.contains("semibold")
        || normalized.contains("demibold")
        || normalized.contains("heavy")
        || normalized.contains("black")
}

func fontValueLooksBold(_ value: Any) -> Bool {
    if let font = value as? NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.bold) {
            return true
        }
        if fontDescriptionLooksBold(font.fontName) {
            return true
        }
        if let displayName = font.displayName, fontDescriptionLooksBold(displayName) {
            return true
        }
    }

    if let descriptor = value as? NSFontDescriptor {
        if descriptor.symbolicTraits.contains(.bold) {
            return true
        }
        if let fontName = descriptor.fontAttributes[.name] as? String,
           fontDescriptionLooksBold(fontName) {
            return true
        }
    }

    return fontDescriptionLooksBold(String(describing: value))
}

func attributesBoldState(_ attributes: [NSAttributedString.Key: Any]) -> BoldInspectionResult {
    let preferredFontKeys: [NSAttributedString.Key] = [
        .font,
        NSAttributedString.Key("AXFont"),
        NSAttributedString.Key("NSFont"),
        NSAttributedString.Key("CTFont"),
    ]
    var sawFontAttribute = false

    for key in preferredFontKeys {
        guard let value = attributes[key] else {
            continue
        }
        sawFontAttribute = true
        if fontValueLooksBold(value) {
            return .bold
        }
    }

    for (key, value) in attributes where key.rawValue.lowercased().contains("font") {
        sawFontAttribute = true
        if fontValueLooksBold(value) {
            return .bold
        }
    }

    return sawFontAttribute ? .notBold : .unknown
}

func nonWhitespaceUTF16Length(_ text: String) -> Int {
    var count = 0
    for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
        count += String(scalar).utf16.count
    }
    return count
}

func boldInspectionResult(
    textArea: AXUIElement,
    range: LineRange
) -> BoldInspectionResult {
    guard range.length > 0,
          let attributed = attributedString(for: textArea, range: range),
          attributed.length > 0 else {
        return .unknown
    }

    let fullRange = NSRange(location: 0, length: attributed.length)
    let attributedText = attributed.string as NSString
    var nonWhitespaceUnits = 0
    var boldUnits = 0
    var sawFontAttribute = false

    attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
        let segment = attributedText.substring(with: range)
        let unitCount = nonWhitespaceUTF16Length(segment)
        guard unitCount > 0 else {
            return
        }

        let boldState = attributesBoldState(attributes)
        if boldState != .unknown {
            sawFontAttribute = true
        }
        if boldState == .bold {
            boldUnits += unitCount
        }
        nonWhitespaceUnits += unitCount
    }

    guard nonWhitespaceUnits > 0 else {
        return .bold
    }
    guard sawFontAttribute else {
        return .unknown
    }

    return Double(boldUnits) / Double(nonWhitespaceUnits) >= 0.8 ? .bold : .notBold
}

func boldStyleIssues(
    textArea: AXUIElement,
    targets: [StyleValidationTarget]
) -> [String] {
    var issues: [String] = []
    var seen: Set<String> = []
    for target in targets {
        guard target.range.length > 0 else {
            continue
        }
        let dedupeKey = "\(target.range.location):\(target.range.length):\(target.label)"
        guard seen.insert(dedupeKey).inserted else {
            continue
        }
        switch boldInspectionResult(textArea: textArea, range: target.range) {
        case .bold:
            continue
        case .notBold:
            issues.append("bold style missing: \(target.label)")
        case .unknown:
            issues.append("bold style unverifiable: \(target.label)")
        }
    }
    return issues
}

func decodeBasicHTMLEntities(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
}

func htmlPlainText(_ html: String) -> String {
    let withLineBreaks = html.replacingOccurrences(
        of: #"(?i)<br\s*/?>"#,
        with: "\n",
        options: .regularExpression
    )
    let withoutTags = withLineBreaks.replacingOccurrences(
        of: #"<[^>]+>"#,
        with: "",
        options: .regularExpression
    )
    return decodeBasicHTMLEntities(withoutTags)
}

func htmlLineBlocks(_ html: String) -> [(text: String, hasBold: Bool)] {
    guard let regex = try? NSRegularExpression(
        pattern: #"(?is)<(div|p|li|h[1-6])\b[^>]*>(.*?)</\1>"#,
        options: []
    ) else {
        return []
    }

    let nsHTML = html as NSString
    let fullRange = NSRange(location: 0, length: nsHTML.length)
    return regex.matches(in: html, options: [], range: fullRange).compactMap { match in
        guard match.numberOfRanges >= 3 else {
            return nil
        }
        let tag = nsHTML.substring(with: match.range(at: 1)).lowercased()
        let inner = nsHTML.substring(with: match.range(at: 2))
        let normalizedText = oneLine(htmlPlainText(inner))
        guard !normalizedText.isEmpty else {
            return nil
        }
        let lowercasedInner = inner.lowercased()
        let hasNestedHeading =
            lowercasedInner.range(of: #"<h[1-6]\b"#, options: .regularExpression) != nil
        let hasBold = tag.hasPrefix("h")
            || hasNestedHeading
            || lowercasedInner.contains("<b")
            || lowercasedInner.contains("<strong")
            || lowercasedInner.contains("bold")
        return (normalizedText, hasBold)
    }
}

func htmlBoldStyleIssues(
    noteTitle: String,
    noteID: String?,
    currentText: String,
    targets: [StyleValidationTarget]
) -> [String] {
    var candidateHTML: [String] = []
    if let html = noteBodyHTMLByAppleScript(noteTitle: noteTitle) {
        candidateHTML.append(html)
    }

    let targetTexts = targets.compactMap { target -> String? in
        guard let rawTargetText = substring(currentText, range: target.range) else {
            return nil
        }
        let targetText = oneLine(rawTargetText)
        return targetText.isEmpty ? nil : targetText
    }

    let matchingHTML = candidateHTML.filter { html in
        let normalizedPlain = oneLine(htmlPlainText(html))
        guard !normalizedPlain.isEmpty else {
            return false
        }
        return targetTexts.prefix(2).allSatisfy { normalizedPlain.contains($0) }
    }
    let htmlToEvaluate = matchingHTML.isEmpty ? candidateHTML : matchingHTML
    guard !htmlToEvaluate.isEmpty else {
        return ["bold style html unavailable: \(noteTitle)"]
    }

    var firstIssues: [String]?
    for html in htmlToEvaluate {
        let blocks = htmlLineBlocks(html)
        guard !blocks.isEmpty else {
            continue
        }
        let boldBlockTexts = Set(blocks.filter(\.hasBold).map { oneLine($0.text) })

        var issues: [String] = []
        var seen: Set<String> = []
        for target in targets {
            guard let rawTargetText = substring(currentText, range: target.range) else {
                continue
            }
            let targetText = oneLine(rawTargetText)
            guard !targetText.isEmpty, seen.insert("\(target.label):\(targetText)").inserted else {
                continue
            }
            guard boldBlockTexts.contains(targetText) else {
                issues.append("bold style missing in html: \(target.label)")
                continue
            }
        }

        if issues.isEmpty {
            return []
        }
        if firstIssues == nil {
            firstIssues = issues
        }
    }

    return firstIssues ?? ["bold style html unavailable: \(noteTitle)"]
}

func checklistEntry(
    matching expectedLabel: String,
    in checklistLines: [CapturedChecklistLine]
) -> CapturedChecklistLine? {
    checklistLines.first(where: { $0.label == expectedLabel })
}

func findNoticeTitleRange(
    currentText: String,
    title: String,
    cursor: inout Int
) -> LineRange? {
    let normalizedTitle = oneLine(title)
    guard !normalizedTitle.isEmpty else {
        return nil
    }

    for entry in lineEntries(in: currentText) {
        guard entry.range.location + entry.range.length >= cursor else {
            continue
        }
        let candidate = oneLine(entry.text)
        guard candidate == normalizedTitle else {
            continue
        }
        cursor = entry.range.location + entry.range.length
        return entry.range
    }

    return nil
}

func findChecklistRangeNearTitle(
    currentText: String,
    titleRange: LineRange,
    label: String
) -> LineRange? {
    let nsText = currentText as NSString
    let titleEnd = titleRange.location + titleRange.length
    let windowLength = min(120, max(0, nsText.length - titleEnd))
    guard windowLength > 0 else {
        return nil
    }

    let searchEnd = titleEnd + windowLength
    let normalizedLabel = oneLine(label)
    for entry in lineEntries(in: currentText) {
        guard entry.range.location >= titleEnd && entry.range.location < searchEnd else {
            continue
        }
        guard lineLabel(entry.text) == normalizedLabel else {
            continue
        }
        return entry.range
    }
    return nil
}

@discardableResult
func setChecklistState(
    app: AXUIElement,
    textArea: AXUIElement,
    range: LineRange,
    expectedLabel: String,
    checked: Bool
) -> Bool {
    for _ in 0..<12 {
        activateApplication(pid: elementPID(app))
        usleep(30_000)
        _ = AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let currentText: String = attr(textArea, kAXValueAttribute) ?? ""
        guard let current = checklistInfo(
            textArea: textArea,
            currentText: currentText,
            range: range,
            expectedLabel: expectedLabel
        ) else {
            Thread.sleep(forTimeInterval: 0.12)
            continue
        }

        if current.isChecked == checked {
            return true
        }

        guard let attachment = current.attachment else {
            Thread.sleep(forTimeInterval: 0.12)
            continue
        }

        _ = selectRange(textArea, location: range.location, length: range.length)
        _ = ensureEditableCaret(textArea)
        let error = AXUIElementPerformAction(attachment, kAXPressAction as CFString)
        guard error == .success else {
            Thread.sleep(forTimeInterval: 0.12)
            continue
        }
        Thread.sleep(forTimeInterval: 0.16)
    }
    let refreshedText: String = attr(textArea, kAXValueAttribute) ?? ""
    return checklistInfo(
        textArea: textArea,
        currentText: refreshedText,
        range: range,
        expectedLabel: expectedLabel
    )?.isChecked == checked
}

@discardableResult
func markChecklistChecked(
    app: AXUIElement,
    textArea: AXUIElement,
    range: LineRange,
    expectedLabel: String
) -> Bool {
    let currentText: String = attr(textArea, kAXValueAttribute) ?? ""
    guard let current = checklistInfo(
        textArea: textArea,
        currentText: currentText,
        range: range,
        expectedLabel: expectedLabel
    ) else {
        return false
    }

    if current.isChecked {
        return true
    }

    _ = app
    return setChecklistState(
        app: app,
        textArea: textArea,
        range: range,
        expectedLabel: expectedLabel,
        checked: true
    )
}

@discardableResult
func markChecklistUnchecked(
    app: AXUIElement,
    textArea: AXUIElement,
    range: LineRange,
    expectedLabel: String
) -> Bool {
    _ = app
    return setChecklistState(
        app: app,
        textArea: textArea,
        range: range,
        expectedLabel: expectedLabel,
        checked: false
    )
}

@discardableResult
func ensureChecklistState(
    app: AXUIElement,
    textArea: AXUIElement,
    range: LineRange,
    expectedLabel: String,
    checked: Bool
) -> Bool {
    if checked {
        return markChecklistChecked(
            app: app,
            textArea: textArea,
            range: range,
            expectedLabel: expectedLabel
        )
    }

    return markChecklistUnchecked(
        app: app,
        textArea: textArea,
        range: range,
        expectedLabel: expectedLabel
    )
}

func ensureChecklistStates(
    app: AXUIElement,
    textArea: AXUIElement,
    resolvedNotices: [ResolvedRenderedNotice]
) {
    for _ in 0..<2 {
        let currentText: String = attr(textArea, kAXValueAttribute) ?? ""
        let fullRange = LineRange(location: 0, length: nsLength(currentText))
        let attributedText = attributedString(for: textArea, range: fullRange)
        var hasMismatch = false
        for resolved in resolvedNotices {
            let desiredReadState = resolved.notice.shouldCheckRead
            let readState = attributedText.flatMap {
                captureChecklistValue(
                    attributedText: $0,
                    currentText: currentText,
                    range: resolved.readRange,
                    expectedLabel: readChecklistLabel
                )
            }
            if readState != desiredReadState {
                hasMismatch = true
                _ = ensureChecklistState(
                    app: app,
                    textArea: textArea,
                    range: resolved.readRange,
                    expectedLabel: readChecklistLabel,
                    checked: desiredReadState
                )
            }

            let desiredImportantState = resolved.notice.shouldCheckImportant
            let importantState = attributedText.flatMap {
                captureChecklistValue(
                    attributedText: $0,
                    currentText: currentText,
                    range: resolved.importantRange,
                    expectedLabel: importantChecklistLabel
                )
            }
            if importantState != desiredImportantState {
                hasMismatch = true
                _ = ensureChecklistState(
                    app: app,
                    textArea: textArea,
                    range: resolved.importantRange,
                    expectedLabel: importantChecklistLabel,
                    checked: desiredImportantState
                )
            }
        }
        if !hasMismatch {
            return
        }
        Thread.sleep(forTimeInterval: 0.18)
    }
}

func ensureCheckedItemsStayInPlace(
    app: AXUIElement,
    textArea: AXUIElement,
    resolvedNotices: [ResolvedRenderedNotice]
) {
    guard let firstChecklistRange =
        resolvedNotices.first.map({ $0.readRange.length > 0 ? $0.readRange : $0.importantRange }),
        selectRange(textArea, location: firstChecklistRange.location, length: firstChecklistRange.length) else {
        return
    }

    let moveCheckedTitles = ["체크한 항목 하단으로 이동", "Move Checked Items to Bottom"]
    guard menuItemMarkChar(app, moveCheckedTitles) != nil else {
        return
    }

    _ = pressMenuIfAvailable(app, moveCheckedTitles)
    Thread.sleep(forTimeInterval: 0.08)
}

func applyChecklistFormatting(
    context: NotesEditorContext,
    noteTitle: String,
    noteID: String?,
    currentText: String,
    resolvedNotices: [ResolvedRenderedNotice]
) {
    func lineIsChecklist(_ lineRange: LineRange) -> Bool {
        let refreshedText: String = attr(context.textArea, kAXValueAttribute) ?? currentText
        return checklistInfo(
            textArea: context.textArea,
            currentText: refreshedText,
            range: lineRange
        ) != nil
    }

    @discardableResult
    func forceChecklistSelectionOn(selectionRange: LineRange, validationRanges: [LineRange]) -> Bool {
        let initialStates = validationRanges.map { lineIsChecklist($0) }
        if initialStates.allSatisfy({ $0 }) {
            return true
        }
        if initialStates.contains(true), validationRanges.count > 1 {
            return false
        }

        guard selectRangeForFormatting(
            context: context,
            range: selectionRange,
            noteTitle: noteTitle,
            noteID: noteID
        ) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.04)

        if validationRanges.allSatisfy(lineIsChecklist) {
            return true
        }

        if let button = resolvedChecklistButton(for: context) {
            activateApplication(pid: elementPID(context.app))
            let _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.08)
            if validationRanges.allSatisfy(lineIsChecklist) {
                return true
            }
        }

        activateApplication(pid: elementPID(context.app))
        _ = pressMenuIfAvailable(context.app, checklistMenuTitles)
        Thread.sleep(forTimeInterval: 0.08)
        return validationRanges.allSatisfy(lineIsChecklist)
    }

    @discardableResult
    func pressChecklistForSelection(_ selectionRange: LineRange) -> Bool {
        guard selectRangeForFormatting(
            context: context,
            range: selectionRange,
            noteTitle: noteTitle,
            noteID: noteID
        ) else {
            return false
        }
        activateApplication(pid: elementPID(context.app))
        if let button = resolvedChecklistButton(for: context),
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            Thread.sleep(forTimeInterval: 0.045)
            return true
        }
        let pressed = pressMenuIfAvailable(context.app, checklistMenuTitles)
        Thread.sleep(forTimeInterval: 0.06)
        return pressed
    }

    func checklistPairSelectionRange(readRange: LineRange, importantRange: LineRange) -> LineRange? {
        guard readRange.length > 0, importantRange.length > 0 else {
            return nil
        }
        let readSelection = paragraphSelectionRange(in: currentText, lineRange: readRange)
        let importantSelection = paragraphSelectionRange(in: currentText, lineRange: importantRange)
        let start = min(readSelection.location, importantSelection.location)
        let end = max(
            readSelection.location + readSelection.length,
            importantSelection.location + importantSelection.length
        )
        guard end > start else {
            return nil
        }
        return LineRange(location: start, length: end - start)
    }

    var fallbackRanges: [LineRange] = []
    if batchChecklistFormattingEnabled {
        timingLog("checklist_format_batch_start note=\(noteTitle) pairs=\(resolvedNotices.count)")
        for resolved in resolvedNotices {
            guard let pairRange = checklistPairSelectionRange(
                readRange: resolved.readRange,
                importantRange: resolved.importantRange
            ) else {
                fallbackRanges.append(resolved.readRange)
                fallbackRanges.append(resolved.importantRange)
                continue
            }
            if pressChecklistForSelection(pairRange) {
                continue
            }
            fallbackRanges.append(resolved.readRange)
            fallbackRanges.append(resolved.importantRange)
        }
        let postBatchText: String = attr(context.textArea, kAXValueAttribute) ?? currentText
        for resolved in resolvedNotices {
            if checklistInfo(
                textArea: context.textArea,
                currentText: postBatchText,
                range: resolved.readRange,
                expectedLabel: readChecklistLabel
            ) == nil {
                fallbackRanges.append(resolved.readRange)
            }
            if checklistInfo(
                textArea: context.textArea,
                currentText: postBatchText,
                range: resolved.importantRange,
                expectedLabel: importantChecklistLabel
            ) == nil {
                fallbackRanges.append(resolved.importantRange)
            }
        }
        fallbackRanges = uniqueLineRanges(fallbackRanges)
        timingLog("checklist_format_batch_finish note=\(noteTitle) fallback_lines=\(fallbackRanges.count)")
    } else {
        fallbackRanges = resolvedNotices.flatMap { [$0.readRange, $0.importantRange] }
    }

    for range in fallbackRanges {
        _ = forceChecklistSelectionOn(
            selectionRange: paragraphSelectionRange(in: currentText, lineRange: range),
            validationRanges: [range]
        )
    }
}

func syncUserStateFromRenderedNote(
    noteTitle: String,
    noteID: String?,
    displayMode: NoticeDisplayMode,
    context: NotesEditorContext,
    previousRenderState: NoticeRenderStateFile?,
    userState: inout NoticeUserStateFile,
    timestamp: String
) {
    guard let previousRenderState else {
        return
    }

    func captureSnapshot(using snapshotContext: NotesEditorContext) -> String {
        _ = pressMenuIfAvailable(snapshotContext.app, ["모든 섹션 펼치기", "Expand All Sections"])
        Thread.sleep(forTimeInterval: 0.35)
        debugLog("expand-all complete")

        for rendered in previousRenderState.renderedNotices.reversed() {
            guard selectRange(
                snapshotContext.textArea,
                location: rendered.sectionRange.location,
                length: rendered.sectionRange.length
            ) else {
                continue
            }
            _ = pressMenuIfAvailable(snapshotContext.app, ["섹션 펼치기", "Expand Section"])
            Thread.sleep(forTimeInterval: 0.08)
        }

        return loadCaptureText(
            textArea: snapshotContext.textArea,
            expectedTitles: previousRenderState.renderedNotices.map(\.title)
        )
    }

    var captureContext = context
    var currentText = captureSnapshot(using: captureContext)
    if !currentText.contains(readChecklistLabel) && !currentText.contains(importantChecklistLabel) {
        debugLog("checklist labels missing in initial snapshot; refreshing editor context")
        ensureNoteVisible(noteTitle: noteTitle, noteID: noteID)
        let resolvedNoteID = existingNoteID(noteTitle: noteTitle, noteID: noteID)
        let anchors = noteAnchorTexts(noteTitle: noteTitle, noteID: resolvedNoteID)
        if let refreshedContext = attemptResolveNotesEditorContext(
            expectedNoteID: resolvedNoteID,
            expectedAnchorTexts: anchors,
            fallbackChecklistButton: context.checklistButton
        ) {
            captureContext = refreshedContext
            currentText = captureSnapshot(using: captureContext)
        } else {
            debugLog("editor context refresh failed; keeping initial context")
        }
    }

    if let expectedPlaintextHash = previousRenderState.plaintextHash,
       plaintextHash(for: currentText) != expectedPlaintextHash {
        debugLog("Skipping capture because rendered note plaintext no longer matches render state: \(noteTitle)")
        return
    }

    debugLog("current-text-prefix=\(oneLine(String(currentText.prefix(240))))")
    let renderedTitles = previousRenderState.renderedNotices.map { rendered in
        let resolvedRenderedTitle = oneLine(rendered.renderedTitle ?? "")
        return resolvedRenderedTitle.isEmpty ? rendered.title : resolvedRenderedTitle
    }
    let titleRanges = resolvedNoticeTitleRanges(
        currentText: currentText,
        titles: renderedTitles
    )
    let textLength = nsLength(currentText)

    for (index, rendered) in previousRenderState.renderedNotices.enumerated() {
        var state = userState.notices[rendered.noticeId] ?? NoticeInteractionState()
        state.title = rendered.title
        state.course = rendered.course
        state.fingerprint = rendered.fingerprint
        state.updatedAt = timestamp

        let titleRange = titleRanges[index]
        let searchRange = noticeBlockSearchRange(
            titleRanges: titleRanges,
            noticeIndex: index,
            textLength: textLength
        )
        let checklistLines = searchRange.map {
            capturedChecklistLines(
                textArea: captureContext.textArea,
                currentText: currentText,
                searchRange: $0
            )
        } ?? []
        let readEntry = checklistEntry(matching: readChecklistLabel, in: checklistLines)
        let importantEntry = checklistEntry(matching: importantChecklistLabel, in: checklistLines)
        let checklistSummary = checklistLines
            .map { "\($0.label)=\($0.isChecked)@\($0.range.location):\($0.range.length)" }
            .joined(separator: ", ")
        debugLog(
            "notice=\(rendered.title) titleRange=\(String(describing: titleRange)) "
                + "checklists=\(checklistSummary)"
        )

        if let readChecked = readEntry?.isChecked {
            debugLog("notice=\(rendered.title) readChecked=\(readChecked)")
            if displayMode == .primary && readChecked {
                state.readFingerprint = rendered.fingerprint
                state.readAt = timestamp
            } else if !readChecked && state.readFingerprint == rendered.fingerprint {
                state.readFingerprint = nil
                state.readAt = nil
            } else if displayMode == .archive && readChecked {
                debugLog("notice=\(rendered.title) ignoring archive read=true capture")
            }
        } else {
            debugLog("notice=\(rendered.title) readChecked=nil")
        }

        if let importantChecked = importantEntry?.isChecked {
            debugLog("notice=\(rendered.title) importantChecked=\(importantChecked)")
            if displayMode == .primary || importantChecked {
                state.important = importantChecked
                state.importantAt = importantChecked ? timestamp : nil
            } else {
                debugLog("notice=\(rendered.title) ignoring archive important=false capture")
            }
        } else {
            debugLog("notice=\(rendered.title) importantChecked=nil")
        }

        userState.notices[rendered.noticeId] = state
    }

    userState.updatedAt = timestamp
}

func captureRenderedNoticeState(
    noteTitle: String,
    noteID: String?,
    displayMode: NoticeDisplayMode,
    previousRenderState: NoticeRenderStateFile?,
    userState: inout NoticeUserStateFile,
    timestamp: String,
    skipActivation: Bool,
    notesPID: pid_t?
) {
    timed("captureRenderedNoticeState title=\(noteTitle)") {
        guard previousRenderState != nil else {
            return
        }
        if !skipActivation {
            guard let resolvedNoteID = existingNoteID(noteTitle: noteTitle, noteID: noteID) else {
                debugLog("Skipping capture for missing managed note: \(noteTitle)")
                return
            }
            guard ensureExistingNoteVisible(noteTitle: noteTitle, noteID: resolvedNoteID) else {
                debugLog("Skipping capture because Notes selection could not be confirmed for \(noteTitle)")
                return
            }
        }
        let captureContext = resolveNotesEditorContext(
            notesPID: notesPID,
            noteTitle: noteTitle,
            noteID: noteID
        )
        syncUserStateFromRenderedNote(
            noteTitle: noteTitle,
            noteID: noteID,
            displayMode: displayMode,
            context: captureContext,
            previousRenderState: previousRenderState,
            userState: &userState,
            timestamp: timestamp
        )
    }
}

func buildRenderPlan(
    noteTitle: String,
    digest: NoticeDigest,
    userState: inout NoticeUserStateFile,
    mode: NoticeDisplayMode
) -> PlanBuildResult {
    var currentNoticeIds: Set<String> = []
    var importantCourses: [DisplayCourse] = []
    var freshCourses: [DisplayCourse] = []
    var unreadCourses: [DisplayCourse] = []

    for courseDigest in digest.courses {
        var importantCourseNotices: [DisplayNotice] = []
        var freshCourseNotices: [DisplayNotice] = []
        var unreadCourseNotices: [DisplayNotice] = []
        for notice in courseDigest.notices {
            let noticeId = noticeIdentifier(course: courseDigest.course, notice: notice)
            currentNoticeIds.insert(noticeId)

            var state = userState.notices[noticeId] ?? NoticeInteractionState()
            state.title = notice.title
            state.course = courseDigest.course
            state.url = notice.url
            state.fingerprint = notice.fingerprint
            state.updatedAt = digest.generatedAt
            userState.notices[noticeId] = state

            let fingerprint = String(notice.fingerprint ?? "")
            let isImportant = boolValue(state.important)
            let isRead = !fingerprint.isEmpty && state.readFingerprint == fingerprint
            let changeState = notice.changeState ?? .stable
            let isFresh = changeState == .new || changeState == .updated
            // Keep the two checklist states independent so Notes only re-checks
            // the boxes the user explicitly left checked.
            let shouldRenderReadChecked = isRead

            let displayNotice = DisplayNotice(
                noticeId: noticeId,
                course: courseDigest.course,
                title: notice.title,
                displayTitle: oneLine(notice.title),
                postedAt: notice.postedAt,
                attachments: notice.attachments ?? [],
                attachmentItems: notice.attachmentItems ?? [],
                summary: notice.summary,
                bodyText: notice.bodyText,
                fingerprint: fingerprint,
                changeState: changeState,
                shouldCheckRead: shouldRenderReadChecked,
                shouldCheckImportant: isImportant
            )

            switch mode {
            case .primary:
                if isImportant {
                    importantCourseNotices.append(displayNotice)
                } else if !isRead {
                    if isFresh {
                        freshCourseNotices.append(displayNotice)
                    } else {
                        unreadCourseNotices.append(displayNotice)
                    }
                }
            case .archive:
                if isRead && !isImportant {
                    unreadCourseNotices.append(displayNotice)
                }
            }
        }

        if !importantCourseNotices.isEmpty {
            importantCourses.append(DisplayCourse(title: courseDigest.course, notices: importantCourseNotices))
        }
        if !freshCourseNotices.isEmpty {
            freshCourses.append(DisplayCourse(title: courseDigest.course, notices: freshCourseNotices))
        }
        if !unreadCourseNotices.isEmpty {
            unreadCourses.append(DisplayCourse(title: courseDigest.course, notices: unreadCourseNotices))
        }
    }

    userState.notices = userState.notices.filter { currentNoticeIds.contains($0.key) }
    userState.updatedAt = digest.generatedAt

    var bodyLines: [RenderLine] = []
    var sectionDividerLineIndexes: [Int] = []
    var importantHeadingLineIndexes: [Int] = []
    var freshHeadingLineIndexes: [Int] = []
    var unreadHeadingLineIndexes: [Int] = []
    var courseHeadingLineIndexes: [Int] = []
    var noticeMetaLineIndexes: [Int] = []
    var attachmentHeadingLineIndexes: [Int] = []
    var pendingNotices: [(notice: DisplayNotice, sectionLineIndex: Int, readLineIndex: Int, importantLineIndex: Int)] = []

    let visibleFreshCount = freshCourses.reduce(0) { $0 + $1.notices.count }
    let visibleUnreadCount = unreadCourses.reduce(0) { $0 + $1.notices.count }
    let visibleImportantCount = importantCourses.reduce(0) { $0 + $1.notices.count }
    let archivedCount = mode == .archive ? visibleUnreadCount : 0

    func appendLine(
        _ text: String,
        checklist: Bool = false,
        bold: Bool = false,
        fontSize: CGFloat = noticeBodyFontSize
    ) {
        bodyLines.append(
            RenderLine(
                text: text,
                isChecklist: checklist,
                isBold: bold,
                fontSize: fontSize
            )
        )
    }

    func appendSectionDivider() {
        sectionDividerLineIndexes.append(bodyLines.count)
        appendLine("--------------")
    }

    func appendNoticeGuidanceBlock(includeFreshGuidance: Bool) {
        appendLine("")
        appendLine("체크 안내", bold: true, fontSize: noticeMetaFontSize)
        appendLine(noticeReadGuidanceLine, fontSize: noticeMetaFontSize)
        appendLine(noticeImportantGuidanceLine, fontSize: noticeMetaFontSize)
        if includeFreshGuidance {
            appendLine(noticeFreshGuidanceLine, fontSize: noticeMetaFontSize)
        }
    }

    appendLine(noteTitle, bold: true, fontSize: noticeDocumentTitleFontSize)
    if mode == .primary {
        let summaryLine =
            "기준 시각: \(digest.generatedAt) · 중요 \(visibleImportantCount)건 · 새로운 \(visibleFreshCount)건 · 읽지 않음 \(visibleUnreadCount)건 · 새 \(digest.newCount)건 · 수정 \(digest.updatedCount)건 · 전체 \(digest.noticeCount)건"
        appendLine(summaryLine, bold: true, fontSize: noticeSummaryFontSize)
        appendNoticeGuidanceBlock(includeFreshGuidance: true)
    } else {
        let summaryLine = "기준 시각: \(digest.generatedAt) · 확인 \(archivedCount)건"
        appendLine(summaryLine, bold: true, fontSize: noticeSummaryFontSize)
        appendNoticeGuidanceBlock(includeFreshGuidance: false)
    }
    appendLine("")

    func appendNotice(_ notice: DisplayNotice) {
        let normalizedTitle = oneLine(notice.displayTitle.isEmpty ? notice.title : notice.displayTitle)
        let finalTitle = normalizedTitle.isEmpty ? "(제목 없음)" : normalizedTitle
        let sectionLineIndex = bodyLines.count
        appendLine(finalTitle, bold: true, fontSize: noticeItemTitleFontSize)

        let readLineIndex = bodyLines.count
        appendLine(readChecklistLabel, checklist: true)
        let importantLineIndex = bodyLines.count
        appendLine(importantChecklistLabel, checklist: true)

        var metaParts: [String] = []
        switch notice.changeState {
        case .new:
            metaParts.append("새 공지")
        case .updated:
            metaParts.append("수정 공지")
        case .stable:
            break
        }
        let postedAt = oneLine(notice.postedAt ?? "")
        if !postedAt.isEmpty {
            metaParts.append("게시일: \(postedAt)")
        }
        let attachmentCount = max(notice.attachments.count, notice.attachmentItems.count)
        if attachmentCount > 0 {
            metaParts.append("첨부: \(attachmentCount)개")
        }
        if !metaParts.isEmpty {
            let metaLineIndex = bodyLines.count
            let metaLine = metaParts.joined(separator: " · ")
            appendLine(metaLine, bold: true, fontSize: noticeMetaFontSize)
            noticeMetaLineIndexes.append(metaLineIndex)
        }

        if !notice.attachmentItems.isEmpty {
            appendLine("")
            attachmentHeadingLineIndexes.append(bodyLines.count)
            appendLine("첨부 파일", bold: true, fontSize: noticeMetaFontSize)
            for attachment in notice.attachmentItems {
                let attachmentName = "- \(attachmentDisplayName(attachment))"
                appendLine(attachmentName)
                if let displayPath = attachmentDisplayPath(attachment) {
                    let pathLine = "  위치: \(displayPath)"
                    appendLine(pathLine)
                }
            }
        } else if !notice.attachments.isEmpty {
            appendLine("")
            attachmentHeadingLineIndexes.append(bodyLines.count)
            appendLine("첨부 파일", bold: true, fontSize: noticeMetaFontSize)
            for attachmentName in fallbackAttachmentNames(notice.attachments) {
                let attachmentLine = "- \(attachmentName)"
                appendLine(attachmentLine)
                let pathLine = "  위치: 동기화된 파일 없음"
                appendLine(pathLine)
            }
        }

        let digestEntry = NoticeDigestEntry(
            url: nil,
            articleId: nil,
            title: notice.title,
            postedAt: notice.postedAt,
            attachments: notice.attachments,
            attachmentItems: notice.attachmentItems,
            summary: notice.summary,
            bodyText: notice.bodyText,
            fingerprint: notice.fingerprint,
            changeState: notice.changeState
        )
        let paragraphs = displayParagraphs(digestEntry)
        if paragraphs.isEmpty {
            appendLine("내용 없음")
        } else {
            if !metaParts.isEmpty {
                appendLine("")
            }
            for (paragraphIndex, paragraph) in paragraphs.enumerated() {
                appendLine(paragraph)
                if paragraphIndex < paragraphs.count - 1 {
                    appendLine("")
                }
            }
        }
        appendLine("")

        pendingNotices.append(
            (
                notice: notice,
                sectionLineIndex: sectionLineIndex,
                readLineIndex: readLineIndex,
                importantLineIndex: importantLineIndex
            )
        )
    }

    func appendCourseGroup(_ courses: [DisplayCourse]) {
        for (courseIndex, course) in courses.enumerated() {
            courseHeadingLineIndexes.append(bodyLines.count)
            let heading = "\(course.title) (\(course.notices.count)건)"
            appendLine(heading, bold: true, fontSize: noticeCourseHeadingFontSize)
            appendLine("")
            for notice in course.notices {
                appendNotice(notice)
            }
            if courseIndex < courses.count - 1 {
                appendLine("")
            }
        }
    }

    if mode == .primary {
        var didAppendPrimarySection = false

        func appendPrimarySection(
            title: String,
            count: Int,
            courses: [DisplayCourse],
            headingIndexes: inout [Int]
        ) {
            guard count > 0 else {
                return
            }
            if didAppendPrimarySection {
                appendLine("")
                appendSectionDivider()
                appendLine("")
            }
            headingIndexes.append(bodyLines.count)
            appendLine("\(title) (\(count)건)", bold: true, fontSize: noticeSectionHeadingFontSize)
            appendLine("")
            appendCourseGroup(courses)
            didAppendPrimarySection = true
        }

        appendPrimarySection(
            title: "중요 공지",
            count: visibleImportantCount,
            courses: importantCourses,
            headingIndexes: &importantHeadingLineIndexes
        )
        appendPrimarySection(
            title: "새로운 공지",
            count: visibleFreshCount,
            courses: freshCourses,
            headingIndexes: &freshHeadingLineIndexes
        )
        appendPrimarySection(
            title: "읽지 않은 공지",
            count: visibleUnreadCount,
            courses: unreadCourses,
            headingIndexes: &unreadHeadingLineIndexes
        )

        if !didAppendPrimarySection {
            appendLine(noticePrimaryEmptyGuidanceLine)
        }
    } else {
        appendCourseGroup(unreadCourses)
    }

    if mode == .archive && unreadCourses.isEmpty {
        appendLine(noticeArchiveEmptyGuidanceLine)
    }

    let lines = bodyLines.map(\.text)
    var cursor = 0
    var lineRanges: [LineRange] = []
    for line in lines {
        let length = nsLength(line)
        lineRanges.append(LineRange(location: cursor, length: length))
        cursor += length + 1
    }

    let sectionDividerRanges = sectionDividerLineIndexes.map { lineRanges[$0] }
    let importantHeadingRanges = importantHeadingLineIndexes.map { lineRanges[$0] }
    let freshHeadingRanges = freshHeadingLineIndexes.map { lineRanges[$0] }
    let unreadHeadingRanges = unreadHeadingLineIndexes.map { lineRanges[$0] }
    let courseHeadingRanges = courseHeadingLineIndexes.map { lineRanges[$0] }
    let noticeMetaRanges = noticeMetaLineIndexes.map { lineRanges[$0] }
    let attachmentHeadingRanges = attachmentHeadingLineIndexes.map { lineRanges[$0] }
    let renderedNotices = pendingNotices.map { item in
        RenderedNoticePlan(
            noticeId: item.notice.noticeId,
            course: item.notice.course,
            title: item.notice.title,
            renderedTitle: bodyLines[item.sectionLineIndex].text,
            fingerprint: item.notice.fingerprint,
            sectionLineIndex: item.sectionLineIndex,
            readLineIndex: item.readLineIndex,
            importantLineIndex: item.importantLineIndex,
            sectionRange: lineRanges[item.sectionLineIndex],
            readChecklistRange: lineRanges[item.readLineIndex],
            importantChecklistRange: lineRanges[item.importantLineIndex],
            shouldCheckRead: item.notice.shouldCheckRead,
            shouldCheckImportant: item.notice.shouldCheckImportant
        )
    }

    let plan = RenderPlan(
        bodyLines: bodyLines,
        titleLineIndex: 0,
        summaryLineIndex: 1,
        sectionDividerLineIndexes: sectionDividerLineIndexes,
        importantHeadingLineIndexes: importantHeadingLineIndexes,
        freshHeadingLineIndexes: freshHeadingLineIndexes,
        unreadHeadingLineIndexes: unreadHeadingLineIndexes,
        courseHeadingLineIndexes: courseHeadingLineIndexes,
        noticeMetaLineIndexes: noticeMetaLineIndexes,
        attachmentHeadingLineIndexes: attachmentHeadingLineIndexes,
        titleRange: lineRanges[0],
        summaryRange: lineRanges[1],
        sectionDividerRanges: sectionDividerRanges,
        importantHeadingRanges: importantHeadingRanges,
        freshHeadingRanges: freshHeadingRanges,
        unreadHeadingRanges: unreadHeadingRanges,
        courseHeadingRanges: courseHeadingRanges,
        noticeMetaRanges: noticeMetaRanges,
        attachmentHeadingRanges: attachmentHeadingRanges,
        renderedNotices: renderedNotices,
        visibleUnreadCount: visibleUnreadCount,
        visibleImportantCount: visibleImportantCount
    )
    return PlanBuildResult(plan: plan, currentNoticeIds: currentNoticeIds)
}

func renderBodyLines(
    context: NotesEditorContext,
    noteTitle: String,
    noteID: String?,
    lines: [RenderLine],
    strategy: RenderStrategy
) {
    _ = strategy
    ensureTypingTargetReady(context: context, noteTitle: noteTitle, noteID: noteID)
    setAttr(context.textArea, kAXValueAttribute, "" as CFTypeRef)
    Thread.sleep(forTimeInterval: initialEditorClearDelay)

    var zero = CFRange(location: 0, length: 0)
    guard let selection = AXValueCreate(.cfRange, &zero) else {
        fail("Failed to create caret range.")
    }
    setAttr(context.textArea, kAXSelectedTextRangeAttribute, selection)
    setAttr(context.textArea, kAXFocusedAttribute, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: initialEditorFocusDelay)
    setChecklistMode(context, enabled: false)
    let plaintext = lines.map(\.text).joined(separator: "\n")
    let html = """
<html><body>
\(lines.map { line in
    let style = htmlStyle(for: line)
    if line.text.isEmpty {
        return "<div style=\"\(style)\"><span style=\"\(style)\"><br></span></div>"
    }
    let escapedText = htmlEscaped(line.text)
    let content = line.isBold ? "<b>\(escapedText)</b>" : escapedText
    return "<div style=\"\(style)\"><span style=\"\(style)\">\(content)</span><br></div>"
}.joined(separator: "\n"))
</body></html>
"""
    let attributed = NSMutableAttributedString()
    for (offset, line) in lines.enumerated() {
        let font = line.isBold
            ? NSFont.boldSystemFont(ofSize: line.fontSize)
            : NSFont.systemFont(ofSize: line.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]
        attributed.append(NSAttributedString(string: line.text, attributes: attributes))
        if offset < lines.count - 1 {
            attributed.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
    }
    paste(context.app, text: plaintext, html: html, attributedText: attributed)
    Thread.sleep(forTimeInterval: finalChecklistDisableDelay)
}

func renderNativeNoteOnce(
    context: NotesEditorContext,
    noteTitle: String,
    noteID: String?,
    plan: RenderPlan,
    strategy: RenderStrategy
) -> (collapsedSections: Int, issues: [String]) {
    timingLog("render_once_start note=\(noteTitle) strategy=\(strategy)")
    timingLog("render_body_start note=\(noteTitle)")
    renderBodyLines(
        context: context,
        noteTitle: noteTitle,
        noteID: noteID,
        lines: plan.bodyLines,
        strategy: strategy
    )
    timingLog("render_body_finish note=\(noteTitle)")

    let initialText = loadCaptureText(
        textArea: context.textArea,
        expectedTitles: plan.renderedNotices.map(\.title)
    )
    let initialPlanLineRanges = resolvedPlanLineRanges(
        currentText: initialText,
        bodyLines: plan.bodyLines
    )
    let initialResolvedNotices = initialPlanLineRanges.map {
        resolveRenderedNoticeRanges(
            lineRanges: $0,
            renderedNotices: plan.renderedNotices
        )
    } ?? resolveRenderedNoticeRanges(
        currentText: initialText,
        renderedNotices: plan.renderedNotices
    )

    timingLog("checklist_format_start note=\(noteTitle) count=\(initialResolvedNotices.count * 2)")
    applyChecklistFormatting(
        context: context,
        noteTitle: noteTitle,
        noteID: noteID,
        currentText: initialText,
        resolvedNotices: initialResolvedNotices
    )
    timingLog("checklist_format_finish note=\(noteTitle)")

    let checklistFormattedText = loadCaptureText(
        textArea: context.textArea,
        expectedTitles: plan.renderedNotices.map(\.title)
    )
    let checklistFormattedRanges = resolvedPlanLineRanges(
        currentText: checklistFormattedText,
        bodyLines: plan.bodyLines
    )
    let checklistResolvedNotices = checklistFormattedRanges.map {
        resolveRenderedNoticeRanges(
            lineRanges: $0,
            renderedNotices: plan.renderedNotices
        )
    } ?? resolveRenderedNoticeRanges(
        currentText: checklistFormattedText,
        renderedNotices: plan.renderedNotices
    )

    timingLog("checklist_keep_in_place_start note=\(noteTitle)")
    ensureCheckedItemsStayInPlace(
        app: context.app,
        textArea: context.textArea,
        resolvedNotices: checklistResolvedNotices
    )
    timingLog("checklist_keep_in_place_finish note=\(noteTitle)")

    timingLog("checklist_state_apply_start note=\(noteTitle)")
    for resolved in checklistResolvedNotices {
        if resolved.notice.shouldCheckRead {
            _ = markChecklistChecked(
                app: context.app,
                textArea: context.textArea,
                range: resolved.readRange,
                expectedLabel: readChecklistLabel
            )
        }
        if resolved.notice.shouldCheckImportant {
            _ = markChecklistChecked(
                app: context.app,
                textArea: context.textArea,
                range: resolved.importantRange,
                expectedLabel: importantChecklistLabel
            )
        }
    }

    ensureChecklistStates(
        app: context.app,
        textArea: context.textArea,
        resolvedNotices: checklistResolvedNotices
    )
    timingLog("checklist_state_apply_finish note=\(noteTitle)")

    func applyStyle(_ range: LineRange, menuItems: [String], fallbackToBold: Bool = false) {
        let selectionRange = paragraphSelectionRange(in: initialText, lineRange: range)
        guard selectRangeForFormatting(
            context: context,
            range: selectionRange,
            noteTitle: noteTitle,
            noteID: noteID
        ) else {
            return
        }
        activateApplication(pid: elementPID(context.app))
        if !pressMenuIfAvailable(context.app, menuItems), fallbackToBold {
            ensureTypingTargetReady(context: context, noteTitle: noteTitle, noteID: noteID)
            _ = pressMenuIfAvailable(context.app, ["굵게", "Bold"])
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    func applyBold(_ range: LineRange) {
        guard selectRangeForFormatting(
            context: context,
            range: range,
            noteTitle: noteTitle,
            noteID: noteID
        ) else {
            return
        }
        activateApplication(pid: elementPID(context.app))
        if !pressMenuIfAvailable(context.app, ["굵게", "Bold"]) {
            ensureTypingTargetReady(context: context, noteTitle: noteTitle, noteID: noteID)
            sendCommandKey(11, targetPID: elementPID(context.app))
        }
        Thread.sleep(forTimeInterval: 0.06)
    }

    let styledLineRanges = checklistFormattedRanges
    var boldValidationTargets: [StyleValidationTarget] = []
    var rememberedBoldTargets = Set<String>()

    func lineRange(_ index: Int, fallback: LineRange) -> LineRange {
        guard let styledLineRanges, index >= 0, index < styledLineRanges.count else {
            return fallback
        }
        return styledLineRanges[index]
    }

    func rememberBoldTarget(_ label: String, _ range: LineRange) {
        guard range.length > 0 else {
            return
        }
        let key = "\(range.location):\(range.length):\(label)"
        guard rememberedBoldTargets.insert(key).inserted else {
            return
        }
        boldValidationTargets.append(StyleValidationTarget(label: label, range: range))
    }

    func rememberReadabilityTarget(_ label: String, _ range: LineRange) {
        guard range.length > 0 else {
            return
        }
        rememberBoldTarget(label, range)
    }

    func rememberReadabilityFormattingTargets() {
        timingLog("readability_validation_targets_start note=\(noteTitle)")

        rememberReadabilityTarget(
            "title",
            lineRange(plan.titleLineIndex, fallback: plan.titleRange)
        )
        rememberReadabilityTarget(
            "summary",
            lineRange(plan.summaryLineIndex, fallback: plan.summaryRange)
        )

        for (offset, index) in plan.importantHeadingLineIndexes.enumerated() {
            rememberReadabilityTarget(
                "important heading \(offset + 1)",
                lineRange(index, fallback: plan.importantHeadingRanges[offset])
            )
        }
        for (offset, index) in plan.freshHeadingLineIndexes.enumerated() {
            rememberReadabilityTarget(
                "fresh heading \(offset + 1)",
                lineRange(index, fallback: plan.freshHeadingRanges[offset])
            )
        }
        for (offset, index) in plan.unreadHeadingLineIndexes.enumerated() {
            rememberReadabilityTarget(
                "unread heading \(offset + 1)",
                lineRange(index, fallback: plan.unreadHeadingRanges[offset])
            )
        }
        for (offset, index) in plan.courseHeadingLineIndexes.enumerated() {
            rememberReadabilityTarget(
                "course heading \(offset + 1)",
                lineRange(index, fallback: plan.courseHeadingRanges[offset])
            )
        }
        for (offset, notice) in plan.renderedNotices.enumerated() {
            rememberReadabilityTarget(
                "notice title \(offset + 1)",
                lineRange(notice.sectionLineIndex, fallback: notice.sectionRange)
            )
        }
        for (offset, index) in plan.noticeMetaLineIndexes.enumerated() {
            rememberReadabilityTarget(
                "notice metadata \(offset + 1)",
                lineRange(index, fallback: plan.noticeMetaRanges[offset])
            )
        }
        for (offset, index) in plan.attachmentHeadingLineIndexes.enumerated() {
            rememberReadabilityTarget(
                "attachment heading \(offset + 1)",
                lineRange(index, fallback: plan.attachmentHeadingRanges[offset])
            )
        }

        timingLog("readability_validation_targets_finish note=\(noteTitle) bold_targets=\(boldValidationTargets.count)")
    }

    if uiStyleMenuFormattingEnabled {
        timingLog("style_apply_start note=\(noteTitle)")
        applyStyle(
            lineRange(plan.titleLineIndex, fallback: plan.titleRange),
            menuItems: ["제목", "Title"],
            fallbackToBold: true
        )

        let summaryRange = lineRange(plan.summaryLineIndex, fallback: plan.summaryRange)
        applyBold(summaryRange)
        rememberBoldTarget("summary", summaryRange)

        for (offset, index) in plan.importantHeadingLineIndexes.enumerated() {
            let heading = lineRange(index, fallback: plan.importantHeadingRanges[offset])
            applyStyle(heading, menuItems: ["제목", "Title"], fallbackToBold: true)
        }

        for (offset, index) in plan.freshHeadingLineIndexes.enumerated() {
            let heading = lineRange(index, fallback: plan.freshHeadingRanges[offset])
            applyStyle(heading, menuItems: ["제목", "Title"], fallbackToBold: true)
        }

        for (offset, index) in plan.unreadHeadingLineIndexes.enumerated() {
            let heading = lineRange(index, fallback: plan.unreadHeadingRanges[offset])
            applyStyle(heading, menuItems: ["제목", "Title"], fallbackToBold: true)
        }

        for (offset, index) in plan.courseHeadingLineIndexes.enumerated() {
            let fallback = plan.courseHeadingRanges[offset]
            applyStyle(lineRange(index, fallback: fallback), menuItems: ["머리말", "Heading"], fallbackToBold: true)
        }

        for notice in plan.renderedNotices {
            let titleRange = lineRange(notice.sectionLineIndex, fallback: notice.sectionRange)
            applyStyle(titleRange, menuItems: ["부머리말", "Subheading"], fallbackToBold: true)
        }

        for (offset, index) in plan.noticeMetaLineIndexes.enumerated() {
            let meta = lineRange(index, fallback: plan.noticeMetaRanges[offset])
            applyBold(meta)
            rememberBoldTarget("notice metadata \(offset + 1)", meta)
        }

        for (offset, index) in plan.attachmentHeadingLineIndexes.enumerated() {
            let attachmentHeading = lineRange(index, fallback: plan.attachmentHeadingRanges[offset])
            applyBold(attachmentHeading)
            rememberBoldTarget("attachment heading \(offset + 1)", attachmentHeading)
        }
        timingLog("style_apply_finish note=\(noteTitle) bold_targets=\(boldValidationTargets.count)")
    } else {
        timingLog(
            "style_apply_skip note=\(noteTitle) reason=rich_paste_default notices=\(plan.renderedNotices.count) "
                + "lines=\(plan.bodyLines.count)"
        )
    }

    rememberReadabilityFormattingTargets()

    var currentText = loadCaptureText(
        textArea: context.textArea,
        expectedTitles: plan.renderedNotices.map(\.title)
    )
    var finalPlanLineRanges = resolvedPlanLineRanges(
        currentText: currentText,
        bodyLines: plan.bodyLines
    )
    var resolvedNotices = finalPlanLineRanges.map {
        resolveRenderedNoticeRanges(
            lineRanges: $0,
            renderedNotices: plan.renderedNotices
        )
    } ?? resolveRenderedNoticeRanges(
        currentText: currentText,
        renderedNotices: plan.renderedNotices
    )

    ensureChecklistStates(
        app: context.app,
        textArea: context.textArea,
        resolvedNotices: resolvedNotices
    )

    var validationIssues: [String] = []
    var checkedStateIssues: [String] = []
    var styleIssues: [String] = []
    timingLog("validation_start note=\(noteTitle)")
    for attempt in 0..<12 {
        currentText = loadCaptureText(
            textArea: context.textArea,
            expectedTitles: plan.renderedNotices.map(\.title)
        )
        finalPlanLineRanges = resolvedPlanLineRanges(
            currentText: currentText,
            bodyLines: plan.bodyLines
        )
        resolvedNotices = finalPlanLineRanges.map {
            resolveRenderedNoticeRanges(
                lineRanges: $0,
                renderedNotices: plan.renderedNotices
            )
        } ?? resolveRenderedNoticeRanges(
            currentText: currentText,
            renderedNotices: plan.renderedNotices
        )

        validationIssues = checklistLayoutIssues(
            textArea: context.textArea,
            currentText: currentText,
            resolvedNotices: resolvedNotices
        )
        checkedStateIssues = checklistStateIssues(
            textArea: context.textArea,
            currentText: currentText,
            resolvedNotices: resolvedNotices
        )
        if boldValidationTargets.isEmpty {
            styleIssues = ["readability style validation targets missing"]
        } else if ProcessInfo.processInfo.environment["NOTICE_NATIVE_INLINE_HTML_STYLE_VERIFY"] == "1" {
            let htmlStyleIssues = htmlBoldStyleIssues(
                noteTitle: noteTitle,
                noteID: noteID,
                currentText: currentText,
                targets: boldValidationTargets
            )
            styleIssues = htmlStyleIssues
        } else {
            styleIssues = []
        }

        if validationIssues.isEmpty && checkedStateIssues.isEmpty && styleIssues.isEmpty {
            break
        }

        if attempt < 11 {
            Thread.sleep(forTimeInterval: 0.18)
        }
    }
    timingLog(
        "validation_finish note=\(noteTitle) checklist_layout=\(validationIssues.count) "
            + "check_state=\(checkedStateIssues.count) style=\(styleIssues.count)"
    )

    if !validationIssues.isEmpty || !checkedStateIssues.isEmpty || !styleIssues.isEmpty {
        return (0, validationIssues + checkedStateIssues + styleIssues)
    }

    var collapsedSections = 0
    if collapseNoticeSectionsEnabled {
        let noticeCollapseRanges = plan.renderedNotices.map {
            lineRange($0.sectionLineIndex, fallback: $0.sectionRange)
        }
        for range in noticeCollapseRanges.reversed() {
            guard selectRange(context.textArea, location: range.location, length: range.length) else {
                continue
            }
            if pressMenuIfAvailable(context.app, ["섹션 접기", "Collapse Section"]) {
                collapsedSections += 1
            }
            Thread.sleep(forTimeInterval: 0.06)
        }

        let courseCollapseRanges = plan.courseHeadingLineIndexes.enumerated().map { offset, index in
            lineRange(index, fallback: plan.courseHeadingRanges[offset])
        }
        for range in courseCollapseRanges.reversed() {
            guard selectRange(context.textArea, location: range.location, length: range.length) else {
                continue
            }
            if pressMenuIfAvailable(context.app, ["섹션 접기", "Collapse Section"]) {
                collapsedSections += 1
            }
            Thread.sleep(forTimeInterval: 0.06)
        }

        let sectionCollapseRanges =
            plan.importantHeadingLineIndexes.enumerated().map { offset, index in
                lineRange(index, fallback: plan.importantHeadingRanges[offset])
            }
            + plan.freshHeadingLineIndexes.enumerated().map { offset, index in
                lineRange(index, fallback: plan.freshHeadingRanges[offset])
            }
            + plan.unreadHeadingLineIndexes.enumerated().map { offset, index in
                lineRange(index, fallback: plan.unreadHeadingRanges[offset])
            }
        for range in sectionCollapseRanges.reversed() {
            guard selectRange(context.textArea, location: range.location, length: range.length) else {
                continue
            }
            if pressMenuIfAvailable(context.app, ["섹션 접기", "Collapse Section"]) {
                collapsedSections += 1
            }
            Thread.sleep(forTimeInterval: 0.06)
        }
    }

    return (collapsedSections, [])
}

func renderNativeNote(
    context: NotesEditorContext,
    noteTitle: String,
    noteID: String?,
    plan: RenderPlan
) -> Int {
    let firstPass = renderNativeNoteOnce(
        context: context,
        noteTitle: noteTitle,
        noteID: noteID,
        plan: plan,
        strategy: .chunked
    )
    if firstPass.issues.isEmpty {
        return firstPass.collapsedSections
    }

    debugLog(
        "Detected checklist layout issues in \(noteTitle); retrying with conservative render. "
            + "Unexpected user-added checklist lines will be deleted. "
            + firstPass.issues.prefix(6).joined(separator: " | ")
    )

    let secondPass = renderNativeNoteOnce(
        context: context,
        noteTitle: noteTitle,
        noteID: noteID,
        plan: plan,
        strategy: .conservative
    )
    if secondPass.issues.isEmpty {
        return secondPass.collapsedSections
    }

    let preview = secondPass.issues.prefix(8).joined(separator: " | ")
    fail("Detected unexpected checklist layout in \(noteTitle): \(preview)")
}

func renderContentHash(for plan: RenderPlan) -> String {
    var components: [String] = [nativeNoticeRenderStyleVersion]
    components.reserveCapacity(plan.bodyLines.count + plan.renderedNotices.count + 2)
    for line in plan.bodyLines {
        components.append(
            "\(line.isChecklist ? "1" : "0")|\(line.isBold ? "1" : "0")|"
                + "\(cssFontSize(line.fontSize))|\(line.text)"
        )
    }
    components.append("::")
    for notice in plan.renderedNotices {
        components.append(
            "\(notice.noticeId)|\(notice.shouldCheckRead ? "1" : "0")|\(notice.shouldCheckImportant ? "1" : "0")"
        )
    }
    let digest = SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func renderPlaintext(for plan: RenderPlan) -> String {
    plan.bodyLines.map(\.text).joined(separator: "\n")
}

func normalizedPlaintextForHash(_ text: String) -> String {
    canonicalText(text)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
}

func plaintextHash(for text: String) -> String {
    let digest = SHA256.hash(data: Data(normalizedPlaintextForHash(text).utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func renderStateFile(
    noteTitle: String,
    noteID: String?,
    timestamp: String,
    plan: RenderPlan
) -> NoticeRenderStateFile {
    NoticeRenderStateFile(
        version: nativeNoticeRenderStateVersion,
        styleVersion: nativeNoticeRenderStyleVersion,
        updatedAt: timestamp,
        noteTitle: noteTitle,
        noteID: noteID,
        renderedNotices: plan.renderedNotices.map {
            RenderedNoticeState(
                noticeId: $0.noticeId,
                course: $0.course,
                title: $0.title,
                renderedTitle: $0.renderedTitle,
                fingerprint: $0.fingerprint,
                sectionRange: $0.sectionRange,
                readChecklistRange: $0.readChecklistRange,
                importantChecklistRange: $0.importantChecklistRange
            )
        },
        contentHash: renderContentHash(for: plan),
        plaintextHash: plaintextHash(for: renderPlaintext(for: plan))
    )
}

func renderManagedNoticeNote(
    noteTitle: String,
    noteID: String?,
    timestamp: String,
    plan: RenderPlan,
    previousRenderState: NoticeRenderStateFile?,
    renderStatePath: String,
    allowNoOpSkip: Bool,
    skipActivation: Bool,
    notesPID: pid_t?
) -> Int {
    timed("renderManagedNoticeNote title=\(noteTitle)") {
        let effectiveNoteID = noteID ?? previousRenderState?.noteID
        let resolvedNoteID = existingNoteID(noteTitle: noteTitle, noteID: effectiveNoteID)
        let desiredRenderState = renderStateFile(
            noteTitle: noteTitle,
            noteID: resolvedNoteID ?? effectiveNoteID,
            timestamp: timestamp,
            plan: plan
        )
        if allowNoOpSkip,
           previousRenderState?.contentHash == desiredRenderState.contentHash,
           let resolvedNoteID,
           let snapshot = noteSnapshot(noteID: resolvedNoteID),
           let expectedPlaintextHash = desiredRenderState.plaintextHash,
           plaintextHash(for: snapshot.plaintext) == expectedPlaintextHash {
            writeJSON(desiredRenderState, path: renderStatePath)
            return 0
        }
        if allowNoOpSkip,
           previousRenderState?.contentHash == desiredRenderState.contentHash,
           resolvedNoteID != nil {
            debugLog("Skipping no-op render disabled because plaintext drifted for \(noteTitle)")
        }
        if !skipActivation {
            ensureNoteVisible(noteTitle: noteTitle, noteID: effectiveNoteID)
        }
        let activeNoteID = existingNoteID(noteTitle: noteTitle, noteID: effectiveNoteID)
        let renderContext = resolveNotesEditorContext(
            notesPID: notesPID,
            noteTitle: noteTitle,
            noteID: activeNoteID ?? effectiveNoteID
        )
        let collapsedSections = renderNativeNote(
            context: renderContext,
            noteTitle: noteTitle,
            noteID: activeNoteID ?? effectiveNoteID,
            plan: plan
        )
        if !skipActivation, effectiveNoteID == nil {
            cleanupDuplicateNotes(noteTitle: noteTitle)
        }
        let persistedNoteID = existingNoteID(noteTitle: noteTitle, noteID: activeNoteID ?? effectiveNoteID)
        writeJSON(
            renderStateFile(
                noteTitle: noteTitle,
                noteID: persistedNoteID ?? activeNoteID ?? effectiveNoteID,
                timestamp: timestamp,
                plan: plan
            ),
            path: renderStatePath
        )
        return collapsedSections
    }
}

@main
enum NoticeNativeNoteMain {
    static func main() {
        let arguments = parseArgs()
        let digest = loadDigest(path: arguments.digestPath)
        var userState = loadOptionalJSON(NoticeUserStateFile.self, path: arguments.noticeStatePath)
            ?? NoticeUserStateFile(version: 1, updatedAt: digest.generatedAt, notices: [:])
        let previousRenderState = loadOptionalJSON(NoticeRenderStateFile.self, path: arguments.renderStatePath)
        let previousArchiveRenderState = loadOptionalJSON(
            NoticeRenderStateFile.self,
            path: arguments.archiveRenderStatePath
        )
        let primaryNoteID = arguments.noteID ?? previousRenderState?.noteID
        let archiveNoteID = arguments.archiveNoteID ?? previousArchiveRenderState?.noteID

        if arguments.mode != "render" {
            if arguments.target != "archive" {
                captureRenderedNoticeState(
                    noteTitle: arguments.noteTitle,
                    noteID: primaryNoteID,
                    displayMode: .primary,
                    previousRenderState: previousRenderState,
                    userState: &userState,
                    timestamp: digest.generatedAt,
                    skipActivation: arguments.skipNoteActivation,
                    notesPID: arguments.notesPID
                )
            }
            if arguments.target != "primary" {
                captureRenderedNoticeState(
                    noteTitle: arguments.archiveNoteTitle,
                    noteID: archiveNoteID,
                    displayMode: .archive,
                    previousRenderState: previousArchiveRenderState,
                    userState: &userState,
                    timestamp: digest.generatedAt,
                    skipActivation: arguments.skipNoteActivation,
                    notesPID: arguments.notesPID
                )
            }
            writeJSON(userState, path: arguments.noticeStatePath)

            if arguments.mode == "capture" {
                let readCount = userState.notices.values.reduce(into: 0) { count, state in
                    let fingerprint = state.fingerprint ?? ""
                    if !fingerprint.isEmpty, state.readFingerprint == fingerprint {
                        count += 1
                    }
                }
                let importantCount = userState.notices.values.reduce(into: 0) { count, state in
                    if state.important == true {
                        count += 1
                    }
                }
                let capturedNoteTitle = arguments.target == "archive" ? arguments.archiveNoteTitle : arguments.noteTitle
                print(
                    "Captured native notice note state: \(capturedNoteTitle) "
                        + "read=\(readCount) important=\(importantCount)"
                        + " ui_capture=1"
                )
                exit(0)
            }
        }

        let buildResult = buildRenderPlan(
            noteTitle: arguments.noteTitle,
            digest: digest,
            userState: &userState,
            mode: .primary
        )
        let archiveBuildResult = buildRenderPlan(
            noteTitle: arguments.archiveNoteTitle,
            digest: digest,
            userState: &userState,
            mode: .archive
        )
        let primaryNoticeIDs = Set(buildResult.plan.renderedNotices.map(\.noticeId))
        let archiveNoticeIDs = Set(archiveBuildResult.plan.renderedNotices.map(\.noticeId))
        let overlappingNoticeIDs = primaryNoticeIDs.intersection(archiveNoticeIDs)
        if !overlappingNoticeIDs.isEmpty {
            fail(
                "A notice was rendered into both managed Notes. "
                    + "This breaks checklist capture consistency."
            )
        }
        let archivedCollapsedSections = arguments.target == "primary" ? 0 : renderManagedNoticeNote(
            noteTitle: arguments.archiveNoteTitle,
            noteID: archiveNoteID,
            timestamp: digest.generatedAt,
            plan: archiveBuildResult.plan,
            previousRenderState: previousArchiveRenderState,
            renderStatePath: arguments.archiveRenderStatePath,
            allowNoOpSkip: true,
            skipActivation: arguments.skipNoteActivation,
            notesPID: arguments.notesPID
        )
        let collapsedSections = arguments.target == "archive" ? 0 : renderManagedNoticeNote(
            noteTitle: arguments.noteTitle,
            noteID: primaryNoteID,
            timestamp: digest.generatedAt,
            plan: buildResult.plan,
            previousRenderState: previousRenderState,
            renderStatePath: arguments.renderStatePath,
            allowNoOpSkip: true,
            skipActivation: arguments.skipNoteActivation,
            notesPID: arguments.notesPID
        )
        if !arguments.skipNoteActivation, arguments.target != "archive" {
            _ = ensureExistingNoteVisible(noteTitle: arguments.noteTitle, noteID: primaryNoteID)
        }
        writeJSON(userState, path: arguments.noticeStatePath)

        print(
            "Updated native notice notes: \(arguments.noteTitle) "
                + "visible=\(buildResult.plan.renderedNotices.count) "
                + "unread=\(buildResult.plan.visibleUnreadCount) "
                + "important=\(buildResult.plan.visibleImportantCount) "
                + "archived=\(archiveBuildResult.plan.renderedNotices.count) "
                + "collapsed_main=\(collapsedSections) "
                + "collapsed_archive=\(archivedCollapsedSections)"
        )
    }
}
