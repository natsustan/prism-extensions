import PrismExtensionKit

/// A to-do list kept in Prism's state. The list filters itself
/// (`filtering: .extension`): Prism sends the query with each load, and a
/// query that matches nothing offers to add it.
@main
struct TodoSwift: PrismExtension {
    private struct Todo: Codable {
        var id: String
        var title: String
        var created: Date
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        let todos = await load(context)
        let text = query.trimmingCharacters(in: .whitespaces)
        let shown = todos.filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) }
            .filter { filter != "today" || Calendar.current.isDateInToday($0.created) }
        var items = shown.map { todo in
            ExtensionListItem(
                id: todo.id,
                title: todo.title,
                icon: ExtensionIcon(symbol: "circle", tint: "green"),
                accessories: [ExtensionListAccessory(text: todo.created.formatted(.relative(presentation: .named)))],
                detail: ExtensionDetail(
                    markdown: "## \(todo.title)",
                    metadata: [ExtensionMetadataRow(label: "Added", value: todo.created.formatted(date: .abbreviated, time: .shortened))]
                ),
                actions: [
                    ExtensionAction(
                        id: "done", title: "Mark as Done", symbol: "checkmark.circle", style: .destructive,
                        shortcut: ExtensionShortcut("cmd+d"), confirmationMessage: "“\(todo.title)” will be removed from the list."
                    ),
                    ExtensionAction(
                        id: "copy", title: "Copy Title", kind: .copy(text: todo.title),
                        shortcut: ExtensionShortcut("cmd+shift+c")
                    ),
                ]
            )
        }
        if !text.isEmpty, !todos.contains(where: { $0.title.caseInsensitiveCompare(text) == .orderedSame }) {
            // The item ID carries the text, so the action knows what to add.
            items.append(ExtensionListItem(
                id: "add:\(text)", title: "Add “\(text)”",
                icon: ExtensionIcon(symbol: "plus.circle.fill", tint: "green"), section: "New",
                actions: [ExtensionAction(id: "add", title: "Add To-Do", symbol: "plus")]
            ))
        }
        return ExtensionList(
            items: items,
            filtering: .extension,
            searchPlaceholder: "Search or add a to-do…",
            filters: [ExtensionListFilter(id: "all", title: "All To-Dos"), ExtensionListFilter(id: "today", title: "Added Today")],
            emptyMessage: ExtensionListMessage(title: "Nothing to do", message: "Type a to-do and press Return to add it.", symbol: "checklist")
        )
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        var todos = await load(context)
        switch action {
        case "add":
            let title = String(item.dropFirst("add:".count))
            todos.append(Todo(id: UUID().uuidString, title: title, created: Date()))
            await save(todos, context)
            return .reload(message: "Added “\(title)”.")
        case "done":
            guard let index = todos.firstIndex(where: { $0.id == item }) else {
                throw PrismExtensionError("That to-do is already gone.")
            }
            let done = todos.remove(at: index)
            await save(todos, context)
            return .reload(message: "Done: \(done.title)")
        default:
            throw PrismExtensionError("Unknown action “\(action)”.")
        }
    }

    // Prism keeps state as simple values; the list is stored as JSON text.
    private func load(_ context: PrismContext) async -> [Todo] {
        guard let text = await context.state("todos")?.stringValue else { return [] }
        return (try? JSONDecoder().decode([Todo].self, from: Data(text.utf8))) ?? []
    }

    private func save(_ todos: [Todo], _ context: PrismContext) async {
        let data = (try? JSONEncoder().encode(todos)) ?? Data("[]".utf8)
        await context.setState(.string(String(decoding: data, as: UTF8.self)), for: "todos")
    }
}
