// CaptureDB：结构化抓包存储层（对齐 PacketHound 参考架构的"存储层"）
//   链路：Socks5Server 每条 TCP/UDP 流在会话结束时写一行 → SQLite 共享 DB(AppGroup) → 主 App 可查询。
//   表：
//     capture_task    —— 抓包任务(每次 VPN 启动一条)：start_time / rule_name / status
//     capture_session —— 每条流量：task_id / proto / host / port / upload_bytes / download_bytes / start_time / end_time
//   变更通知：CFNotificationCenter(Darwin) 广播 com.trollagent.app.db.changed，主 App 可监听刷新 UI。
//
//   【安全设计】绝不影响转发：
//     1. 所有 DB 操作走独立后台串行队列(dbQueue)，不在转发热路径上；
//     2. 全部 sqlite 调用 try?/错误忽略——最坏是存失败，转发照常；
//     3. 只在会话结束时写一行（不在 pump 每块循环里写），数据量比 hexlog 小几个数量级。
//     4. libsqlite3 是 iOS 系统稳定 dylib，链接无拉起风险。
import Foundation
import SQLite3

final class CaptureDB {
    static let shared = CaptureDB()

    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "capture.db", qos: .utility)
    private var currentTaskId: Int64 = -1
    private let groupId = "group.com.ai.iosxcode"

    private init() {
        guard let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else { return }
        let path = g.path + "/capture.db"
        dbQueue.sync {
            guard sqlite3_open(path, &db) == SQLITE_OK else { db = nil; return }
            let sql = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS capture_task(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              start_time INTEGER, rule_name TEXT, status TEXT);
            CREATE TABLE IF NOT EXISTS capture_session(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id INTEGER, proto TEXT, host TEXT, port INTEGER,
              upload_bytes INTEGER, download_bytes INTEGER,
              start_time INTEGER, end_time INTEGER);
            """
            var err: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, sql, nil, nil, &err)
            if err != nil { sqlite3_free(err) }
        }
    }

    /// VPN 启动时开一条抓包任务
    func beginTask(ruleName: String = "full") {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT INTO capture_task(start_time,rule_name,status) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, now)
                sqlite3_bind_text(stmt, 2, ruleName, -1, nil)
                sqlite3_bind_text(stmt, 3, "running", -1, nil)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    self.currentTaskId = sqlite3_last_insert_rowid(db)
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    /// 会话结束时写一条流量记录（离热路径，一次一行）
    func logSession(proto: String, host: String, port: UInt16,
                    up: Int64, down: Int64, start: Int64, end: Int64) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let task = self.currentTaskId
            var stmt: OpaquePointer?
            let sql = "INSERT INTO capture_session(task_id,proto,host,port,upload_bytes,download_bytes,start_time,end_time) VALUES(?,?,?,?,?,?,?,?)"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, task)
                sqlite3_bind_text(stmt, 2, proto, -1, nil)
                sqlite3_bind_text(stmt, 3, host, -1, nil)
                sqlite3_bind_int(stmt, 4, Int32(port))
                sqlite3_bind_int64(stmt, 5, up)
                sqlite3_bind_int64(stmt, 6, down)
                sqlite3_bind_int64(stmt, 7, start)
                sqlite3_bind_int64(stmt, 8, end)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            // 变更通知：主 App 可 CFNotificationCenterGetDarwinNotifyCenter 监听刷新
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.trollagent.app.db.changed" as CFString), nil, nil, true)
        }
    }
}
