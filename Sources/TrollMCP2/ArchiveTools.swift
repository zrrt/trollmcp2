//
//  ArchiveTools.swift
//  TrollAgent — 对齐 TrollFools preprocessAssets 的 zip/deb 解压能力
//  纯系统库实现：libz（raw deflate / gzip）+ Compression.framework（bzip2/lzma）+ liblzma dlsym（xz）
//  + 手写 ZIP/ar/tar 解析
//

import Foundation
import zlib
import Compression

enum ArchiveError: Error, CustomStringConvertible {
    case format(String)
    var description: String {
        switch self {
        case .format(let msg): return "ArchiveError: " + msg
        }
    }
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

/// deb 解包（对齐 extractDebianPackage：data.tar.gz/bz2/lzma/xz/zst/lz4；
/// v2.9.126 支持 gzip + bzip2 + raw lzma + xz 容器；zst/lz4 明确报错并给出重打包指引）
enum DebReader {
    /// 用 Compression.framework 解 bzip2 / raw lzma 流（无容器包装，逐块 streaming）
    private static func decompressCompression(_ data: Data, algorithm: compression_algorithm) -> Data? {
        var out = Data()
        let src = (data as NSData).bytes.bindMemory(to: UInt8.self, capacity: data.count)
        var dummyDst: UInt8 = 0
        var stream = compression_stream(dst_ptr: &dummyDst, dst_size: 0, src_ptr: src, src_size: data.count, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_ERROR else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }
        var dst = [UInt8](repeating: 0, count: 65536)
        let dstBuf = dst.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self).baseAddress! }
        var status = COMPRESSION_STATUS_OK
        stream.src_ptr = src
        stream.src_size = data.count
        var guardCount = 0
        while status == COMPRESSION_STATUS_OK {
            stream.dst_ptr = dstBuf
            stream.dst_size = dst.count
            status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = dst.count - stream.dst_size
            if produced > 0 { out.append(dstBuf, count: produced) }
            if status == COMPRESSION_STATUS_END { break }
            if status == COMPRESSION_STATUS_ERROR { return nil }
            // 防死循环：输入耗尽且无进展（异常流）时退出
            guardCount += 1
            if guardCount > 1_000_000 || (stream.src_size == 0 && produced == 0) { break }
        }
        return out
    }

    /// 解 xz 容器：dlsym /usr/lib/liblzma.dylib（iOS 系统自带；Debian deb 默认 data.tar.xz 是 XZ 容器格式，
    /// Compression.framework 的 COMPRESSION_LZMA 只解 raw lzma 流、解不了 xz 帧，必须走 liblzma）。
    /// lzma_stream 是 C ABI 固定布局（xz 5.x 64 位，字段顺序/偏移 liblzma 保证稳定）：
    ///   0:next_in  8:avail_in  16:total_in  24:next_out  32:avail_out  40:total_out  48:allocator  56:internal
    /// 用固定偏移读写（不用 Swift struct——Swift 结构体布局不保证与 C 一致）。
    private static func decompressXZ(_ data: Data) -> Data? {
        typealias LzmaStreamDecoderFn = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32) -> Int32
        typealias LzmaCodeFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
        typealias LzmaEndFn = @convention(c) (UnsafeMutableRawPointer) -> Void

        guard let handle = dlopen("/usr/lib/liblzma.dylib", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symDecoder = dlsym(handle, "lzma_stream_decoder"),
              let symCode = dlsym(handle, "lzma_code"),
              let symEnd = dlsym(handle, "lzma_end") else { return nil }
        let decoderFn = unsafeBitCast(symDecoder, to: LzmaStreamDecoderFn.self)
        let codeFn = unsafeBitCast(symCode, to: LzmaCodeFn.self)
        let endFn = unsafeBitCast(symEnd, to: LzmaEndFn.self)

        // 零初始化一块足够大的 stream buffer（liblzma 只写它认识的字段）
        let stream = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 16)
        memset(stream, 0, 256)
        defer { endFn(stream); stream.deallocate() }

        let ret = decoderFn(stream, UInt64.max, 0x001 /* LZMA_CONCATENATED */)
        guard ret == 0 /* LZMA_OK */ else { return nil }

        var out = Data()
        var dstBuf = [UInt8](repeating: 0, count: 262144)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let bytes = stream.assumingMemoryBound(to: UInt64.self)
            bytes[0] = UInt64(UInt(bitPattern: base))          // next_in
            bytes[1] = UInt64(data.count)                       // avail_in
            while true {
                bytes[3] = UInt64(UInt(bitPattern: dstBuf.withUnsafeMutableBytes { $0.baseAddress! }))  // next_out
                bytes[4] = UInt64(dstBuf.count)                                                          // avail_out
                let r = codeFn(stream, 3 /* LZMA_FINISH */)
                let produced = dstBuf.count - Int(bytes[4])
                if produced > 0 { out.append(dstBuf, count: produced) }
                if r == 1 /* LZMA_STREAM_END */ { return out }
                if r != 0 /* LZMA_OK */ { return nil }
            }
        }
    }

    static func extractDylibAndBundles(at url: URL, to targetDir: URL) throws {
        let data = try Data(contentsOf: url)
        var tarData: Data?
        if let member = ArReader.member(data, name: "data.tar.gz") {
            tarData = try Gzip.decompress(member)
        } else if let member = ArReader.member(data, name: "data.tar.bz2") {
            // 构建环境 Compression SDK 无 COMPRESSION_BZIP2 常量，明确降级（bzip2 deb 极少见）
            _ = member
            throw ArchiveError.format("data.tar.bz2 暂不支持（SDK 缺 COMPRESSION_BZIP2），请用 gzip 打包的 deb")
        } else if let member = ArReader.member(data, name: "data.tar.lzma") {
            guard let d = decompressCompression(member, algorithm: COMPRESSION_LZMA) else {
                throw ArchiveError.format("data.tar.lzma 解压失败（raw lzma）")
            }
            tarData = d
        } else if let member = ArReader.member(data, name: "data.tar.xz") {
            guard let d = decompressXZ(member) else {
                throw ArchiveError.format("data.tar.xz 解压失败（liblzma）")
            }
            tarData = d
        } else {
            for alt in ["data.tar.zst", "data.tar.lz4"] {
                if ArReader.member(data, name: alt) != nil {
                    throw ArchiveError.format("deb 含 \(alt)，iOS 平台无内置解压器。请用 gzip 重新打包 deb（dpkg-deb -Zgzip）后再注入。")
                }
            }
            throw ArchiveError.format("deb 中找不到 data.tar.gz/bz2/lzma/xz")
        }
        guard let tar = tarData else { throw ArchiveError.format("deb 解压后为空") }
        let entries = TarReader.entries(tar)
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
