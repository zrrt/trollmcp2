import Foundation

// MARK: - Assistant 记忆工具（对齐原版 assistant.memory_*）

final class AssistantMemoryStore: ObservableObject {
    static let shared = AssistantMemoryStore()
    private let key = "trollmcp2.assistant_memory"

    @Published var entries: [String: String] = [:]

    init() { load() }

    func load() {
        entries = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func save() {
        UserDefaults.standard.set(entries, forKey: key)
    }

    func set(_ key: String, value: String) {
        entries[key] = value
        save()
    }

    func delete(_ key: String) {
        entries.removeValue(forKey: key)
        save()
    }
}

final class AssistantMemorySetTool: MCPTool {
    let definition = ToolDefinition(
        name: "assistant.memory_set",
        summary: "Save an assistant memory entry (key-value pair)",
        parameters: ["key": "Memory key", "value": "Memory value"],
    verified: true, category: "knowledge")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let key = params["key"] as? String,
              let value = params["value"] as? String else {
            throw MCPError.invalidParams("key and value required")
        }
        AssistantMemoryStore.shared.set(key, value: value)
        AuditLog.shared.log("assistant.memory_set", detail: key)
        return ["key": key, "value": value, "saved": true]
    }
}

final class AssistantMemoryListTool: MCPTool {
    let definition = ToolDefinition(
        name: "assistant.memory_list",
        summary: "List all assistant memory entries",
        parameters: ["query": "Optional: keyword filter"],
        verified: true, category: "knowledge")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let query = params["query"] as? String ?? ""
        let store = AssistantMemoryStore.shared
        let filtered = query.isEmpty ? store.entries : store.entries.filter {
            $0.key.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query)
        }
        return [
            "count": filtered.count,
            "entries": filtered.map { ["key": $0.key, "value": $0.value] }
        ]
    }
}

final class AssistantMemoryDeleteTool: MCPTool {
    let definition = ToolDefinition(
        name: "assistant.memory_delete",
        summary: "Delete a specific assistant memory entry",
        parameters: ["key": "Memory key to delete"],
    verified: true, category: "knowledge")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let key = params["key"] as? String else {
            throw MCPError.invalidParams("key required")
        }
        AssistantMemoryStore.shared.delete(key)
        AuditLog.shared.log("assistant.memory_delete", detail: key)
        return ["deleted": true, "key": key]
    }
}
