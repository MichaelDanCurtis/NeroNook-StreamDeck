import Foundation

/// Optional read-only calendar adapter on actions-v1. Provider credentials and
/// recurrence semantics stay with the provider; consumers store opaque identity.
public struct PluginCalendarReference: Codable, Equatable, Hashable, Sendable {
    public var calendar: String
    public var event: String
    public var occurrence: String
    public init(calendar: String, event: String, occurrence: String) { self.calendar = calendar; self.event = event; self.occurrence = occurrence }
    public func validate() throws {
        guard [calendar, event, occurrence].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              try PluginCalendarContract.json(self).utf8.count <= 1800 else { throw ModuleProblem("Invalid calendar reference.") }
    }
}
public struct PluginCalendarEvent: Codable, Equatable, Sendable {
    public var reference: PluginCalendarReference
    public var title: String
    public var calendarName: String
    public var start: Double
    public var end: Double
    public var allDay: Bool
    public var url: URL?
    public var meetingURL: URL?
    public init(reference: PluginCalendarReference, title: String, calendarName: String, start: Date, end: Date, allDay: Bool = false, url: URL? = nil, meetingURL: URL? = nil) {
        self.reference = reference; self.title = title; self.calendarName = calendarName
        self.start = start.timeIntervalSince1970; self.end = end.timeIntervalSince1970; self.allDay = allDay; self.url = url; self.meetingURL = meetingURL
    }
    public func validate() throws {
        try reference.validate()
        guard !title.isEmpty, title.utf8.count <= 180, calendarName.utf8.count <= 120,
              start.isFinite, end.isFinite, end >= start, (-2_208_988_800...4_133_980_800).contains(start),
              (-2_208_988_800...4_133_980_800).contains(end), try PluginCalendarContract.json(self).utf8.count <= 1900
        else { throw ModuleProblem("Calendar event exceeds the text or date limits.") }
        for value in [url, meetingURL].compactMap({ $0 }) { guard PluginCalendarContract.safeURL(value) else { throw ModuleProblem("Invalid calendar website link.") } }
    }
}
public enum PluginCalendarContract {
    public static let list = PluginRegisteredAction("list_calendar_events", title: "Read calendar events for a selected day",
        input: .init([.init("start", .number), .init("end", .number), .init("offset", .number, minimum: 0, maximum: 10000)]),
        output: .init([.init("events", .string), .init("next", .number, minimum: -1), .init("total", .number), .init("observed_at", .number)]), cancellable: true, timeoutSeconds: 60)
    public static let read = PluginRegisteredAction("read_calendar_event", title: "Verify a linked calendar event",
        input: .init([.init("reference", .string)]), output: .init([.init("event", .string), .init("status", .string), .init("observed_at", .number)]), cancellable: true, timeoutSeconds: 60)
    public static func accepts(_ entry: PluginCatalogEntry, action: PluginRegisteredAction) -> Bool {
        guard let value = entry.action else { return false }
        return value.id == action.id && value.effect == .readOnly && value.cancellable && value.input == action.input && value.output == action.output && value.timeoutSeconds <= 60
    }
    public static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    public static func safeURL(_ value: URL) -> Bool {
        value.scheme == "https" && value.host?.isEmpty == false && value.user == nil && value.password == nil && value.absoluteString.utf8.count <= 500
    }
    public static func bounded(_ value: String, bytes: Int) -> String { var v = value; while v.utf8.count > bytes { v.removeLast() }; return v }
    public static func range(_ values: [String: PluginValue]) throws -> (start: Date, end: Date, offset: Int) {
        try list.input.validate(values)
        guard case .number(let start) = values["start"], case .number(let end) = values["end"], case .number(let offset) = values["offset"],
              (-2_208_988_800...4_133_980_800).contains(start), end > start, end - start <= 172800,
              end <= 4_133_980_800, offset.rounded() == offset else { throw ModuleProblem("Choose a calendar range of at most two days and a whole-number page.") }
        return (Date(timeIntervalSince1970: start), Date(timeIntervalSince1970: end), Int(offset))
    }
    public static func reference(_ values: [String: PluginValue]) throws -> PluginCalendarReference {
        try read.input.validate(values)
        guard case .string(let json) = values["reference"] else { throw ModuleProblem("Missing calendar reference.") }
        let value = try JSONDecoder().decode(PluginCalendarReference.self, from: Data(json.utf8)); try value.validate(); return value
    }
    public static func page(_ events: [PluginCalendarEvent], offset: Int, now: Date = Date()) throws -> [String: PluginValue] {
        guard events.count <= 10000, offset >= 0, offset <= events.count else { throw ModuleProblem("Calendar list changed. Start again at the first page.") }
        var selected: [PluginCalendarEvent] = []
        for event in events.dropFirst(offset) {
            try event.validate()
            if try json(selected + [event]).utf8.count > 2048 { break }
            selected.append(event); if selected.count == 6 { break }
        }
        guard offset == events.count || !selected.isEmpty else { throw ModuleProblem("Calendar event exceeds the page limit.") }
        return ["events": .string(try json(selected)), "next": .number(offset + selected.count < events.count ? Double(offset + selected.count) : -1), "total": .number(Double(events.count)), "observed_at": .number(now.timeIntervalSince1970)]
    }
    public static func result(_ event: PluginCalendarEvent?, now: Date = Date()) throws -> [String: PluginValue] {
        if let event { try event.validate() }
        return ["event": .string(try event.map(json) ?? ""), "status": .string(event == nil ? "missing" : "found"), "observed_at": .number(now.timeIntervalSince1970)]
    }
}
