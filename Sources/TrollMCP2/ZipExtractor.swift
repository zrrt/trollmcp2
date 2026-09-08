import Foundation
import Compression

/// 轻量 ZIP 解压器（v2.9.9）
/// 支持 STORE(0) 与 DEFLATE(8) 两种压缩方式，解析 ZIP 中央目录。
/// 用于 GitHub Actions artifact 下载后的解压，避免依赖系统 unzip 或第三方库。
enum ZipExtractor {
    /// v2.9.112：ZIP 条目元数据（fs.zip 浏览用）
    struct ZipEntry {
        let name: String
        let method: Int
        let compSize: Int
        let uncompSize: Int
        let localOffset: Int
        var isDir: Bool { name.hasSuffix("/") }
    }

    enum ZipError: Error, CustomStringConvertible {
        case notZip, corrupt(String)
        var description: String {
            switch self {
            case .notZip: return "不是有效的 ZIP 文件"
            case .corrupt(let m): return "ZIP 解析失败: \(m)"
            }
        }
    }

    /// 把 zip 解压到目标目录。若目录已存在会先清空重建。
    static func unzip(_ zipURL: URL, to destURL: URL) throws {
        let data = try Data(contentsOf: zipURL)
        try unzip(data, to: destURL)
    }

    /// v2.9.112：列出 ZIP 内全部条目（只读中央目录，不写盘）
    static func entries(_ data: Data) throws -> [ZipEntry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.notZip }
        var eocdIdx: Int? = nil
        let minSearch = max(0, bytes.count - 65557)
        var i = bytes.count - 22
        while i >= minSearch {
            if bytes[i] == 0x50, bytes[i+1] == 0x4b, bytes[i+2] == 0x05, bytes[i+3] == 0x06 {
                eocdIdx = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdIdx else { throw ZipError.notZip }
        let cdCount = u16(bytes, eocd + 10)
        let cdOffset = u32(bytes, eocd + 16)
        var result: [ZipEntry] = []
        var offset = Int(cdOffset)
        for _ in 0..<cdCount {
            guard offset + 46 <= bytes.count,
                  bytes[offset] == 0x50, bytes[offset+1] == 0x4b,
                  bytes[offset+2] == 0x01, bytes[offset+3] == 0x02 else {
                throw ZipError.corrupt("中央目录条目签名错误 @\(offset)")
            }
            let method = u16(bytes, offset + 10)
            let compSize = u32(bytes, offset + 20)
            let uncompSize = u32(bytes, offset + 24)
            let nameLen = u16(bytes, offset + 28)
            let extraLen = u16(bytes, offset + 30)
            let commentLen = u16(bytes, offset + 32)
            let localOffset = u32(bytes, offset + 42)
            let nameStart = offset + 46
            let nameData = Array(bytes[nameStart..<(nameStart + Int(nameLen))])
            let name = String(bytes: nameData, encoding: .utf8) ?? String(bytes: nameData, encoding: .isoLatin1) ?? ""
            result.append(ZipEntry(name: name, method: method, compSize: compSize, uncompSize: uncompSize, localOffset: localOffset))
            offset = nameStart + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }
        return result
    }

    /// v2.9.112：读取 ZIP 内单个条目内容（解压到内存，不写盘）
    static func entryData(_ data: Data, name: String) throws -> Data {
        let bytes = [UInt8](data)
        guard let e = try entries(data).first(where: { $0.name == name }) else {
            throw ZipError.corrupt("条目不存在: \(name)")
        }
        guard !e.isDir else { return Data() }
        let dataStart = try localDataOffset(bytes: bytes, localOffset: e.localOffset)
        let compEnd = dataStart + e.compSize
        guard compEnd <= bytes.count else { throw ZipError.corrupt("压缩数据越界 @\(name)") }
        let comp = Array(bytes[dataStart..<compEnd])
        let out: [UInt8]
        if e.method == 0 {
            out = comp
        } else if e.method == 8 {
            out = try inflate(comp, expectedSize: e.uncompSize)
        } else {
            out = comp
        }
        return Data(out)
    }

    static func unzip(_ data: Data, to destURL: URL) throws {
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        let bytes = [UInt8](data)

        // 1. 定位 EOCD（End of Central Directory）签名 0x06054b50，从尾部找
        guard bytes.count >= 22 else { throw ZipError.notZip }
        var eocdIdx: Int? = nil
        let minSearch = max(0, bytes.count - 65557) // EOCD 最大注释 65535 + 22
        var i = bytes.count - 22
        while i >= minSearch {
            if bytes[i] == 0x50, bytes[i+1] == 0x4b, bytes[i+2] == 0x05, bytes[i+3] == 0x06 {
                eocdIdx = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdIdx else { throw ZipError.notZip }

        let cdCount = u16(bytes, eocd + 10)
        let cdOffset = u32(bytes, eocd + 16)

        // 2. 遍历中央目录条目（签名 0x02014b50）
        var offset = Int(cdOffset)
        for _ in 0..<cdCount {
            guard offset + 46 <= bytes.count,
                  bytes[offset] == 0x50, bytes[offset+1] == 0x4b,
                  bytes[offset+2] == 0x01, bytes[offset+3] == 0x02 else {
                throw ZipError.corrupt("中央目录条目签名错误 @\(offset)")
            }
            let method = u16(bytes, offset + 10)
            let compSize = u32(bytes, offset + 20)
            let uncompSize = u32(bytes, offset + 24)
            let nameLen = u16(bytes, offset + 28)
            let extraLen = u16(bytes, offset + 30)
            let commentLen = u16(bytes, offset + 32)
            let localOffset = u32(bytes, offset + 42)

            let nameStart = offset + 46
            let nameData = Array(bytes[nameStart..<(nameStart + Int(nameLen))])
            let name = String(bytes: nameData, encoding: .utf8) ?? String(bytes: nameData, encoding: .isoLatin1) ?? ""

            // 跳过目录项
            if !name.isEmpty && !name.hasSuffix("/") {
                // 读本地文件头，找到实际数据起点
                let dataStart = try localDataOffset(bytes: bytes, localOffset: Int(localOffset))
                let compEnd = dataStart + Int(compSize)
                guard compEnd <= bytes.count else {
                    throw ZipError.corrupt("压缩数据越界 @\(name)")
                }
                let comp = Array(bytes[dataStart..<compEnd])
                let out: [UInt8]
                if method == 0 {
                    out = comp
                } else if method == 8 {
                    out = try inflate(comp, expectedSize: Int(uncompSize))
                } else {
                    out = comp // 未知方法按原样
                }
                try write(Array(out), name: name, destURL: destURL)
            }

            offset = nameStart + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }
    }

    /// 解析本地文件头（签名 0x04034b50），返回压缩数据起始偏移
    private static func localDataOffset(bytes: [UInt8], localOffset: Int) throws -> Int {
        guard localOffset + 30 <= bytes.count,
              bytes[localOffset] == 0x50, bytes[localOffset+1] == 0x4b,
              bytes[localOffset+2] == 0x03, bytes[localOffset+3] == 0x04 else {
            throw ZipError.corrupt("本地文件头签名错误 @\(localOffset)")
        }
        let nameLen = u16(bytes, localOffset + 26)
        let extraLen = u16(bytes, localOffset + 28)
        return localOffset + 30 + Int(nameLen) + Int(extraLen)
    }

    private static func write(_ data: [UInt8], name: String, destURL: URL) throws {
        let target = destURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 防目录穿越
        let standardized = target.standardizedFileURL.path
        guard standardized.hasPrefix(destURL.standardizedFileURL.path) else { return }
        try Data(data).write(to: target)
    }

    /// DEFLATE 解压（raw deflate），用 compression 框架。
    /// ZIP 存储的是 raw deflate（无 zlib 头）。compression 的 COMPRESSION_ZLIB
    /// 通常能容忍无头数据；若失败，则前置 zlib 头(0x78 0x9C)后重试。
    private static func inflate(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        let cap = expectedSize > 0 ? expectedSize : max(input.count * 4, 1024)
        var output = [UInt8](repeating: 0, count: cap)

        func decode(_ data: [UInt8]) -> Int {
            data.withUnsafeBufferPointer { inBuf -> Int in
                output.withUnsafeMutableBufferPointer { outBuf -> Int in
                    compression_decode_buffer(outBuf.baseAddress!, outBuf.count,
                                              inBuf.baseAddress!, inBuf.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
        }

        var written = decode(input)
        if written == 0 {
            // 无头 raw deflate → 前置 zlib 头重试
            var withHeader = [UInt8](repeating: 0, count: input.count + 2)
            withHeader[0] = 0x78
            withHeader[1] = 0x9C
            for (idx, b) in input.enumerated() { withHeader[idx + 2] = b }
            written = decode(withHeader)
        }
        guard written > 0 else { throw ZipError.corrupt("DEFLATE 解压失败") }
        return Array(output[0..<written])
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i+1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i+1]) << 8) | (Int(b[i+2]) << 16) | (Int(b[i+3]) << 24)
    }
}
