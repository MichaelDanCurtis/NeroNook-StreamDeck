import Foundation

/// Optional agenda-v1 contribution. Integrations and credentials remain provider-owned.
public struct PluginAgendaEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var source: String
    public var color: String
    public var location: String?
    public var url: URL?
    public var meetingURL: URL?
    public var externalID: String?
    public var isTask: Bool
    public init(id: String, title: String, start: Date, end: Date, allDay: Bool = false, source: String, color: String = "#4285F4", location: String? = nil, url: URL? = nil, meetingURL: URL? = nil, externalID: String? = nil, isTask: Bool = false) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.source = source; self.color = color; self.location = location; self.url = url; self.meetingURL = meetingURL; self.externalID = externalID; self.isTask = isTask
    }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 512, title.count <= 300, source.count <= 100,
              (location?.count ?? 0) <= 300, (externalID?.count ?? 0) <= 512,
              start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end >= start,
              color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw ModuleProblem("Invalid agenda entry.") }
        for url in [url, meetingURL].compactMap({ $0 }) {
            guard url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 2048 else { throw ModuleProblem("Invalid agenda link.") }
        }
    }
}
public struct PluginAgenda: Codable, Equatable, Sendable {
    public var date: Date
    public var fetchedAt: Date
    public var expiresAt: Date
    public var entries: [PluginAgendaEntry]
    public init(date: Date, fetchedAt: Date, expiresAt: Date, entries: [PluginAgendaEntry]) {
        self.date = date; self.fetchedAt = fetchedAt; self.expiresAt = expiresAt; self.entries = entries
    }
    public func validate(now: Date = Date()) throws {
        guard date.timeIntervalSince1970.isFinite, fetchedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              fetchedAt <= now.addingTimeInterval(30), expiresAt >= fetchedAt, expiresAt.timeIntervalSince(fetchedAt) <= 600,
              entries.count <= 64, Set(entries.map(\.id)).count == entries.count else { throw ModuleProblem("Invalid agenda contribution.") }
        try entries.forEach { try $0.validate() }
    }
}
