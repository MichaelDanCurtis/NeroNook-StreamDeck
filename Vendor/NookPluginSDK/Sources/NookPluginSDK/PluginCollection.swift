import Foundation

/// Semantic, provider-neutral layouts. All actions remain opaque plugin commands.
public struct PluginCollectionItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var detail: String
    public var category: String
    public var symbol: String?
    public var date: Date?
    public var unread: Bool
    public var completed: Bool
    public var action: PluginAction?
    public init(_ id: String, title: String, subtitle: String = "", detail: String = "", category: String = "", symbol: String? = nil, date: Date? = nil, unread: Bool = false, completed: Bool = false, action: PluginAction? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.detail = detail; self.category = category; self.symbol = symbol; self.date = date; self.unread = unread; self.completed = completed; self.action = action
    }
}
public struct PluginCalendarDay: Codable, Equatable, Sendable, Identifiable {
    public var date: Date
    public var action: PluginAction
    public var id: String { action.id }
    public init(date: Date, action: PluginAction) { self.date = date; self.action = action }
}
public struct PluginCollection: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, Sendable { case calendar, inbox, tasks, files }
    public var layout: Layout
    public var title: String
    public var subtitle: String
    public var emptyText: String
    public var items: [PluginCollectionItem]
    public var selectedDate: Date?
    public var days: [PluginCalendarDay]?
    public var actions: [PluginAction]
    public init(_ layout: Layout, title: String, subtitle: String = "", emptyText: String = "No items", items: [PluginCollectionItem] = [], selectedDate: Date? = nil, days: [PluginCalendarDay]? = nil, actions: [PluginAction] = []) {
        self.layout = layout; self.title = title; self.subtitle = subtitle; self.emptyText = emptyText; self.items = items; self.selectedDate = selectedDate; self.days = days; self.actions = actions
    }
    public var displayActions: [PluginAction] { actions + items.compactMap(\.action) + (days ?? []).map(\.action) }
    public func validate() throws {
        guard !title.isEmpty, title.count <= 100, subtitle.count <= 300, emptyText.count <= 500,
              items.count <= 96, Set(items.map(\.id)).count == items.count, actions.count <= 4 else { throw ModuleProblem("Invalid collection size.") }
        for item in items {
            guard ModulePackage.validKey(item.id), !item.title.isEmpty, item.title.count <= 160,
                  item.subtitle.count <= 200, item.detail.count <= 500, item.category.count <= 80,
                  (item.symbol?.count ?? 0) <= 80, item.date.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw ModuleProblem("Invalid collection item.") }
        }
        if layout == .calendar {
            guard let selectedDate, selectedDate.timeIntervalSince1970.isFinite, let days, (28...42).contains(days.count), days.count % 7 == 0,
                  Set(days.map(\.id)).count == days.count, Set(days.map(\.date)).count == days.count,
                  days.allSatisfy({ $0.date.timeIntervalSince1970.isFinite }) else { throw ModuleProblem("Invalid calendar collection.") }
        } else if days != nil || selectedDate != nil { throw ModuleProblem("Dates require a calendar collection.") }
    }
}
