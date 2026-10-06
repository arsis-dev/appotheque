import Foundation

public enum ProjectList {
    public static func ordered(_ projects: [Project], favorites: Set<UUID>, order: [UUID]) -> [Project] {
        let uniqueOrder = order.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        let ranks = Dictionary(uniqueKeysWithValues: uniqueOrder.enumerated().map { ($1, $0) })
        let fallback = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($1.id, $0) })
        return projects.sorted {
            let left = favorites.contains($0.id), right = favorites.contains($1.id)
            if left != right { return left }
            return (ranks[$0.id] ?? (order.count + fallback[$0.id, default: 0])) <
                (ranks[$1.id] ?? (order.count + fallback[$1.id, default: 0]))
        }
    }

    public static func moving(_ id: UUID, before target: UUID, in projects: [Project], favorites: Set<UUID>) -> [UUID]? {
        guard id != target, projects.contains(where: { $0.id == id }),
              projects.contains(where: { $0.id == target }), favorites.contains(id) == favorites.contains(target) else { return nil }
        var ids = projects.map(\.id).filter { $0 != id }
        guard let index = ids.firstIndex(of: target) else { return nil }
        ids.insert(id, at: index)
        return ids
    }

    public static func search(_ projects: [Project], query: String) -> [Project] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return projects.filter { project in
            let text = project.name + " " + project.directory
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
