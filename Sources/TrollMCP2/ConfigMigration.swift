//
//  ConfigMigration.swift
//  TrollAgent — v2.9.126：配置 schema 迁移框架（借鉴 cc-switch DatabaseUpgrade）
//
//  问题：模块更新后旧配置结构脱节（key 改名/结构变化/新增必填字段），老用户升级后
//  旧配置失效或行为异常，且无任何提示。
//  方案：启动时读上次 schemaVersion，逐级执行迁移步骤后写入新版本；
//  未来任何配置结构变更都必须在 MIGRATIONS 里加一级，禁止直接改 key 含义。
//

import Foundation

enum ConfigMigration {
    /// 当前配置 schema 版本。每次配置结构变更 +1，并在 MIGRATIONS 里加对应步骤。
    static let currentVersion = 2

    static let versionKey = "trollagent.configSchemaVersion"

    /// 迁移步骤表：版本号 → 迁移闭包（从上一版升级到该版）
    /// 注意：迁移必须是幂等的（重复执行无副作用），因为崩溃可能中断在任意一步。
    private static let migrations: [Int: () -> Void] = [
        2: { migrateToV2() }
    ]

    /// App 启动时调用（AppDelegate.didFinishLaunching 最前面）
    static func migrateIfNeeded() {
        let installed = UserDefaults.standard.integer(forKey: versionKey)
        guard installed < currentVersion else { return }
        var v = installed
        while v < currentVersion {
            let target = v + 1
            if let step = migrations[target] {
                step()
                UserDefaults.standard.set(target, forKey: versionKey)
                NSLog("[ConfigMigration] schema \(v) → \(target) 迁移完成")
            } else {
                NSLog("[ConfigMigration] 无迁移步骤 \(v) → \(target)，直接跳版本")
                UserDefaults.standard.set(target, forKey: versionKey)
            }
            v = target
        }
    }

    // MARK: - 迁移步骤

    /// v2.9.126 → v2（当前）
    /// 模型 API 配置键统一（trollmcp2.* → trollagent.*），旧键自动搬运：
    /// 老版本用 trollmcp2. 前缀散落，未来统一 trollagent. 前缀集中管理。
    private static func migrateToV2() {
        let ud = UserDefaults.standard
        // 旧键 → 新键（只搬运存在的）
        let renames: [String: String] = [
            "trollmcp2.baseURL": "trollagent.baseURL",
            "trollmcp2.apiKey": "trollagent.apiKey",
            "trollmcp2.model": "trollagent.model",
            "trollmcp2.transcript": "trollagent.transcript",
        ]
        for (oldKey, newKey) in renames {
            if ud.object(forKey: newKey) == nil, let val = ud.object(forKey: oldKey) {
                ud.set(val, forKey: newKey)
                ud.removeObject(forKey: oldKey)
            }
        }
        // 会话切换键（旧：lastUsedModelClientID / lastUsedSessionID 等）
        if ud.object(forKey: "trollagent.lastUsedModel") == nil, let v = ud.string(forKey: "lastUsedModelClientID") {
            ud.set(v, forKey: "trollagent.lastUsedModel")
        }
        // 无删除操作——保留旧键兼容（不做破坏性清理，宁可多占几字节）
    }
}
