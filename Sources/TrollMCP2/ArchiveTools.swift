//
//  ArchiveTools.swift
//  TrollAgent — 对齐 TrollFools preprocessAssets 的 zip/deb 解压能力
//  纯系统库实现：libz（raw deflate / gzip）+ 手写 ZIP/ar/tar 解析
//

import Foundation
import zlib

enum ArchiveError: Error, CustomStringConvertible {
    case format(String)
    var description: String { "ArchiveError: " + format }
}

/// ZIP 读取器（local file header 顺序遍历，支持 store/deflate）
enum ZIPReader {
    static func extractEntries(from data: Data) throws -> [(name: String, data: Data)] {
        var entries: [(String, Data)] = []
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 30 <= bytes.count {
            let sig = UInt32(bytes[offset]) | (UInt32(bytes[offset+1]) << 8) | (UInt32(bytes[offset+2]) << 16) | (UInt32(bytes[offset+3]) << 24)
            if sig == 0x04034b50 { // local file header
                let method = Int(bytes[offset+8]) | (Int(bytes[offset+9]) << 8)
                let compSize = Int(bytes[offset+18]) | (Int(bytes[offset+19]) << 8) | (Int(bytes[offset+20]) << 16) | (Int(bytes[offset+21]) << 24)
                let nameLen = Int(bytes[offset+26]) | (Int(bytes[offset+27]) << 8)
                let extraLen = Int(bytes[offset+28]) | (Int(bytes[offset+29]) << 8)
                let dataStart = offset + 30 + nameLen + extraLen
                guard dataStart + compSize <= bytes.count else { break }
                let name = String(data: Data(bytes[offset+30 ..< offset+30+nameLen]), encoding: .utf8) ?? ""
                let comp = Data(bytes[dataStart ..< dataStart+compSize])
                let out: Data
                switch method {
                case 0: out = comp
                case 8: out = try inflateRaw(comp)
                default: throw ArchiveError.format("zip method \(method) unsupported")
                }
                if !name.hasSuffix("/") { entries.append((name, out)) }
                offset = dataStart + compSize
                continue
            } else if sig == 0x02014b50 || sig == 0x06054b50 { // central dir / EOCD
                break
            } else {
                break
            }
        }
        return entries
    }

    /// raw deflate 解压（zip method 8）
    static func inflateRaw(_ data: Data) throws -> Data {
        var stream = z_stream()
        let src = [UInt8](data)
        let ret = src.withUnsafeBufferPointer { buf -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: buf.baseAddress)
            stream.avail_in = uInt(buf.count)
            var out = Data()
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            let initRet = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initRet == Z_OK else { return initRet }
            defer { inflateEnd(&stream) }
            while stream.avail_in > 0 {
                stream.next_out = UnsafeMutablePointer(&chunk)
                stream.avail_out = uInt(chunk.count)
                let r = inflate(&stream, Z_NO_FLUSH)
                if r != Z_OK && r != Z_STREAM_END { return r }
                out.append(chunk, count: chunk.count - Int(stream.avail_out))
                if r == Z_STREAM_END { break }
            }
            return Z_OK
        }
        guard ret == Z_OK || ret == Z_STREAM_END else { throw ArchiveError.format("deflate error \(ret)") }
        return try inflateRawRest(data) // 重新解压以收集全部输出
    }

    private static func inflateRawRest(_ data: Data) throws -> Data {
        var stream = z_stream()
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let ret = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(data.count)
            let initRet = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initRet == Z_OK else { return initRet }
            defer { inflateEnd(&stream) }
            while stream.avail_in > 0 {
                stream.next_out = UnsafeMutablePointer(&chunk)
                stream.avail_out = uInt(chunk.count)
                let r = inflate(&stream, Z_NO_FLUSH)
                if r != Z_OK && r != Z_STREAM_END { return r }
                out.append(chunk, count: chunk.count - Int(stream.avail_out))
                if r == Z_STREAM_END { break }
            }
            return Z_OK
        }
        guard ret == Z_OK || ret == Z_STREAM_END else { throw ArchiveError.format("deflate error \(ret)") }
        return out
    }
}

/// gzip 解压（deb data.tar.gz）
enum Gzip {
    static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let ret = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(data.count)
            let initRet = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initRet == Z_OK else { return initRet }
            defer { inflateEnd(&stream) }
            while stream.avail_in > 0 {
                stream.next_out = UnsafeMutablePointer(&chunk)
                stream.avail_out = uInt(chunk.count)
                let r = inflate(&stream, Z_NO_FLUSH)
                if r != Z_OK && r != Z_STREAM_END { return r }
                out.append(chunk, count: chunk.count - Int(stream.avail_out))
                if r == Z_STREAM_END { break }
            }
            return Z_OK
        }
        guard ret == Z_OK || ret == Z_STREAM_END else { throw ArchiveError.format("gzip error \(ret)") }
        return out
    }
}

/// ar 归档（deb 外壳）
enum ArReader {
    static func member(_ data: Data, name target: String) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, String(data: Data(bytes[0..<8]), encoding: .ascii) == "!<arch>\n" else { return nil }
        var offset = 8
        while offset + 60 <= bytes.count {
            let name = String(data: Data(bytes[offset..<offset+16]), encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
            let sizeStr = String(data: Data(bytes[offset+48..<offset+58]), encoding: .ascii) ?? "0"
            let size = Int(sizeStr.trimmingCharacters(in: .whitespaces)) ?? 0
            let dataStart = offset + 60
            guard dataStart + size <= bytes.count else { break }
            if name == target {
                return Data(bytes[dataStart..<dataStart+size])
            }
            offset = dataStart + size + (size % 2 == 1 ? 1 : 0)
        }
        return nil
    }
}

/// tar 读取器（USTAR，对齐 TarReader：提取 .dylib 与 .bundle 目录）
enum TarReader {
    struct Entry { let name: String; let isDir: Bool; let data: Data? }

    static func entries(_ data: Data) -> [Entry] {
        let bytes = [UInt8](data)
        var result: [Entry] = []
        var offset = 0
        while offset + 512 <= bytes.count {
            let block = Array(bytes[offset..<offset+512])
            if block.allSatisfy({ $0 == 0 }) { break }
            let name = String(data: Data(block[0..<100]), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            let sizeStr = String(data: Data(block[124..<136]), encoding: .ascii)?.trimmingCharacters(in: CharacterSet(charactersIn: " \0")) ?? "0"
            let size = Int(sizeStr, radix: 8) ?? 0
            let typeflag = block[156]
            let isDir = typeflag == 53 || name.hasSuffix("/") // '5'
            let dataStart = offset + 512
            let entryData: Data? = (!isDir && dataStart + size <= bytes.count) ? Data(bytes[dataStart..<dataStart+size]) : nil
            if !name.isEmpty {
                result.append(Entry(name: name, isDir: isDir, data: entryData))
            }
            offset = dataStart + size + (size % 512 == 0 ? 0 : 512 - (size % 512))
        }
        return result
    }
}

/// deb 解包（对齐 extractDebianPackage：data.tar.gz/bz2/xz/lzma/zst/lz4；本实现支持 gz，其余明确报错）
enum DebReader {
    static func extractDylibAndBundles(at url: URL, to targetDir: URL) throws {
        let data = try Data(contentsOf: url)
        guard let ar = ArReader.member(data, name: "data.tar.gz") else {
            let supported = ["data.tar.gz"]
            for alt in ["data.tar.bz2", "data.tar.xz", "data.tar.lzma", "data.tar.zst", "data.tar.lz4"] {
                if ArReader.member(data, name: alt) != nil {
                    throw ArchiveError.format("deb 含 \(alt)，当前仅支持 gzip 压缩（data.tar.gz）。请用 gzip 重新打包 deb。")
                }
            }
            throw ArchiveError.format("deb 中找不到 data.tar.gz")
        }
        _ = supported
        let tarData = try Gzip.decompress(ar)
        let entries = TarReader.entries(tarData)
        var processedBundles = Set<String>()
        for entry in entries {
            let lower = entry.name.lowercased()
            if !entry.isDir, lower.hasSuffix(".dylib"), let d = entry.data {
                let name = URL(fileURLWithPath: entry.name).lastPathComponent
                if name.hasPrefix(".") { continue }
                try d.write(to: targetDir.appendingPathComponent(name))
            } else if entry.isDir, lower.hasSuffix(".bundle") {
                let bundleName = URL(fileURLWithPath: entry.name).lastPathComponent
                guard !processedBundles.contains(bundleName) else { continue }
                processedBundles.insert(bundleName)
                let bDir = targetDir.appendingPathComponent(bundleName)
                try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)
                for e in entries where e.name.hasPrefix(entry.name) && !e.name.hasSuffix("/") {
                    if let d = e.data {
                        let rel = String(e.name.dropFirst(entry.name.count))
                        let dest = bDir.appendingPathComponent(rel)
                        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try d.write(to: dest)
                    }
                }
            }
        }
    }
}
