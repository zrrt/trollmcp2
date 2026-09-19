# Apple Security Bounty Report: In-the-Wild Safari Full Exploit Chain on arm64e

**Date:** March 2026
**Severity:** Critical
**Components:** JavaScriptCore (JIT compiler, NaN-boxing, WebAssembly), ARM64e PAC, WebContent Sandbox
**Affected Platforms:** iOS 16.0-17.x, macOS (arm64e devices: A12+ / M1+)
**Category:** Full exploit chain  --  WebKit RCE + Wasm dispatch hijack + PAC bypass + JIT cage escape + sandbox policy bypass

---

## 1. Executive Summary

This report documents a **complete in-the-wild exploit chain** recovered from a Safari watering-hole attack (delivered via `b27.icu`). The chain consists of 28 JavaScript modules and exploits **six independent vulnerabilities** to achieve arbitrary native code execution from JavaScript in Safari's WebContent process on arm64e devices. A comprehensive 6596-line technical analysis accompanies this report.

The chain achieves:

1. **WebKit RCE (2 independent paths)**  --  NaN-boxing type confusion and JIT structure check elimination provide arbitrary read/write from JavaScript
2. **Wasm dispatch hijack**  --  `call_indirect` JIT pointer overwrite converts the Wasm sandbox into an arbitrary native function call primitive
3. **ARM64e PAC bypass**  --  unsigned GOT-swap through Apple framework "confused deputies"
4. **Sandbox bypass**  --  unrestricted `mach_vm_allocate` with `VM_PROT_EXECUTE` from WebContent
5. **JIT Cage escape (`SecureARM64EHashPins`)**  --  PACDB rolling hash forged in JavaScript

Additional finding: **stable unsigned GOT offsets** across 6 Apple private frameworks enable version-portable exploitation without runtime gadget scanning.

**Full exploit source code and detailed technical analysis are attached.** Every technical claim in this report has been verified against the source through static reverse engineering.

### Chain Flow

```
Visitor lands on watering-hole page (b27.icu)
    │
    ▼
VULNERABILITY 1: WebKit RCE (NaN-Boxing or JIT Structure Confusion)
    │  Achieves arbitrary read/write in WebContent process
    ▼
VULNERABILITY 3: Wasm call_indirect Dispatch Hijack
    │  Converts Wasm sandbox into arbitrary native call primitive
    ▼
VULNERABILITY 4: PAC Bypass via Unsigned GOT-Swap
    │  Enables calling any native function with controlled arguments
    ▼
VULNERABILITY 5: mach_vm_allocate RWX from WebContent Sandbox
    │  Allocates executable memory pages outside the JIT cage
    ▼
VULNERABILITY 6: JIT Cage Escape via PACDB Hash Forgery
    │  Signs arbitrary shellcode so it passes kernel JIT verification
    ▼
Arbitrary ARM64 shellcode execution in WebContent process
```

---

## 2. Vulnerability 1: WebKit RCE  --  NaN-Boxing Type Confusion (YGPUu7)

### 2.1 The Security Assumption Being Violated

JavaScriptCore's JIT compiler (DFG/FTL) relies on type speculation to generate optimized machine code. The security model assumes:
- JIT-compiled code correctly validates speculated types at runtime via structure checks
- Array index bounds checks prevent out-of-bounds memory access
- Integer range analysis prevents arithmetic overflow/underflow from producing valid OOB indices

### 2.2 The Flaw

The exploit demonstrates that JSC's JIT compiler can be forced to eliminate a critical integer range check through a carefully constructed warmup sequence:

1. **Fake JSCell construction:** Forge synthetic NaN-boxed values via aliased `Float64Array`/`Uint32Array` views over a shared `ArrayBuffer`. The `isNaN()` guard ensures forged bit patterns avoid the IEEE 754 NaN range.

2. **Structure spray:** 400 identical empty arrays populate JSC's structure table, plus 16 auxiliary object arrays with indexed properties to create predictable StructureIDs.

3. **Base64 trigger function:** A `new Function(atob(...))` constructs the JIT trigger  --  integer arithmetic near `INT32_MAX` (2147483647). After 16M+ warmup iterations with safe parameters, the JIT eliminates the range check. The payload path subtracts `2147483640`, producing a small positive index through a path the JIT speculated was unreachable.

4. **NaN offset recovery:** After OOB access, the exploit reads back the corrupted value and extracts the actual StructureID to compute the NaN-boxing offset correction (`T.Dn.Mn = 65536 * (indexingType - 4)`) used for all subsequent pointer arithmetic.

### 2.3 Dual-Wasm-Instance R/W Engine (Class P)

With the type confusion established, the exploit constructs a **WebAssembly-backed arbitrary read/write**:

1. Build a Wasm module with 4 exports (`a`, `b`, `c`, `d`)  --  simple accessors over 3 mutable globals (2 × i64, 1 × i32)
2. Create two instances from the same module  --  "executor" (`this.Er`) and "navigator" (`this.Nr`) with separate global storage
3. Locate each instance's internal global storage via `addrof(instance) + FSCw9f + VMMcyp` (JSC internal offsets from config module)
4. **Overwrite navigator's global storage pointer** to redirect to executor's storage with computed offset
5. Now: `navigator.set_addr(target)` loads into executor's global; `executor.read32()` returns value at target address

The resulting Class P provides `Zr(addr)` for address targeting and read/write methods at `T.Dn.Pn`.

### 2.4 Source Location

**File:** `YGPUu7_8dbfa3fd.js`  --  function `r.kr` (exploit trigger), Class P (Wasm R/W engine)

### 2.5 Impact

- Arbitrary read/write from JavaScript in the WebContent process
- No user interaction required  --  triggers automatically on page load
- Fully deterministic  --  no race conditions, no heap grooming uncertainty

---

## 3. Vulnerability 2: WebKit RCE  --  JIT Structure Check Elimination (KRfmo6)

### 3.1 The Security Assumption Being Violated

JSC's DFG optimizer uses structure (hidden class) checks to validate that objects have the expected property layout before accessing inline storage. The security model assumes:
- Structure checks are never incorrectly eliminated
- DFG's control flow graph analysis correctly identifies mandatory checks
- `Reflect.construct()` objects are handled with the same rigor as regular objects

### 3.2 The Flaw

The exploit forces the JIT to eliminate a structure check through control flow complexity:

1. **Divergent structures:** Create objects `r` and `i` via `Reflect.construct(Object, [], n)`. Assign `double[]` to `r.p1`/`r.p2` and integers to `i.p1`/`i.p2`, then reshape `i` by deleting and reattaching properties  --  different types, partially similar structure.

2. **CFG flooding:** The JIT trigger function contains **36 redundant** `while(h < 1) { s.guard_p1 = 1; h++ }` loops specifically designed to fill DFG's control flow graph and trigger aggressive speculative optimization.

3. **Structure check elimination:** After millions of warmup iterations always passing `r` (double array at p1), the JIT speculates `o.p1` is always a double array and eliminates the structure check.

4. **Type confusion trigger:** Pass `i` instead of `r`  --  JIT reads integer `i.p1` as a double array, then shifts the butterfly pointer by 16 bytes via `l[0] = l[0] + 16`, giving a **16-byte relative read/write displacement**.

5. **Primitive escalation:** `pm.ws()` builds `addrof` (via `ps()`), absolute read (`ys()`/`rs()`), and absolute write (`bs()`/`As()`) by chaining the displacement. `pm.Us()` upgrades to full arbitrary R/W via Array length field manipulation.

### 3.3 Source Location

**File:** `KRfmo6_166411bd.js`  --  Worker path `ct` (`pm.init()`, `pm.ws()`, `pm.Us()`), Class `ut` (BigInt R/W coordinator)

### 3.4 Impact

- Independent WebKit RCE  --  alternative to YGPUu7, selected per platform/version
- Same end result: arbitrary read/write at `T.Dn.Pn`
- Uses BigInt throughout (Class `ut`) for exact 64-bit arithmetic

---

## 4. Vulnerability 3: Wasm `call_indirect` Dispatch Hijack (class ct)

### 4.1 The Security Assumption Being Violated

WebAssembly's `call_indirect` instruction provides type-safe indirect calls within the Wasm sandbox. The security model assumes:
- `call_indirect` can only dispatch to functions present in the Wasm Table
- The Table's internal JIT code pointer is not accessible from JavaScript
- Wasm's structured control flow prevents arbitrary native jumps

### 4.2 The Flaw

Three design weaknesses:

1. **Stable JIT pointer offset:** The Wasm Table's internal JIT-compiled function code pointer is at a known, stable offset (`bvVGhS`) from the compiled function's address  --  part of the 71-field config table the exploit carries.

2. **Writable pointer:** With arbitrary R/W (from Vulnerability 1 or 2), the pointer can be overwritten directly.

3. **No integrity check:** `call_indirect` reads the pointer and jumps to it without verifying it points to legitimate Wasm code.

### 4.3 The Trampoline

A 306-byte inline Wasm module constructs the universal native call primitive:

| Export | Type | Purpose |
|---|---|---|
| `f` | Function (16 × i32) | Entry point  --  packs args into 8 x-registers, calls through table |
| `o` | Function -> i32 | Accessor for locating the JIT code pointer |
| `m` | Memory (1 page) | Return value storage |
| `t` | Table (1 funcref) | The hijack target  --  its code pointer gets overwritten |

The 16 `i32` parameters are packed into 8 `i64` values inside `$call_inner` via `(p_hi << 32) | p_lo`, mapping directly to ARM64 registers `x0`-`x7`.

### 4.4 Hijack Sequence

```
1. addrof(exports.o) + bvVGhS -> JIT code pointer location
2. Save original pointer
3. Overwrite with target native address
4. Call exports.f(x0_lo, x0_hi, ..., x7_lo, x7_hi)
5. call_indirect -> CPU jumps to target with 8 controlled registers
6. Read 64-bit return value from linear memory
7. Restore original pointer in finally block
```

### 4.5 Source Location

**File:** `macos_stage2_eOWEVG_55afb1a6.js`  --  `class ct`, stored as `T.Dn.Wn`
**Config field:** `bvVGhS` in the 71-field platform configuration table

### 4.6 Impact

- Converts the Wasm sandbox into an arbitrary native function call primitive
- Every subsequent native call in the chain (`dlsym`, `mach_vm_allocate`, `mprotect`, ObjC messages, Mach traps) flows through `ct.call()`
- `finally` block guarantees cleanup  --  forensically clean

---

## 5. Vulnerability 4: PAC Bypass via Unsigned GOT-Swap

### 5.1 The Security Assumption Being Violated

ARM64e PAC is designed to prevent control-flow hijacking by cryptographically signing code pointers. The security model assumes:
- PAC-signed pointers cannot be forged without the secret key
- Indirect calls through PAC-authenticated pointers will fault if tampered
- The `__AUTH_CONST` segment contains PAC-protected GOT entries that are immutable

### 5.2 The Flaw

The exploit demonstrates that **not all GOT entries in Apple framework code paths are PAC-protected**:

1. While `__AUTH_CONST` contains PAC-authenticated GOT entries, frameworks also reference GOT entries in `__DATA` and `__DATA_CONST` that are **not** PAC-signed.
2. These unsigned entries are **writable** from the WebContent process.
3. Legitimate framework code reads these unsigned entries, then passes resolved addresses through PAC-authenticated call sequences using the **framework's own PAC context**.
4. This creates a "confused deputy"  --  Apple's frameworks PAC-authenticate attacker-supplied addresses.

### 5.3 GOT-Swap Mechanism (4 Phases)

**Phase 1  --  Save:** Read and store original GOT values at known framework offsets.

**Phase 2  --  Swap:** Overwrite 6+ unsigned GOT entries with attacker addresses:
- `Zl` -> `_dlfcn_globallookup` (libdyld  --  dynamic symbol resolution)
- `za` -> `_xmlHashScanFull` (libxml2  --  hash table walker)
- `rc` -> `_EdgeInfoCFArrayReleaseCallBack` (CoreGraphics  --  CF callback)
- `Za` -> `objc_msgSend` (libobjc  --  ObjC dispatch)
- `Yl`, `Wl`, `$l`, `Ka`  --  secondary anchors for call chain

**Phase 3  --  Trigger:** Invoke a legitimate API that traverses the tampered GOT:
- **Primary:** `Intl.Segmenter` with `nu:"sentence"`  --  forces ICU library through PAC-auth calls during locale resolution error handling
- **Fallback:** `XSLTProcessor.transformToDocument()`  --  triggers libxml2/libxslt PAC-auth callbacks

**Phase 4  --  Restore:** Write back all originals in a `finally` block. No persistent corruption.

### 5.4 Frameworks Exploited as Confused Deputies

| Framework | GOT Entry Used | Code Path |
|---|---|---|
| `libdyld.dylib` | `_dlfcn_globallookup` | Dynamic symbol resolution |
| `CloudKit.framework` | `cksqlcs_blobBindingValue:destructor:error:` | SQLite blob callback |
| `CoreGraphics.framework` | `_EdgeInfoCFArrayReleaseCallBack` | CF array release callback |
| `libobjc.A.dylib` | `objc_msgSend` (via `Za`) | ObjC message dispatch |
| `libxml2.2.dylib` | `_xmlHashScanFull`, `xmlSAX2GetPublicId` | XML hash table traversal |

### 5.5 Version-Specific Gadget Table

| iOS Version | Primary Gadget | Secondary |
|---|---|---|
| ≥17.1 | HomeSharing (offset 56416) | PassKitCore (offset 25497) |
| ≥17.0 | CoreML (offset 34022) | AppleMediaServices (offset 56883) |
| ≥16.4 | CoreML (offset 62253) | SpringBoard (offset 39351) |
| ≥16.0 | HomeSharing (offset 39661) | CoreML (offset 4123) |
| Fallback | MediaToolbox (offset 61040) | MediaToolbox (offset 61040) |

### 5.6 Class Architecture

| Class | Role |
|---|---|
| `ta` | PAC engine core  --  `Sh(type, addr, pacsig)` splits 64-bit pointers into address + PAC bits |
| `ia` | GOT-swap dispatcher  --  coordinates save/swap/trigger/restore cycle |
| `ca` | `Intl.Segmenter` trigger  --  constructs 300-word body to force ICU traversal |
| `sa` | ObjC PAC signer  --  creates NSUUID, sends ObjC message, captures PAC-signed return |
| `at` | ObjC message sender  --  swaps `Qa` selector (`secondAttribute`), calls through `rc` |
| `it` | Inner GOT-swap  --  nests 7-entry swaps (`Zl`, `ql`, `Yl`, `Wl`, `$l`, `tc`, `Ka`) |

### 5.7 Impact

- Bypasses PAC entirely  --  any native function callable with controlled arguments, authenticated by Apple's own frameworks
- Fully deterministic  --  no races, no brute force
- Forensically clean  --  GOT entries restored after each use
- Version-portable  --  5 tiers covering iOS 16.0-17.x

---

## 6. Vulnerability 6: JIT Cage Escape via SecureARM64EHashPins PACDB Hash Forgery

### 6.1 The Security Assumption Being Violated

Apple's JIT cage restricts WebKit's JIT compiler to writing code only in designated memory regions, with kernel-level verification of code integrity before execution permission is granted. The security model assumes:
- Only the JIT compiler can produce validly-signed code pages
- The rolling PACDB hash chain binds each instruction to its position, preventing code injection
- The `SecureARM64EHashPins` mechanism is an internal implementation detail not accessible to exploit code

### 6.2 The Flaw

The exploit demonstrates three design flaws:

1. **The `SecureARM64EHashPins` symbol is exported**  --  `_ZN3JSC20SecureARM64EHashPins27allocatePinForCurrentThreadEv` is resolvable via `dlsym` or export trie walking from the JavaScriptCore framework.

2. **The PACDB hardware key is process-wide**  --  any code running within the WebContent process can issue PACDB instructions with the same key the kernel uses for JIT code verification.

3. **The rolling hash algorithm is deterministic**  --  given the seed value (derived from page offset), the hash chain can be computed forward for arbitrary instruction sequences.

### 6.3 Rolling Hash Algorithm

The exploit reimplements the kernel's JIT code signing algorithm in JavaScript (method `kg()` in class `hc`):

```javascript
kg() {
    const sign = (code, offset, dest) => {
        let hash = K._(offset);  // Seed from page offset
        for (let i = 0; i < code.length; i++) {
            const val = (code[i] ^ hash) >>> 0;
            const h = lc.cc(sc(val), ctx1).et >>> 7;   // PACDB context 1
            const t = lc.cc(sc(val), ctx2);              // PACDB context 2
            hash = (h ^ (t.it >>> 23 | t.et << 9)) >>> 0;
            ac.sr(dest + 4*i, hash);                     // Write hash chain
        }
        return hash;
    };
}
```

For each 32-bit instruction word:
1. XOR instruction with current hash value
2. Compute two PACDB operations using different contexts (`lc.cc()` with ctx1 and ctx2)
3. Combine results: `hash = (pacdb1.et >>> 7) ^ (pacdb2.it >>> 23 | pacdb2.et << 9)`
4. Store hash chain value adjacent to the instruction

Three algorithm variants exist (functions `c`, `a`, `l` inside `kg()`), selected by runtime flags `CqGuvK` and `iXsBro`, covering different JIT cage implementations across OS versions.

### 6.4 Symbols Resolved at Runtime

| Symbol | Purpose |
|---|---|
| `_ZN3JSC20SecureARM64EHashPins27allocatePinForCurrentThreadEv` | Allocate/access thread-local hash pin |
| `_ZN3JSC16jitOperationListE` | JIT operation validation table |
| `_jitCagePtr` / `jitCagePtr` | JIT cage base pointer (searched with and without underscore) |
| `_ZN3JSC10LinkBuffer8linkCodeERNS_14MacroAssemblerENS_20JITCompilationEffortE` | JIT linking (newer signature) |
| `_ZN3JSC10LinkBuffer8linkCodeERNS_14MacroAssemblerEPvNS_20JITCompilationEffortE` | JIT linking (older signature) |
| `_ZN3JSC22ExecutableMemoryHandle10createImplEm` | JIT memory handle creation |
| `_ZN3WTF13MetaAllocator8allocateEmPv` | JIT allocator (older API) |
| `_ZN3WTF13MetaAllocator8allocateERKNS_6LockerINS_4LockEEEm` | JIT allocator (newer API) |

Both old and new signatures for `LinkBuffer::linkCode` and `MetaAllocator::allocate` ensure compatibility across WebKit versions.

### 6.5 Class Architecture

| Class | Role |
|---|---|
| `oc` | Base class  --  defines abstract interface (empty `Ig()` stub, `gg()` stub, `cg()` JIT detection) and `tg()` template method |
| `hc` (extends `oc`) | Complete JIT cage escape  --  constructor resolves all symbols via `dlsym`/export trie, `kg()` computes rolling hash, `Ig()` override uploads signed pages, `Lg()` navigates fallback path |
| `ni` (in payload A) | Framework resolver  --  locates JavaScriptCore binary path and `jitOperationListE` symbol |

### 6.6 Fallback Path

When the primary `mach_vm_allocate` path is unavailable, method `Lg()` navigates JSC's internal JIT handler table by traversing offset chain `khTYss` -> `ZPvyxD` -> `uxHrSg` -> `hY1Ib7` to find an alternative allocation path. This indicates the exploit authors anticipated potential hardening of the primary path.

### 6.7 Impact

- Arbitrary ARM64 shellcode passes kernel JIT page verification
- Code executes in RWX memory outside the JIT cage
- Three algorithm variants ensure version portability across iOS 16.0-17.x
- Defeats the second major defense-in-depth layer (after PAC)

---

## 7. Vulnerability 5: `mach_vm_allocate` RWX from WebContent Sandbox

### 7.1 The Security Assumption Being Violated

The WebContent process sandbox is designed to restrict the process to only operations needed for web rendering. The security model assumes:
- Only the JIT compiler should be able to create executable memory
- The JIT cage constrains all JIT-compiled code to a designated region
- Arbitrary executable memory allocation from the sandbox should be blocked

### 7.2 The Flaw

The exploit calls `mach_vm_allocate` (resolved from `libdyld.dylib` via `dlsym`) to allocate memory with full RWX permissions:

```
mach_vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE)
mach_vm_protect(mach_task_self(), address, size, FALSE, VM_PROT_ALL)
```

This succeeds from within the WebContent sandbox, indicating:

1. The `mach_vm_allocate` Mach trap is **not filtered** by the sandbox profile
2. `VM_PROT_EXECUTE` permission is **granted** for pages allocated this way
3. The resulting pages are **outside the JIT cage**  --  not subject to JIT code signing verification

### 7.3 Symbol Resolution

| Step | Symbol | Source |
|---|---|---|
| 1 | `dlsym` | Resolved via Wasm R/W primitive from libobjc export trie |
| 2 | `_mach_vm_allocate` | Resolved via `dlsym` from `libdyld.dylib` |
| 3 | `_mach_vm_protect` | Resolved via `dlsym` from `libdyld.dylib` |
| 4 | `mprotect` | Backup for permission changes |

### 7.4 No Legitimate Use Case

The WebContent process has **no legitimate reason** to allocate RWX memory outside the JIT cage. All legitimate JIT compilation goes through JSC's `ExecutableAllocator`, which allocates within the JIT cage region, uses kernel JIT code signing, and is subject to JIT operation list validation. Any `mach_vm_allocate` with `VM_PROT_EXECUTE` from WebContent is anomalous.

### 7.5 Impact

- Arbitrary executable memory allocation outside the JIT cage
- Combined with PACDB hash forgery (Vulnerability B), enables execution of arbitrary ARM64 shellcode
- Fallback path (`Lg()`) indicates inconsistent enforcement across OS versions

---

## 8. Additional Finding: Stable Unsigned GOT Offsets Across iOS Versions

The exploit carries a hardcoded lookup table of (framework, offset) pairs for 6 Apple private frameworks spanning iOS 16.0-17.1+. These offsets point to unauthenticated `BR x16` gadgets that load from unsigned GOT entries.

| iOS Version | Primary Framework | Offset | Secondary Framework | Offset |
|---|---|---|---|---|
| ≥17.1 | HomeSharing | 56416 | PassKitCore | 25497 |
| ≥17.0 | CoreML | 34022 | AppleMediaServices | 56883 |
| ≥16.4 | CoreML | 62253 | SpringBoard | 39351 |
| ≥16.0 | HomeSharing | 39661 | CoreML | 4123 |
| Fallback | MediaToolbox | 61040 | MediaToolbox | 61040 |

The offsets are **pre-computed, not runtime-discovered**, indicating unsigned GOT entry locations are stable across point releases within each iOS version bracket. This stability enables reliable, deterministic exploitation without runtime gadget scanning  --  a significant insecure design weakness.

**Affected frameworks:** HomeSharing, CoreML, PassKitCore, AppleMediaServices, SpringBoard, MediaToolbox

---

## 9. Combined Impact Assessment

**Severity: Critical**

This chain allows an attacker with arbitrary read/write in the WebContent process (achievable via any WebKit memory corruption bug) to:

1. **Achieve WebKit RCE**  --  two independent JIT compiler bugs provide arbitrary read/write from JavaScript
2. **Hijack Wasm dispatch**  --  convert the Wasm sandbox into an arbitrary native function call primitive
3. **Bypass PAC entirely**  --  call any native function with attacker-controlled arguments, authenticated by Apple's own frameworks
4. **Escape the JIT cage**  --  forge PACDB hash chains so arbitrary shellcode passes kernel verification
5. **Allocate executable memory outside the JIT cage**  --  sandbox does not restrict `mach_vm_allocate` with `VM_PROT_EXECUTE`
6. **Execute arbitrary ARM64 machine code**  --  full native code execution within the WebContent process

**Zero user interaction**  --  watering-hole delivery, executes automatically on page visit.

**Version portability:** The chain covers iOS 16.0 through 17.x via:
- 2 independent WebKit RCE paths selected per platform/version
- 5 PAC gadget tiers with pre-computed framework offsets
- 3 JIT hash algorithm variants selected by runtime detection
- 2 API signature sets (older/newer) for JIT allocator functions

**Operational characteristics:**
- Fully deterministic  --  no race conditions, no brute force
- Forensically clean  --  GOT entries restored after each use
- Fallback paths for anticipated hardening

---

## 10. Suggested Mitigations

### For WebKit RCE (Vulnerabilities 1 & 2)

1. **Strengthen JIT structure check elimination analysis**  --  ensure DFG never eliminates structure checks when object types have diverged during warmup.
2. **Harden integer range analysis**  --  specifically handle `INT32_MAX` boundary arithmetic that produces speculated-unreachable code paths.
3. **Limit `new Function(atob(...))` code generation**  --  restrict dynamically constructed function sources from triggering JIT optimization, or add additional validation passes.

### For Wasm Dispatch Hijack (Vulnerability 3)

1. **PAC-sign Wasm Table JIT code pointers**  --  authenticate the internal code pointer before `call_indirect` dispatch.
2. **Randomize the JIT pointer offset (`bvVGhS`)**  --  break the stable offset assumption.
3. **Validate `call_indirect` targets**  --  verify target address falls within the Wasm module's own JIT region.
4. **Move Table metadata to read-only pages**  --  only writable by the JIT compiler itself.

### For PAC Bypass (Vulnerability 4)

1. **PAC-authenticate all GOT entries** reachable from PAC-authenticated call chains  --  the gap between `__AUTH_CONST` (protected) and `__DATA`/`__DATA_CONST` (unprotected) GOT entries is the root cause.
2. **Enforce W^X on GOT pages** after dynamic linking completes  --  prevent the write phase.
3. **Harden `Intl.Segmenter` and `XSLTProcessor` code paths**  --  reduce depth of PAC-auth call chains or add canary checks.

### For JIT Cage Escape (Vulnerability 6)

1. **Remove or restrict the `SecureARM64EHashPins` symbol**  --  should not be resolvable via `dlsym` from WebContent.
2. **Separate the PACDB signing context**  --  use a different key/context for JIT code signing not accessible to WebContent.
3. **Add kernel-side code origin verification**  --  verify JIT pages originated from the legitimate compiler codepath.
4. **Strip JIT-internal symbols from release builds**  --  `jitOperationList`, `LinkBuffer::linkCode`, `MetaAllocator::allocate`.

### For Sandbox RWX (Vulnerability 5)

1. **Block `mach_vm_allocate` with `VM_PROT_EXECUTE` from WebContent**  --  add sandbox rule denying execute permission except from the JIT compiler's designated path.
2. **Enforce `MAP_JIT` for all executable allocations**  --  constrain to JIT cage with per-thread W^X via `pthread_jit_write_protect_np`.
3. **Audit sandbox profiles** for consistency across iOS and macOS.

---

### For Stable GOT Offsets (Additional Finding)

1. **Randomize GOT layout per-build**  --  compile private frameworks with randomized GOT entry ordering so offsets change with every release.
2. **Convert identified unsigned GOT entries to `__AUTH_CONST`**  --  any GOT entry used in indirect call chains should be PAC-authenticated.
3. **Audit all `BR x16` gadgets** in the six affected frameworks  --  replace with `BRAA x16, xN` (authenticated branch) where possible.

---

## 11. Evidence Source

Full source code of the exploit chain is attached: 28 JavaScript modules recovered from a watering-hole attack delivered via `b27.icu`. A comprehensive 6596-line technical analysis (`CORUNA_TECHNICAL_ANALYSIS.md`) is included that documents the complete reverse engineering process. Every technical claim in this report has been verified against the source code through static reverse engineering. The exploit was not executed  --  all analysis is based on source-level examination.

The key source files for each vulnerability are:
- **Vulnerability 1 (NaN-boxing RCE):** `YGPUu7_8dbfa3fd.js`  --  function `r.kr`, Class P (Wasm R/W engine)
- **Vulnerability 2 (JIT structure confusion RCE):** `KRfmo6_166411bd.js`  --  Worker path `ct`, Class `ut`; alternate: `yAerzw_d6cb72f5.js`
- **Vulnerability 3 (Wasm dispatch hijack):** `macos_stage2_eOWEVG_55afb1a6.js`  --  `class ct`, `bvVGhS` offset; also in `final_payload_A_16434916_inner.js`
- **Vulnerability 4 (PAC bypass):** `final_payload_A_16434916_inner.js`  --  classes `ta`, `ia`, `ca`, `sa`, `at`, `it`
- **Vulnerability 5 (sandbox RWX):** `final_payload_B_6241388a_inner.js`  --  `mach_vm_allocate` resolution and invocation via class `hc`
- **Vulnerability 6 (JIT cage escape):** `final_payload_B_6241388a_inner.js`  --  classes `oc`, `hc`; `final_payload_A_16434916_inner.js`  --  class `ni`
- **Stable GOT offsets:** Platform config embedded in trigger modules; decoded framework paths in `CORUNA_TECHNICAL_ANALYSIS.md` Section 9.4
- **Shared infrastructure:** `config_81502427.js`, `fallback_2d2c721e.js`, `KRfmo6_166411bd.js`, `ios_uOj89n_bcb56dc5.js`, `d9a260b1c2f63ab5e5aac4261d8a0be5a8b64da0.js.js`

---

*Prepared for Apple Security Bounty Program.*
