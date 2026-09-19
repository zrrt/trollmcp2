# Apple Security Bounty Report: JIT Cage Escape via `SecureARM64EHashPins` PACDB Hash Forgery

**Date:** March 2026
**Severity:** Critical
**Component:** JavaScriptCore JIT Cage — `SecureARM64EHashPins` code signing verification
**Affected Platforms:** iOS 16.0–17.x, macOS (arm64e devices: A12+ / M1+)
**Category:** Software and Data Integrity Failure — JIT Code Signature Bypass

---

## 1. Executive Summary

A technique observed in an in-the-wild exploit framework escapes JavaScriptCore's JIT cage by **forging the rolling PACDB hash chain** that the kernel uses to verify JIT-compiled code pages. The exploit accesses the `SecureARM64EHashPins` thread-local structure (via the exported symbol `_ZN3JSC20SecureARM64EHashPins27allocatePinForCurrentThreadEv`), computes the correct rolling hash using the same PACDB hardware key available to the process, and writes shellcode pages that pass kernel verification. This allows execution of arbitrary ARM64 machine code outside the JIT cage.

---

## 2. Vulnerability Description

### 2.1 The Security Assumption Being Violated

Apple's JIT cage restricts WebKit's JIT compiler to writing code only in designated memory regions, with kernel-level verification of code integrity before execution permission is granted. The security model assumes:
- Only the JIT compiler can produce validly-signed code pages
- The rolling PACDB hash chain binds each instruction to its position, preventing code injection
- The `SecureARM64EHashPins` mechanism is an internal implementation detail not accessible to exploit code

### 2.2 The Flaw

The observed exploit demonstrates that:

1. **The `SecureARM64EHashPins` symbol is exported** — `_ZN3JSC20SecureARM64EHashPins27allocatePinForCurrentThreadEv` is resolvable via `dlsym` or export trie walking from the JavaScriptCore framework.

2. **The PACDB hardware key is process-wide** — any code running within the WebContent process (including exploit JavaScript via the Wasm trampoline) can issue PACDB instructions with the same key the kernel uses for verification.

3. **The rolling hash algorithm is deterministic** — given the seed value (derived from the page offset), the hash chain can be computed forward for arbitrary instruction sequences. The exploit reimplements this algorithm in JavaScript:

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

4. **Three implementation variants exist** — the exploit carries three versions of the hash computation (`kg()` method variants a, b, c) selected based on runtime flags `CqGuvK` and `iXsBro`, indicating awareness of different JIT cage implementations across OS versions.

### 2.3 Exploitation Flow

```
1. Resolve SecureARM64EHashPins symbol from JavaScriptCore
2. Read the thread-local hash pin structure to obtain signing context
3. Allocate RWX memory page via mach_vm_allocate (see Report D)
4. Write ARM64 shellcode to the allocated page
5. Compute rolling PACDB hash chain for each instruction word
6. Write hash chain alongside shellcode
7. Kernel validates hash chain → grants execute permission
8. Transfer control to shellcode via Wasm call_indirect table hijack (see Report C)
```

---

## 3. Technical Details

### 3.1 Symbol Resolution

The exploit resolves the following JSC-internal symbols at runtime:

| Symbol | Purpose |
|---|---|
| `_ZN3JSC20SecureARM64EHashPins27allocatePinForCurrentThreadEv` | Allocate/access thread-local hash pin |
| `_ZN3JSC16jitOperationListE` | JIT operation validation table |
| `_jitCagePtr` / `jitCagePtr` | JIT cage base pointer (searched with and without underscore prefix) |
| `_ZN3JSC10LinkBuffer8linkCodeERNS_14MacroAssemblerENS_20JITCompilationEffortE` | JIT linking function (newer signature) |
| `_ZN3JSC10LinkBuffer8linkCodeERNS_14MacroAssemblerEPvNS_20JITCompilationEffortE` | JIT linking function (older signature) |
| `_ZN3JSC22ExecutableMemoryHandle10createImplEm` | JIT memory handle creation |
| `_ZN3WTF13MetaAllocator8allocateEmPv` | JIT allocator (older API) |
| `_ZN3WTF13MetaAllocator8allocateERKNS_6LockerINS_4LockEEEm` | JIT allocator (newer API) |

The exploit carries both old and new signatures for `LinkBuffer::linkCode` and `MetaAllocator::allocate` to support multiple WebKit versions.

### 3.2 Rolling Hash Computation

The PACDB rolling hash operates as follows:

1. **Seed** the hash from the page-relative offset of the first instruction
2. **For each 32-bit instruction word**: XOR the instruction with the current hash, then compute two PACDB operations using different contexts
3. **Combine** the PACDB results via bit shifting and XOR to produce the next hash value
4. **Store** the hash chain in memory adjacent to the code

This produces a deterministic signature that the kernel can verify by running the same algorithm forward. Since the PACDB key is process-wide and the algorithm is deterministic, any code within the process can produce valid signatures for arbitrary instruction sequences.

### 3.3 Class Architecture

| Class | Role |
|---|---|
| `oc` | Base class — defines abstract interface (empty `Ig()` stub, `gg()` stub, `cg()` JIT detection) and `tg()` template method |
| `hc` (extends `oc`) | Complete JIT cage escape — constructor resolves all symbols via `dlsym`/export trie, `kg()` computes rolling hash, `Ig()` override uploads signed pages, `Lg()` navigates fallback path |
| `ni` (in payload A) | Framework resolver — locates JavaScriptCore binary path and `jitOperationListE` symbol |

### 3.4 Fallback Path

When the primary `mach_vm_allocate` path is unavailable, the exploit uses method `Lg()` which navigates JSC's internal JIT handler table to find an alternative allocation path. This indicates the exploit authors anticipated potential hardening of the primary path.

---

## 4. Impact Assessment

**Severity: Critical**

This technique allows an attacker who has achieved PAC bypass (Report A) to:

1. **Execute arbitrary ARM64 machine code** — any shellcode the attacker writes will pass kernel verification
2. **Escape the JIT cage entirely** — code executes in RWX memory outside the designated JIT region
3. **Achieve full native code execution** — from this point, the attacker has equivalent privileges to the WebContent process
4. **Remain version-portable** — three hash algorithm variants and multiple allocator API signatures ensure compatibility across iOS 16.0–17.x

This defeats the second major defense-in-depth layer (after PAC) that Apple deployed to prevent browser-based code execution.

---

## 5. Suggested Mitigations

1. **Remove or restrict the `SecureARM64EHashPins` symbol** — this symbol should not be resolvable from within the WebContent sandbox. Mark it as a private symbol or restrict `dlsym` access.

2. **Separate the PACDB signing context** — use a different PACDB context (or a separate PAC key) for JIT code signing that is not accessible to the WebContent process. The current design uses the process-wide PACDB key, which any code in the process can access.

3. **Kernel-side code origin verification** — when validating JIT pages, verify that the code originated from the legitimate JIT compiler codepath (e.g., via a call-stack check or a per-allocation token issued by the JIT compiler).

4. **Rate-limit or audit `mach_vm_allocate` with execute permission** — monitor for RWX allocations from WebContent processes, which have no legitimate use case outside the JIT compiler itself.

5. **Strip JIT-internal symbols from release builds** — symbols like `jitOperationList`, `LinkBuffer::linkCode`, and `MetaAllocator::allocate` provide the exploit with a roadmap to JIT internals. Removing these symbols would force attackers to rely on heuristic discovery.

---

## 6. Evidence Source

Identified through static reverse engineering of an in-the-wild, multi-stage iOS/macOS browser exploit chain. The JIT cage escape is implemented across multiple exploit loader modules. The hash computation algorithm uses a rolling XOR with dual-context PACDB operations, with separate methods for page upload and execution dispatch. Full source artifacts and detailed analysis are available upon request.

---

*Prepared for Apple Security Bounty Program.*
