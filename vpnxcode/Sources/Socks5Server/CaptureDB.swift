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
              start_time INTEGER, end_time INTEGER,
              is_tls INTEGER DEFAULT 0,
              method TEXT, path TEXT, status_code INTEGER,
              content_type TEXT, app_hint TEXT);
            """
            var err: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, sql, nil, nil, &err)
            if err != nil { sqlite3_free(err) }
            // 兼容旧表：补新列（存在则 ALTER 报 duplicate，忽略）
            for col in ["is_tls","method","path","status_code","content_type","app_hint"] {
                var e2: UnsafeMutablePointer<CChar>?
                sqlite3_exec(db, "ALTER TABLE capture_session ADD COLUMN \(col) TEXT", nil, nil, &e2)
                if e2 != nil { sqlite3_free(e2) }
            }
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
    /// - method/path/status：明文 HTTP 或 MITM 后才有；HTTPS 未解密时为 nil
    func logSession(proto: String, host: String, port: UInt16,
                    up: Int64, down: Int64, start: Int64, end: Int64,
                    method: String? = nil, path: String? = nil, status: Int? = nil,
                    isTls: Bool = true, contentType: String? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let task = self.currentTaskId
            var stmt: OpaquePointer?
            let sql = "INSERT INTO capture_session(task_id,proto,host,port,upload_bytes,download_bytes,start_time,end_time,is_tls,method,path,status_code,content_type) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, task)
                sqlite3_bind_text(stmt, 2, proto, -1, nil)
                sqlite3_bind_text(stmt, 3, host, -1, nil)
                sqlite3_bind_int(stmt, 4, Int32(port))
                sqlite3_bind_int64(stmt, 5, up)
                sqlite3_bind_int64(stmt, 6, down)
                sqlite3_bind_int64(stmt, 7, start)
                sqlite3_bind_int64(stmt, 8, end)
                sqlite3_bind_int(stmt, 9, isTls ? 1 : 0)
                if let m = method { sqlite3_bind_text(stmt, 10, m, -1, nil) } else { sqlite3_bind_null(stmt, 10) }
                if let p = path { sqlite3_bind_text(stmt, 11, p, -1, nil) } else { sqlite3_bind_null(stmt, 11) }
                if let s = status { sqlite3_bind_int(stmt, 12, Int32(s)) } else { sqlite3_bind_null(stmt, 12) }
                if let ct = contentType { sqlite3_bind_text(stmt, 13, ct, -1, nil) } else { sqlite3_bind_null(stmt, 13) }
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            // 变更通知：主 App 可 CFNotificationCenterGetDarwinNotifyCenter 监听刷新
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.trollagent.app.db.changed" as CFString), nil, nil, true)
        }
    }

    /// HAR 导出（fix3cy34）：把 capture_session 导出为 HTTP Archive JSON，写到 AppGroup/capture_export.har。
    ///   HTTPS 未解密时 request/response body 标 unavailable，AI 仍能看到请求地图(method/host/大小/耗时)。
    ///   AI 消费路径：shell.exec 把该文件 cp 到 Workspace 后经 /api/file 拉回，或主 App 直接读。
    func exportHAR() -> String {
        var entries: [[String: Any]] = []
        dbQueue.sync {
            guard let db = self.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT host,port,upload_bytes,download_bytes,start_time,end_time,method,path,status_code,is_tls FROM capture_session ORDER BY start_time", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let host = String(cString: sqlite3_column_text(stmt, 0))
                    let port = Int(sqlite3_column_int(stmt, 1))
                    let up = sqlite3_column_int64(stmt, 2)
                    let down = sqlite3_column_int64(stmt, 3)
                    let startMs = sqlite3_column_int64(stmt, 4)
                    let endMs = sqlite3_column_int64(stmt, 5)
                    var method = "UNKNOWN"; if let c = sqlite3_column_text(stmt, 6) { method = String(cString: c) }
                    var path = "/"; if let c = sqlite3_column_text(stmt, 7) { path = String(cString: c) }
                    let status = sqlite3_column_int(stmt, 8)
                    let isTls = sqlite3_column_int(stmt, 9) == 1
                    let scheme = isTls ? "https" : "http"
                    let url = "\(scheme)://\(host):\(port)\(path)"
                    let startDate = Date(timeIntervalSince1970: Double(startMs)/1000.0)
                    let iso = ISO8601DateFormatter().string(from: startDate)
                    let dur = max(0, Int((endMs - startMs)))
                    entries.append([
                        "startedDateTime": iso,
                        "time": dur,
                        "request": [
                            "method": method, "url": url, "httpVersion": "HTTP/1.1",
                            "headers": [], "queryString": [], "cookies": [],
                            "headersSize": -1, "bodySize": Int(up),
                            "postData": ["mimeType": "", "text": isTls ? "(encrypted)" : "(not captured)"]
                        ],
                        "response": [
                            "status": Int(status), "statusText": "", "httpVersion": "HTTP/1.1",
                            "headers": [], "cookies": [], "redirectURL": "",
                            "headersSize": -1, "bodySize": Int(down),
                            "content": ["size": Int(down), "mimeType": "", "text": isTls ? "(encrypted)" : "(not captured)"]
                        ],
                        "cache": [:],
                        "timings": ["send": 0, "wait": dur, "receive": 0],
                        "comment": "is_tls=\(isTls)"
                    ])
                }
            }
            sqlite3_finalize(stmt)
        }
        let har: [String: Any] = [
            "log": [
                "version": "1.2", "creator": ["name": "trollagent-vpn", "version": "0.1"],
                "entries": entries
            ]
        ]
        let jsonData = (try? JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        var outPath = ""
        if let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) {
            outPath = g.path + "/capture_export.har"
            try? FileManager.default.createDirectory(atPath: (outPath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? jsonData.write(to: URL(fileURLWithPath: outPath))
        }
        return outPath
    }
}
