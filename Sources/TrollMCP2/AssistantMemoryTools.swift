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
        summary: "Save a memory note (key-value pair). Use for: remember facts across sessions, store user preferences. Don't use for: save file (use artifact.write_text), search memory (use assistant.memory_get). Example: user says '记住我叫张三' → save memory.",
        parameters: ["key": "Memory key name", "value": "Memory value to save"],
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
        summary: "List all saved memory notes. Use for: see what you've remembered, search memory by keyword. Don't use for: save new memory (use assistant.memory_set), delete memory (use assistant.memory_delete). Example: user says '你都记住了什么' → list all memories.",
        parameters: ["query": "Search keyword (optional, filter by)"],
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
        summary: "Delete a saved memory note. Use for: forget a fact you remembered, remove outdated info. Don't use for: save new memory (use assistant.memory_set), list all memories (use assistant.memory_list). Example: user says '忘了我刚才说的名字' → delete memory.",
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
