# Apple Security Bounty Report: PAC Bypass via `__AUTH_CONST` GOT-Swap Technique

**Date:** March 2026
**Severity:** Critical
**Component:** ARM64e Pointer Authentication (PAC) — `__AUTH_CONST` segment protection
**Affected Platforms:** iOS 16.0–17.x, macOS (arm64e devices: A12+ / M1+)
**Category:** Broken Access Control — Pointer Authentication Bypass

---

## 1. Executive Summary

A technique observed in an in-the-wild exploit framework bypasses ARM64e Pointer Authentication Code (PAC) protections **without forging any PAC signatures**. Instead of attacking the PAC cryptographic mechanism directly, the exploit temporarily overwrites unsigned GOT (Global Offset Table) entries in writable memory segments (`__DATA`, `__DATA_CONST`), then triggers legitimate Apple framework code paths that naturally traverse PAC-authenticated indirect calls through the tampered GOT entries. The legitimate frameworks authenticate the attacker's target address using their own PAC context, effectively "laundering" unauthenticated pointers through Apple's own code.

This technique renders PAC protections ineffective against an attacker who has achieved arbitrary read/write within the WebContent process, which is the standard post-exploitation state after any WebKit memory corruption vulnerability.

---

## 2. Vulnerability Description

### 2.1 The Security Assumption Being Violated

ARM64e PAC is designed to prevent control-flow hijacking by cryptographically signing code pointers. The security model assumes that:
- PAC-signed pointers cannot be forged without the secret key
- Indirect calls through PAC-authenticated pointers will fault if the pointer has been tampered with
- The `__AUTH_CONST` segment contains PAC-protected GOT entries that are immutable at runtime

### 2.2 The Flaw

The observed exploit demonstrates that **not all GOT entries in the code path are PAC-protected**. Specifically:

1. While `__AUTH_CONST` contains PAC-authenticated GOT entries, Apple frameworks also reference GOT entries in `__DATA` and `__DATA_CONST` segments that are **not** PAC-signed.
2. These unsigned GOT entries are **writable** from the WebContent process (or can be made writable via `mprotect`).
3. Legitimate framework code paths read these unsigned GOT entries, then pass the resolved addresses through PAC-authenticated call sequences.
4. The PAC authentication step at the end of the chain uses the **framework's own PAC context** — it doesn't verify that the address originated from a trusted source.

This creates a "confused deputy" scenario: Apple's own frameworks become unwitting accomplices that PAC-authenticate attacker-supplied addresses.

### 2.3 Why This Is Not Simply "Arbitrary Write"

This technique is distinct from, and more severe than, simple memory corruption:
- It **defeats PAC** — the primary ARM64e security mechanism — using PAC's own infrastructure
- It is **generic** across iOS versions (the exploit supports 5 version tiers with different framework gadgets)
- It is **reliable** — no race conditions, no timing dependencies, no brute force
- The GOT entries are **restored after use** in a `finally` block, leaving no persistent memory corruption artifacts

---

## 3. Technical Details

### 3.1 GOT-Swap Mechanism

The exploit follows a deterministic four-phase pattern for every PAC-authenticated operation:

**Phase 1 — Save:** Read and store the original values of target GOT entries at known offsets from framework base addresses.

**Phase 2 — Swap:** Overwrite 6+ GOT entries with attacker-controlled addresses. The specific entries targeted are:
- `Yl`, `Wl` — primary GOT pointers (each swapped 6 times during a single PAC operation)
- `$l`, `Ql`, `Ka` — secondary GOT anchors for the call chain
- `Zl` → `_dlfcn_globallookup` — entry point for symbol resolution
- `za` → `_xmlHashScanFull` — libxml2 hash table walker used as indirect call target
- `Xa` → `_autohinter_iterator_begin` — FreeType iterator gadget
- `rc` → `_EdgeInfoCFArrayReleaseCallBack` — CoreGraphics callback pointer

**Phase 3 — Trigger:** Invoke a legitimate API that traverses the tampered GOT:
- **Primary path:** `Intl.Segmenter` with `nu:"sentence"` option (non-standard numbering system value) — forces ICU library code through PAC-authenticated call sequences during locale resolution error handling
- **Fallback path:** `XSLTProcessor.transformToDocument()` with a crafted XML document — triggers libxml2/libxslt code paths through PAC-authenticated callbacks

**Phase 4 — Restore:** In a `finally` block, write back all original GOT values, leaving no trace.

### 3.2 Class Architecture

The exploit implements this through a cooperating class hierarchy:

| Class | Role |
|---|---|
| `ta` | PAC engine core — `Sh(type, addr, pacsig)` splits 64-bit pointers into address + PAC bits |
| `ia` | GOT-swap dispatcher — coordinates the save/swap/trigger/restore cycle |
| `ca` | `Intl.Segmenter` trigger — constructs a 300-word body with specific options to force ICU traversal |
| `sa` | ObjC PAC signer — creates NSUUID instance, sends ObjC message, captures PAC-signed return value |
| `at` | ObjC message sender — swaps `Qa` selector pointer (`secondAttribute`), calls through `rc` (`_EdgeInfoCFArrayReleaseCallBack` entry point) |
| `it` | Inner GOT-swap caller — nests 7-entry GOT swaps (`Zl`, `ql`, `Yl`, `Wl`, `$l`, `tc`, `Ka`) for ObjC dispatch |

### 3.3 Frameworks Exploited as "Confused Deputies"

The following Apple frameworks are used to launder attacker pointers through PAC authentication:

| Framework | GOT Entry Used | Code Path Triggered |
|---|---|---|
| `libdyld.dylib` | `_dlfcn_globallookup` | Dynamic symbol resolution |
| `CloudKit.framework` | `cksqlcs_blobBindingValue:destructor:error:` | SQLite blob callback |
| `CoreGraphics.framework` | `_EdgeInfoCFArrayReleaseCallBack` | CF array release callback |
| `libobjc.A.dylib` | `objc_msgSend` (via `Za` GOT entry) | ObjC message dispatch |
| `libxml2.2.dylib` | `_xmlHashScanFull`, `xmlSAX2GetPublicId` | XML hash table traversal |

### 3.4 Version-Specific Gadget Frameworks

The technique is adaptable across iOS versions because different frameworks provide stable unsigned GOT entries:

| iOS Version | Primary Gadget Framework | Secondary |
|---|---|---|
| ≥17.1 | HomeSharing (offset 56416) | PassKitCore (offset 25497) |
| ≥17.0 | CoreML (offset 34022) | AppleMediaServices (offset 56883) |
| ≥16.4 | CoreML (offset 62253) | SpringBoard (offset 39351) |
| ≥16.0 | HomeSharing (offset 39661) | CoreML (offset 4123) |
| Fallback | MediaToolbox (offset 61040) | MediaToolbox (offset 61040) |

---

## 4. Impact Assessment

**Severity: Critical**

This technique allows an attacker with arbitrary read/write in the WebContent process (achievable via any WebKit memory corruption bug) to:

1. **Bypass PAC entirely** — call any native function with attacker-controlled arguments, authenticated by Apple's own frameworks
2. **Achieve arbitrary code execution** on arm64e devices despite PAC protections
3. **Remain stable across iOS versions** — the version-specific gadget table covers iOS 16.0 through 17.x+
4. **Leave minimal forensic evidence** — GOT entries are restored after each operation

This directly undermines the primary defense-in-depth mechanism Apple deployed on all A12+ and M1+ devices.

---

## 5. Suggested Mitigations

1. **Make all GOT entries PAC-authenticated** — any GOT entry reachable from a code path that performs PAC-authenticated indirect calls should itself be PAC-signed. The current gap between `__AUTH_CONST` (protected) and `__DATA`/`__DATA_CONST` (unprotected) GOT entries is the root cause.

2. **Enforce W^X on GOT pages** — GOT pages containing function pointers used in PAC-authenticated call chains should be mapped read-only after dynamic linking completes. This would prevent the write phase of the GOT-swap.

3. **Add runtime GOT integrity verification** — instrument PAC-authenticated call sites to verify that the resolved GOT address falls within expected bounds (e.g., within the correct framework's `__TEXT` segment).

4. **Harden `Intl.Segmenter` and `XSLTProcessor` code paths** — these APIs serve as reliable trigger mechanisms because they traverse deep call chains through PAC-authenticated indirect calls. Reducing the depth of these call chains or adding canary checks at intermediate points would increase the complexity of exploitation.

---

## 6. Evidence Source

This technique was identified through static reverse engineering of an in-the-wild, multi-stage iOS/macOS browser exploit chain consisting of 28 JavaScript modules (~559 KB total) delivered via a watering-hole attack. The GOT-swap PAC bypass is implemented across multiple exploit stage modules targeting both iOS and macOS. Full source artifacts and detailed analysis are available upon request.

---

*Prepared for Apple Security Bounty Program.*
