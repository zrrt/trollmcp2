# Coruna Analysis - Errata & Corrections

Corrections to **CORUNA_TECHNICAL_ANALYSIS.md** and **KERNEL_EXPLOIT_ANALYSIS.md**, verified independently against source code artifacts. All corrections have been applied inline to the respective documents.

Full verification details are documented in `reports/ERRORS_FOUND.md`.

---

## Browser Exploit Chain (CORUNA_TECHNICAL_ANALYSIS.md)

| # | Section | Original Claim | Correction | Severity |
|---|---------|----------------|------------|----------|
| 1 | 2.4 | `[7,7,12,29,0,12] ^ 88` = `__DATA` | Decodes to `__TEXT` | Minor |
| 2 | 1.5 | Buffer size 16,842,560 | Correct XOR result: 16,777,216 (2^24) | Minor |
| 3 | Abstract | "500+ strings", "16 recovered modules" | 191 unique strings (1,250 instances); 15 unique modules (28 files, 13 duplicate pairs) | Moderate |
| 4 | 2.8 | ~~"exactly 28 instances" of `throw new Error("")`~~ | ~~434 instances across 28 files~~ - **RETRACTED**: original "28" was correct (1 per file, `grep -rc` confirms 28 total) | ~~Significant~~ |
| 5 | 4.7 | "36 redundant" while loops | 72 total (36 before + 36 after trigger) | Minor |
| 8 | 3.4 | `segment_command_64` field labels (Es=vmsize, Os=filesize, zs=maxprot) | Es=vmaddr (dup), Os=vmsize, zs=filesize (per Apple struct layout) | Minor-Moderate |
| 9 | 3.4 | `section_64` Re=sectname, Vs=segname | Swapped: Re=segname (offset 16), Vs=sectname (offset 0) | Minor |
| 11 | 4.1 | StructureID range 0x000-0xFFF | Actual range 0x111-0x888 (nibbles 1-8 only) | Minor-Moderate |
| 12 | 4.1 | NaN-boxing bit field table (20-bit StructureID, 8-bit Cell type) | Corrected: 12-bit StructureID, 16-bit Cell type, 24-bit Butterfly | Significant |
| 13 | 4.1 | Butterfly mask `0x1FFFFF` (21 bits) | Actual mask `0xFFFFFF` (24 bits) | Moderate |
| 14 | 4.1 | YGPUu7 warmup "16,777,216 iterations (1885621838 ^ 1902399054)" | XOR pair belongs to KRfmo6; YGPUu7 uses 1,000,000 (1749300023 ^ 1749774711) | Significant |
| 15 | 4.1 | YGPUu7 "first 131,072 safe iterations" | Value belongs to KRfmo6; removed from YGPUu7 section | Moderate |
| 16 | 5.4.3, 7.5 | macOS modules use `nu:"currency"`; anti-signature narrative | **All** modules use `nu:"sentence"` - "currency" claim fabricated | **Critical** |
| 17 | 4.6 | Version-adjusted offsets (73064, 61000, 53864, 77200, 69944, 78080) | Correct values: 77464, 77472, 78488, 78496, 78528, 78536 | Significant |
| 18 | 4.6 | tt["02"] swaps from 96 to 88 | Actually increments from 96 to 104 | Minor-Moderate |
| 19 | 4.6 | "41 JSC internal structure offsets" | 42 unique offsets | Minor |
| 20 | 10.2 | KRfmo6 Wasm "~130 bytes vs ~90" | Actual: 165 bytes vs 117 | Minor |
| 21 | 10.2 | KRfmo6 Wasm "3 globals (all mutable i64)" | 8 globals (v128, i64, v128, 5× externref) | Moderate |
| 22 | 10.2 | "4 additional small accessor functions" | Fabricated - only 2 functions exist in Wasm binary | Moderate |
| 23 | 4 | YGPUu7 "~10KB" | 14,668 bytes (14.3 KB) | Minor |
| 24 | 7.4.2 | Sentinel value `0x1BC5A9ABBn` | Actual: `0x1BBBBBBBBn` - `BigInt(7444609979)` = `0x1BBBBBBBB` from source `j(7444609979)` | Significant |
| 25 | 6.3 | "26 named properties" in class er | 28 properties | Minor |
| 26 | 12.2 | Wasm "Found In" table: 117B→Fq2t1Q, 306B→YGPUu7 | 117B→YGPUu7, 306B→eOWEVG (swapped) | Moderate |
| 27 | 7.4.1 | 4/7 inline comments wrong (Zl=dlfcn, ql=autohinter, etc.) | Corrected per Section 6.3 XOR-decoded mappings | Significant |
| 28 | 11.14 | Category subtotals (Framework Paths=28, Exploit Primitives=25) | Framework Paths=27, Exploit Primitives=26 | Minor |
| 29 | 9.2, 12.5-6 | `SharedArrayBuffer` (7 occurrences) | Actual API: `ArrayBuffer` - different security properties | Moderate |
| 30 | 9.1.1 | Binary blob b64 chars: 41,746 / 39,882 | Actual: 41,744 / 39,880 (systematic +2) | Minor |
| 31 | 2.4 | XOR decode example: wrong decoded framework path | Corrected to CoreGraphics framework path | Minor |
| 32 | 2.4 | XOR decode example: `__auth_stubs` | Corrected to `__ZN3JSC16jitOperationListE` | Minor |
| 33 | 2.5 | Key distribution subtotal: range 45-57 = 13 | Actual: 11 keys in range 45-57 | Minor |
| 34 | 2.5 | Key distribution subtotal: range 97-122 = 24 | Actual: 26 keys in range 97-122 | Minor |
| 35 | 2.6 | "3 indirect access pairs" listed | Actually 4 pairs: (107,117), (116,53), (88,78), (108,69) | Minor |
| 36 | 2.9 | "zero non-empty error messages" | 3 unique non-empty error messages across 6 instances | Minor |
| 37 | 6.3 | Bl() library shift: ql=CloudKit, $l=RESync, Ql=CoreUtils | ql=RESync, $l=CoreUtils, Ql=CoreGraphics | Moderate |
| 38 | 6.3 | xc decoded from libsystem_c | xc decoded from JavaScriptCore.framework | Moderate |
| 39 | 7.1 | eOWEVG "33 En references / 21 symbols" | ~28 refs / 23 symbols; removed phantom `dc` | Minor-Moderate |
| 40 | 7.1 | agTkHY "20 references" | ~10 refs / 9 symbols | Minor-Moderate |
| 41 | 11.3 | Heading "28 strings" vs table 27 rows | Heading corrected to 27 | Minor |
| 43 | 7.4.2 | Dispatch constant `0x3B53DB3Fn` | Actual: `0x1CCCCCCCn` (927943795 ^ 730038463) | Significant |
| 44 | 7.6.3 | tc comment: `_xmlMalloc` | Actual: `_EdgeInfoCFArrayReleaseCallBack` (CoreMedia) | Minor-Moderate |
| 45 | 10.4 | Wasm 306-byte module: 3 type signatures swapped | Export "o" takes 8×i64 params; "f" returns void; $call_passthrough returns i64 | Moderate |
| 46 | 7.9.4 | bh/\$c XSLT assignments swapped | bh = xsltFreeTransformContext, \$c = xsltTransformError | Moderate |
| 47 | 7.9.5-6 | `ArrayBuffer(224)` in classes li/si | Actual: `ArrayBuffer(288)` (0x120 = 288) | Minor |
| 48 | 7.10 | `r.Kc = ii` embedded in return statement | Standalone assignment at offset 13367 | Minor |
| 49 | 7.9.4 | Class hi: 3 methods listed | 4 methods - added missing `Th()` | Minor |
| 50 | 7.4.1 | `Jc()` comment: `i[4] = 3 // CPU type: ARM64` | `i[4] = 3 // ncmds: 3 load commands` | Minor |
| 51 | 7.9.4 | Class hi offset range `34157-36093` | Corrected to `34157-36092` | Minor |
| 54 | 8.1 | Base64 sizes: A=37,838 / B=62,770 | A=37,836 / B=62,768 (off-by-2 from counting quotes) | Minor |
| 55 | 8.3 | PAC context `0x3D96` | Actual: `0x47EA` (1194742374 ^ 1194726796) | Moderate |
| 56 | 8.4 | Fill byte `0x3C` (BRK #0 - ARM64 breakpoint) | `0xCC` (INT 3 - x86 software breakpoint) | Moderate |
| 57 | 8.6.1 | r.Sg() "copies platform flags T.Dn.Fn" | Payload B: M.Fn = oc.ag() (hc instance); Payload A: full page alloc + shellcode upload | Significant |
| 58 | 5.3.6 | LC_SYMTAB / LC_DYSYMTAB labels | LC_DYLD_INFO_ONLY (0x80000022) / LC_DYLD_EXPORTS_TRIE (0x80000033) | Moderate |
| 59 | 1.2 | "14 payload URLs" | 13 payload URLs (2 base64-inline entries are not URLs) | Minor |
| 60 | 3.6 | Class et "26 methods" | 25 methods - added missing po()/vo() | Minor |

---

## Kernel Exploit (KERNEL_EXPLOIT_ANALYSIS.md)

| # | Section | Original Claim | Correction | Severity |
|---|---------|----------------|------------|----------|
| K2 | 2.1 | Flags: MH_NOUNDEFS \| MH_DYLDLINK \| MH_TWOLEVEL | Missing MH_NO_REEXPORTED_DYLIBS (0x100000) - binary flags are 0x100085 | Minor |
| K4 | 4.8, 7.2, 7.3 | "33 fixed-byte patterns and 6 wildcard patterns" | 20 fixed + 20 wildcard (total 40; index 58 `..` was previously missed) | Moderate |
| K8 | 6.2 | End addresses dump[0x5C9B] and dump[0x5C79] | Corrected to dump[0x5A22] and dump[0x5A0A] (match lengths unchanged) | Minor |
| K9 | 6.2 | "29,990 bytes before _driver starts" | 28,006 bytes (0x7514 − 0x7AE) | Minor |

---

*Errata compiled by @Nadsec*
*All corrections verified against original source artifacts*
