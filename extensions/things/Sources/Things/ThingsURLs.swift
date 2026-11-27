import Foundation

/// Builds `things:///` URLs for opening items and creating to-dos.
/// `show` and `add` do not require Things' URL authentication token.
enum ThingsURLs {
    static let bundleIdentifier = "com.culturedcode.ThingsMac"
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    static let websiteURL = URL(string: "https://culturedcode.com/things/")!

    static func showURL(id: String) -> URL {
        var components = URLComponents()
        components.scheme = "things"
        components.host = ""
        components.path = "/show"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? URL(string: "things:///show")!
    }

    static func show(id: String) -> String {
        showURL(id: id).absoluteString
    }

    static func add(_ draft: ThingsDraft, reveal: Bool) -> URL? {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "title", value: draft.title),
        ]
        if !draft.notes.isEmpty {
            items.append(URLQueryItem(name: "notes", value: draft.notes))
        }
        if let when = draft.when {
            items.append(URLQueryItem(name: "when", value: when.urlParameterValue))
        }
        if let deadline = draft.deadline {
            items.append(URLQueryItem(name: "deadline", value: deadline.isoString))
        }
        if let listID = draft.listID, !listID.isEmpty {
            items.append(URLQueryItem(name: "list-id", value: listID))
        } else if let listTitle = draft.listTitle, !listTitle.isEmpty {
            items.append(URLQueryItem(name: "list", value: listTitle))
        }
        if !draft.tags.isEmpty {
            items.append(URLQueryItem(name: "tags", value: draft.tags.joined(separator: ",")))
        }
        items.append(URLQueryItem(name: "reveal", value: reveal ? "true" : "false"))

        var components = URLComponents()
        components.scheme = "things"
        components.host = ""
        components.path = "/add"
        components.queryItems = items
        return components.url
    }
}
