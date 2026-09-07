# -*- coding: utf-8 -*-
import io

path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\Models.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

old = """    private let key = "trollmcp2.model_configs"

    init() { load() }"""

new = """    private let key = "trollmcp2.model_configs"
    // v2.9.97：记住最近一次使用的模型，顶栏立即显示用户上次用的配置，不再回退到第一个（旧 gpt4o）
    private let lastUsedKey = "trollmcp2.last_used_config_id"

    init() { load() }

    var lastUsedConfigId: String? {
        get { UserDefaults.standard.string(forKey: lastUsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastUsedKey) }
    }

    func markUsed(_ id: String) {
        lastUsedConfigId = id
    }"""

assert old in c, 'pattern1 not found'
c = c.replace(old, new)

old2 = """    var defaultConfig: ModelConfig? {
        configs.first(where: { $0.isDefault }) ?? configs.first
    }"""

new2 = """    var defaultConfig: ModelConfig? {
        if let d = configs.first(where: { $0.isDefault }) { return d }
        // v2.9.97：其次取最近使用，最后回退第一个
        if let last = lastUsedConfigId, let m = configs.first(where: { $0.id.uuidString == last }) {
            return m
        }
        return configs.first
    }"""

assert old2 in c, 'pattern2 not found'
c = c.replace(old2, new2)

with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('PATCHED Models.swift')
