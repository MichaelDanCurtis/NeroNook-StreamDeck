import SwiftUI

/// Native semantic surfaces shared by independent providers. No service APIs live here.
public struct PluginCollectionView: View {
    @Environment(\.pluginAppearance) private var appearance
    public init(collection: PluginCollection, invoke: @escaping (String) -> Void) { self.collection = collection; self.invoke = invoke }
    let collection: PluginCollection
    let invoke: (String) -> Void
    @State private var query = ""
    @State private var filter = "All"
    @State private var selection: String?
    @State private var fileGrid = false
    @State private var sortByName = false
    @State private var reviewing: PluginAction?
    private var calendar: Calendar { .current }
    private var filtered: [PluginCollectionItem] {
        let items = collection.items.filter { item in
            (query.isEmpty || [item.title, item.subtitle, item.category].contains { $0.localizedCaseInsensitiveContains(query) }) &&
            (filter != "Unread" || item.unread) &&
            (filter != "Today" || item.date.map(calendar.isDateInToday) == true) &&
            (filter != "Overdue" || (!item.completed && item.date.map { $0 < calendar.startOfDay(for: Date()) } == true))
        }
        return collection.layout == .files && sortByName ? items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : items
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if collection.layout == .calendar { calendarSurface }
            else {
                toolbar
                if collection.layout == .files { fileHeadings }
                ScrollView {
                    if filtered.isEmpty { emptyState }
                    else if collection.layout == .files && fileGrid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135))], spacing: 10) {
                            ForEach(filtered) { item in fileTile(item) }
                        }.padding(3)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { item in
                                Button { selection = item.id } label: {
                                    switch collection.layout {
                                    case .inbox: inboxRow(item)
                                    case .tasks: taskRow(item)
                                    default: fileRow(item)
                                    }
                                }.buttonStyle(.plain)
                                    .background(selection == item.id ? Color(pluginHex:appearance.palette.accent).opacity(0.15) : Color.clear)
                                    .accessibilityLabel(item.title + ", " + item.subtitle)
                                Divider().opacity(0.35)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let item = filtered.first(where: { $0.id == selection }) { selectedItem(item) }
                footer
            }
        }
        .overlay {
            if let action = reviewing {
                VStack(alignment: .leading, spacing: 14) {
                    Text(action.confirmation ?? action.label).fixedSize(horizontal: false, vertical: true)
                    HStack { Button("Cancel") { reviewing = nil }; Spacer(); Button("Confirm") { reviewing = nil; invoke(action.id) }.buttonStyle(.borderedProminent) }
                }.padding(20).frame(maxWidth: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: collection.displayActions) { actions in if let reviewing, !actions.contains(reviewing) { self.reviewing = nil } }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search \(collection.title.lowercased())", text: $query).textFieldStyle(.roundedBorder)
            if collection.layout == .inbox {
                Picker("Messages", selection: $filter) { Text("All").tag("All"); Text("Unread").tag("Unread") }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
            } else if collection.layout == .tasks {
                Picker("Due date", selection: $filter) { Text("All").tag("All"); Text("Today").tag("Today"); Text("Overdue").tag("Overdue") }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            } else {
                Button { sortByName.toggle() } label: { Label(sortByName ? "Name" : "Recent", systemImage: "arrow.up.arrow.down") }.help("Change file sort order")
                Button { fileGrid.toggle() } label: { Image(systemName: fileGrid ? "list.bullet" : "square.grid.2x2") }.help(fileGrid ? "List view" : "Grid view").accessibilityLabel(fileGrid ? "List view" : "Grid view")
            }
            ForEach(collection.actions) { action in actionButton(action, iconOnly: action.symbol != nil) }
        }
    }
    private func inboxRow(_ item: PluginCollectionItem) -> some View {
        HStack(spacing: 10) {
            Circle().fill(item.unread ? Color(pluginHex:appearance.palette.accent) : .clear).frame(width: 6, height: 6)
            Text(item.subtitle).font(.callout.weight(item.unread ? .semibold : .regular)).lineLimit(1).frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.callout.weight(item.unread ? .semibold : .regular)).lineLimit(1)
                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            dateLabel(item.date)
        }.padding(.horizontal, 10).padding(.vertical, 13).contentShape(Rectangle())
    }
    private func taskRow(_ item: PluginCollectionItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(item.completed ? Color.green : .secondary)
                .accessibilityLabel(item.completed ? "Completed" : "Incomplete")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.callout.weight(.medium)).strikethrough(item.completed).lineLimit(2)
                if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let due = item.date {
                Text(due.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(due < calendar.startOfDay(for: Date()) ? Color.orange : .secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Color.primary.opacity(0.05), in: Capsule())
            } else { Text("No due date").font(.caption).foregroundStyle(.tertiary) }
        }.padding(12).contentShape(Rectangle())
    }
    private var fileHeadings: some View {
        HStack {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            if !fileGrid { Text("Kind").frame(width: 100, alignment: .leading); Text("Modified").frame(width: 95, alignment: .trailing) }
        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 2)
    }
    private func fileRow(_ item: PluginCollectionItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol ?? "doc").font(.title3).foregroundStyle(fileColor(item)).frame(width: 24)
            Text(item.title).font(.callout).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(item.category).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 100, alignment: .leading)
            dateLabel(item.date).frame(width: 95, alignment: .trailing)
        }.padding(12).contentShape(Rectangle())
    }
    private func fileTile(_ item: PluginCollectionItem) -> some View {
        Button { selection = item.id } label: {
            VStack(spacing: 9) {
                Image(systemName: item.symbol ?? "doc").font(.system(size: 32)).foregroundStyle(fileColor(item)).frame(height: 45)
                Text(item.title).font(.callout).lineLimit(2).frame(height: 34)
                Text(item.category).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.padding(12).frame(maxWidth: .infinity).background(selection == item.id ? Color(pluginHex:appearance.palette.accent).opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private func fileColor(_ item: PluginCollectionItem) -> Color {
        switch item.symbol { case "tablecells": return .green; case "rectangle.on.rectangle": return .orange; case "folder.fill": return .cyan; case "doc.richtext": return .red; default: return .blue }
    }
    private func selectedItem(_ item: PluginCollectionItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text(item.detail.isEmpty ? item.subtitle : item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let action = item.action { actionButton(action) }
        }.padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
    private var footer: some View {
        HStack {
            Text("\(filtered.count) \(collection.layout == .inbox ? "messages" : collection.layout == .tasks ? "tasks" : "files")").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(collection.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: collection.layout == .inbox ? "tray" : collection.layout == .tasks ? "checklist" : collection.layout == .files ? "folder" : "calendar").font(.largeTitle).foregroundStyle(.secondary)
            Text(query.isEmpty && filter == "All" ? collection.emptyText : "No matching items").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(maxWidth: .infinity)
    }
    private var calendarSurface: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    HStack {
                        Text(collection.selectedDate?.formatted(.dateTime.month(.wide).year()) ?? collection.title).font(.headline)
                        Spacer()
                        ForEach(collection.actions) { action in actionButton(action, iconOnly: action.symbol != nil) }
                    }
                    let symbols = calendar.veryShortStandaloneWeekdaySymbols
                    let first = calendar.firstWeekday - 1
                    HStack(spacing: 0) { ForEach(0..<7, id: \.self) { offset in Text(symbols[(offset + first) % 7]).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                        ForEach(collection.days ?? []) { day in
                            let selected = collection.selectedDate.map { calendar.isDate($0, inSameDayAs: day.date) } == true
                            let inMonth = collection.selectedDate.map { calendar.isDate($0, equalTo: day.date, toGranularity: .month) } == true
                            Button { perform(day.action) } label: {
                                VStack(spacing: 4) {
                                    Text("\(calendar.component(.day, from: day.date))").font(.callout.weight(selected || calendar.isDateInToday(day.date) ? .bold : .regular))
                                    Circle().fill(calendar.isDateInToday(day.date) ? Color(pluginHex:appearance.palette.accent) : .clear).frame(width: 4, height: 4)
                                }.frame(maxWidth: .infinity).frame(height: max(23, min(46, (geometry.size.height - 90) / 6)))
                                    .foregroundStyle(selected ? Color(pluginHex:appearance.palette.onAccent) : inMonth ? .primary : .secondary)
                                    .background(selected ? Color(pluginHex:appearance.palette.accent) : Color.primary.opacity(inMonth ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 11))
                            }.buttonStyle(.plain).disabled(!day.action.enabled).accessibilityLabel(day.date.formatted(date: .complete, time: .omitted)).accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    Text("Select a day to load its agenda").font(.caption2).foregroundStyle(.secondary)
                }.frame(width: geometry.size.width * 0.49)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(collection.selectedDate?.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) ?? "Agenda").font(.headline)
                    ScrollView {
                        if collection.items.isEmpty { emptyState }
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(collection.items) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.category).font(.caption.weight(.semibold)).foregroundStyle(Color(pluginHex:appearance.palette.accent))
                                    Text(item.title).font(.callout.weight(.medium))
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                    if let action = item.action { actionButton(action) }
                                }.padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color(pluginHex:appearance.palette.accent)).frame(width: 3) }
                            }
                        }
                    }
                    Text(collection.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
    @ViewBuilder private func dateLabel(_ date: Date?) -> some View {
        if let date { Text(calendar.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : (calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(date: .abbreviated, time: .omitted))).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        else { Text("—").font(.caption).foregroundStyle(.tertiary) }
    }
    private func actionButton(_ action: PluginAction, iconOnly: Bool = false) -> some View {
        Button { perform(action) } label: {
            if iconOnly { Image(systemName: action.symbol ?? "arrow.up.right") }
            else { Text(action.label).font(.caption.weight(.medium)) }
        }.disabled(!action.enabled).help(action.label).accessibilityLabel(action.label)
    }
    private func perform(_ action: PluginAction) {
        guard action.enabled else { return }
        if action.confirmation != nil { reviewing = action } else { invoke(action.id) }
    }
}
