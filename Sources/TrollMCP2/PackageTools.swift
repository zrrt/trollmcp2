// PackageTool：解包查看别人的包（deb / ipa）— v3.3.4
// 子命令：inspect（列结构）/ unpack（解包到工作区）
// deb = ar 归档（control.tar.* + data.tar.*）；ipa = zip。
// 压缩支持：gzip（zlib）、xz/lzma（Compression）；zstd 暂不支持（提示电脑端处理）。

import Foundation
import Compression
import zlib
import ZIPFoundation

final class PackageTool: MCPTool {
    let definition = ToolDefinition(
        name: "package",
        summary: "Inspect & unpack package files (.deb / .ipa). Use for: when user wants to see what's inside someone else's package (deb tweak, ipa app), list its structure, read its control/info, or extract files. Modes: inspect (list members: deb → ar entries + control text + data.tar file list; ipa → zip entry list + main Info.plist path), unpack (extract all to a workspace dir, then read files with fs.read / artifact). Handles: deb=ar+tar (gz/xz/lzma compressed data), ipa=zip (stored/deflate). NOT supported yet: zstd-compressed data.tar (modern deb sometimes) — tell user to unpack on PC with 7-Zip/bsdtar. Example: user says '看看这个 deb 里有什么' → package command:inspect path:/xxx.deb; '解包这个 ipa' → package command:unpack path:/xxx.ipa dest:/var/mobile/Documents/Workspace/extract. REQUIRED PARAMS: command + path.",
        parameters: [
            "command": "inspect / unpack",
            "path": "absolute path to .deb or .ipa",
            "dest": "required for unpack — output directory (will be created)"
        ],
        verified: false, category: "package", prerequisites: [
            "path must be a real file (use fs.find / shell to locate it first)",
            "unpack writes to dest; ensure enough free space for extracted size",
            "after unpack, read inner files with fs.read / artifact read"
        ])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("package: missing command (inspect / unpack)")
        }
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("package: missing path")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.classified("package: file not found: \(path)",
                                      code: "NOT_FOUND", reason: "path",
                                      nextStep: "use fs.find / shell ls to locate the file first")
        }

        switch command {
        case "inspect": return try inspect(path)
        case "unpack":
            guard let dest = params["dest"] as? String, !dest.isEmpty else {
                throw MCPError.invalidParams("package unpack: missing dest (output directory)")
            }
            return try unpack(path, dest: dest)
        default:
            throw MCPError.invalidParams("package: unknown command '\(command)' (inspect / unpack)")
        }
    }

    // MARK: - Inspect

    private func inspect(_ path: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MCPError.failed("package: cannot read file: \(path)")
        }
        if data.prefix(8).elementsEqual(Array("!<arch>\n".utf8)) {
            return try inspectDeb(data, path: path)
        }
        // zip magic: PK\x03\x04 (local) or PK\x05\x06 (empty)
        if data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
            || data.prefix(4).elementsEqual([0x50, 0x4B, 0x05, 0x06]) {
            return try inspectIpa(path)
        }
        throw MCPError.classified("package: unsupported format (not deb/ipa) — magic mismatch",
                                  code: "BAD_FORMAT", reason: "format",
                                  nextStep: "only .deb (ar archive) and .ipa (zip) supported")
    }

    private func inspectDeb(_ data: Data, path: String) throws -> [String: Any] {
        var offset = 8 // skip "!<arch>\n"
        var members: [[String: Any]] = []
        var dataTarName: String?
        var controlText: String?
        var dataFileList: [String] = []

        while offset + 60 <= data.count {
            let hdr = data[offset..<offset + 60]
            let name = String(data: hdr[0..<16], encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sizeStr = String(data: hdr[48..<58], encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            let size = Int(sizeStr) ?? 0
            let contentStart = offset + 60
            guard contentStart + size <= data.count else { break }
            let content = data.subdata(in: contentStart..<contentStart + size)

            // skip symbol table members
            if name != "/" && name != "//" && !name.hasSuffix("/") {
                members.append([
                    "name": name,
                    "size": size,
                    "type": name.hasPrefix("data.tar") ? "data archive" : (name.hasPrefix("control.tar") ? "control archive" : "member")
                ])
                if name.hasPrefix("data.tar") {
                    dataTarName = name
                    dataFileList = tarFileList(content) ?? []
                }
                if name.hasPrefix("control.tar") {
                    controlText = controlFromTar(content)
                }
            }
            offset = contentStart + size + (size % 2) // ar aligns to even
        }

        return [
            "format": "deb (ar archive)",
            "path": path,
            "file_size": data.count,
            "members": members,
            "control": controlText ?? "(no control)",
            "data_archive": dataTarName ?? "(none)",
            "data_file_count": dataFileList.count,
            "data_files_sample": Array(dataFileList.prefix(80)),
            "hint": "use package command:unpack path:<file> dest:<dir> to extract, then fs.read inner files"
        ]
    }

    private func inspectIpa(_ path: String) throws -> [String: Any] {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read) else {
            throw MCPError.failed("package: cannot open ipa as zip: \(path)")
        }
        let names = archive.map { $0.path }
        var payloadInfoPath: String?
        if let p = names.first(where: { $0.hasSuffix("/Info.plist") && $0.hasPrefix("Payload/") }) {
            payloadInfoPath = p
        }
        var appNames = Set<String>()
        for n in names where n.hasPrefix("Payload/") {
            let parts = n.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 { appNames.insert(String(parts[1])) }
        }
        return [
            "format": "ipa (zip)",
            "path": path,
            "file_size": (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0,
            "entry_count": names.count,
            "entries_sample": Array(names.prefix(120)),
            "app_names": Array(appNames),
            "main_info_plist": payloadInfoPath ?? "(none)",
            "hint": "use package command:unpack path:<file> dest:<dir> to extract, then fs.read Payload/<App>.app/Info.plist"
        ]
    }

    // MARK: - Unpack

    private func unpack(_ path: String, dest: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MCPError.failed("package: cannot read file: \(path)")
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let destURL = URL(fileURLWithPath: dest).standardizedFileURL

        var extracted = 0
        var list: [String] = []
        var format = "unknown"

        if data.prefix(8).elementsEqual(Array("!<arch>\n".utf8)) {
            format = "deb"
            // unpack data.tar.* fully; control.tar content too (control file readable)
            var offset = 8
            while offset + 60 <= data.count {
                let hdr = data[offset..<offset + 60]
                let name = String(data: hdr[0..<16], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let sizeStr = String(data: hdr[48..<58], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                let size = Int(sizeStr) ?? 0
                let contentStart = offset + 60
                guard contentStart + size <= data.count else { break }
                let content = data.subdata(in: contentStart..<contentStart + size)
                if name != "/" && name != "//" && !name.hasSuffix("/") {
                    if name.hasPrefix("data.tar") {
                        let n = try extractTar(content, into: destURL)
                        extracted += n
                        list.append(contentsOf: tarFileList(content) ?? [])
                    } else if name.hasPrefix("control.tar") {
                        let n = try extractTar(content, into: destURL.appendingPathComponent("_control"))
                        extracted += n
                    }
                }
                offset = contentStart + size + (size % 2)
            }
        } else if data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
            || data.prefix(4).elementsEqual([0x50, 0x4B, 0x05, 0x06]) {
            format = "ipa"
            guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read) else {
                throw MCPError.failed("package: cannot open ipa as zip: \(path)")
            }
            var count = 0
            for entry in archive {
                do {
                    _ = try archive.extract(entry, to: destURL.appendingPathComponent(entry.path))
                    count += 1
                } catch { /* skip unreadable entry */ }
            }
            extracted = count
            list = archive.map { $0.path }
        } else {
            throw MCPError.classified("package: unsupported format (not deb/ipa)",
                                      code: "BAD_FORMAT", reason: "format",
                                      nextStep: "only .deb (ar) and .ipa (zip) supported")
        }

        return [
            "command": "unpack",
            "format": format,
            "dest": destURL.path,
            "extracted_count": extracted,
            "top_files_sample": Array(list.prefix(100)),
            "next": "read inner files with fs.read / artifact read"
        ]
    }

    // MARK: - tar

    /// List file paths inside a possibly-compressed tar (data.tar.gz/.xz/.lzma/plain).
    private func tarFileList(_ raw: Data) -> [String]? {
        guard let tar = decompressTar(raw) else { return nil }
        return parseTar(tar).map { $0.name }
    }

    private func controlFromTar(_ raw: Data) -> String? {
        guard let tar = decompressTar(raw) else { return nil }
        for (name, data) in parseTar(tar) where name == "./control" || name == "control" {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        }
        return nil
    }

    private func decompressTar(_ raw: Data) -> Data? {
        // detect by magic
        if raw.count >= 2 && raw[0] == 0x1F && raw[1] == 0x8B { return gunzip(raw) }       // gzip
        if raw.count >= 6 && raw[0..<6].elementsEqual([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return xzDecode(raw) } // xz
        if raw.count >= 3 && raw[0] == 0x5D && raw[1] == 0x00 && raw[2] == 0x00 { return lzmaAloneDecode(raw) }   // .lzma
        if raw.count >= 4 && raw[0..<4].elementsEqual(Array("28 BZ".utf8)) { return nil } // bzip2 unsupported
        if raw.count >= 4 && raw[0..<4].elementsEqual(Array("\u{28}\u{B5}\u{2F}\u{FD}".utf8)) { return nil } // zstd
        if raw.count >= 512 { return raw } // plain tar
        return nil
    }

    private func gunzip(_ data: Data) -> Data? {
        // skip 10-byte gzip header (+ optional extra fields)
        var start = 10
        if data.count > start && (data[start] & 0x04) != 0 { // FEXTRA
            let xlen = Int(data[start + 1]) | (Int(data[start + 2]) << 8)
            start += 2 + xlen
        }
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard start < data.count else { return nil }
            let srcPtr = src.baseAddress!.advanced(by: start)
            let srcLen = data.count - start
            var out = Data()
            let chunk = 64 * 1024
            var dst = [UInt8](repeating: 0, count: chunk)
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcPtr.bindMemory(to: UInt8.self, capacity: srcLen))
            stream.avail_in = UInt32(srcLen)
            let ok = inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard ok == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            while stream.avail_in > 0 || stream.avail_out == 0 {
                stream.next_out = dst.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self).baseAddress }
                stream.avail_out = UInt32(chunk)
                let r = inflate(&stream, Z_NO_FLUSH)
                if r == Z_STREAM_END {
                    out.append(dst, count: chunk - Int(stream.avail_out))
                    break
                } else if r == Z_OK {
                    out.append(dst, count: chunk - Int(stream.avail_out))
                } else {
                    return nil
                }
            }
            return out
        }
    }

    /// 用 compression_decode_buffer 单次解压（LZMA/xz），容量不足时倍增重试。
    /// 绕开 compression_stream 结构体构造的 Swift 兼容坑 (CI 实测 2026-09-24）。
    private func decodeLZMA(_ data: Data, skipHeader: Int) -> Data? {
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard skipHeader < data.count else { return nil }
            let srcPtr = src.baseAddress!.advanced(by: skipHeader).bindMemory(to: UInt8.self, capacity: data.count - skipHeader)
            let srcLen = data.count - skipHeader
            let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_LZMA)
            var scratch = [UInt8](repeating: 0, count: scratchSize)
            var capacity = max(64 * 1024, srcLen * 4)
            while capacity < 512 * 1024 * 1024 {
                var dst = [UInt8](repeating: 0, count: capacity)
                let n = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
                    compression_decode_buffer(dstRaw.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              srcPtr, srcLen,
                                              &scratch, COMPRESSION_LZMA)
                }
                if n > 0 {
                    return Data(dst[0..<n])
                }
                // 容量不够时（0 返回且数据非空）翻倍重试
                capacity *= 2
            }
            return nil
        }
    }

    private func xzDecode(_ data: Data) -> Data? {
        return decodeLZMA(data, skipHeader: 0)
    }

    private func lzmaAloneDecode(_ data: Data) -> Data? {
        // .lzma alone: 13-byte header then LZMA stream
        return decodeLZMA(data, skipHeader: 13)
    }

    private func parseTar(_ data: Data) -> [(name: String, data: Data)] {
        var out: [(String, Data)] = []
        var offset = 0
        var longName: String?
        while offset + 512 <= data.count {
            let block = data[offset..<offset + 512]
            if block.allSatisfy({ $0 == 0 }) { break }
            var name = String(data: block[0..<100], encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            if name.isEmpty { offset += 512; continue }
            let sizeStr = String(data: block[124..<136], encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "0"
            let size = Int(sizeStr, radix: 8) ?? 0
            let type = block[156] == 0 ? "0" : String(UnicodeScalar(block[156]))
            let linkName = String(data: block[157..<257], encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            let contentStart = offset + 512
            let contentEnd = min(contentStart + size, data.count)
            let content = data.subdata(in: contentStart..<contentEnd)

            if type == "L" { // GNU longname
                longName = String(data: content, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            } else {
                let finalName = longName ?? name
                longName = nil
                if type == "0" || type == "\u{0}" || type == "" {
                    out.append((finalName, content))
                }
            }
            let aligned = contentStart + size + ((512 - (size % 512)) % 512)
            offset = aligned
        }
        return out
    }

    /// Extract a (possibly compressed) tar into dest, path-traversal safe. Returns file count.
    private func extractTar(_ raw: Data, into destURL: URL) throws -> Int {
        guard let tar = decompressTar(raw) else {
            // detect zstd/bz2 to give a precise message
            if raw.count >= 4 && raw[0..<4].elementsEqual(Array("\u{28}\u{B5}\u{2F}\u{FD}".utf8)) {
                throw MCPError.classified("package: data.tar uses zstd compression — not supported on iOS yet",
                                          code: "UNSUPPORTED_COMPRESSION", reason: "format",
                                          nextStep: "unpack on PC with 7-Zip / bsdtar, or ask to add zstd support")
            }
            if raw.count >= 4 && raw[0..<4].elementsEqual(Array("28 BZ".utf8)) {
                throw MCPError.classified("package: data.tar uses bzip2 — not supported on iOS",
                                          code: "UNSUPPORTED_COMPRESSION", reason: "format",
                                          nextStep: "unpack on PC with 7-Zip")
            }
            throw MCPError.failed("package: cannot decompress data.tar")
        }
        let fm = FileManager.default
        var count = 0
        for (name, content) in parseTar(tar) {
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            guard !clean.isEmpty else { continue }
            let target = destURL.appendingPathComponent(clean).standardizedFileURL
            guard target.path.hasPrefix(destURL.path + "/") else { continue } // zip-slip guard
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target)
            count += 1
        }
        return count
    }
}
