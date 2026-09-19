# Apple Security Bounty Report: `mach_vm_allocate` RWX Memory from WebContent Sandbox

**Date:** March 2026
**Severity:** High
**Component:** WebContent process sandbox policy — `mach_vm_allocate` with RWX permissions
**Affected Platforms:** iOS 16.0–17.x, macOS (arm64e devices)
**Category:** Security Misconfiguration — Excessive Sandbox Permissions

---

## 1. Executive Summary

An in-the-wild exploit framework allocates **read-write-execute (RWX) memory pages** from within Safari's WebContent sandbox process by directly invoking the `mach_vm_allocate` kernel trap with `VM_PROT_ALL` (read | write | execute) permissions. This indicates that the WebContent sandbox policy does not restrict this kernel trap, allowing exploit code to create writable-and-executable memory pages outside the JIT cage. These pages are used to stage and execute arbitrary ARM64 shellcode.

---

## 2. Vulnerability Description

### 2.1 The Security Assumption Being Violated

The WebContent process sandbox is designed to restrict the process to only the operations needed for web rendering. The security model for code execution assumes:
- Only the JIT compiler should be able to create executable memory
- The JIT cage constrains all JIT-compiled code to a designated region
- Arbitrary executable memory allocation from the sandbox should be blocked

### 2.2 The Flaw

The observed exploit calls `mach_vm_allocate` (resolved from `libdyld.dylib` via `dlsym`) to allocate memory with full RWX permissions:

```
mach_vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE)
mach_vm_protect(mach_task_self(), address, size, FALSE, VM_PROT_ALL)
```

This succeeds from within the WebContent sandbox, indicating:

1. The `mach_vm_allocate` Mach trap is **not filtered** by the sandbox profile
2. `VM_PROT_EXECUTE` permission is **granted** for pages allocated this way
3. The resulting pages are **outside the JIT cage** — they are not subject to JIT code signing verification

### 2.3 Exploitation Flow

```
1. Resolve _mach_vm_allocate from /usr/lib/system/libdyld.dylib via dlsym
2. Call via Wasm trampoline (Report C) with:
   - task = mach_task_self()
   - size = shellcode length (rounded to page size)
   - flags = VM_FLAGS_ANYWHERE
3. Kernel allocates RWX page and returns address
4. Write ARM64 shellcode to the allocated page
5. Compute PACDB rolling hash (Report B) for kernel verification
6. Execute shellcode via Wasm call_indirect table pointer swap
```

### 2.4 Fallback Mechanism

The exploit includes a fallback method `Lg()` that navigates JSC's internal JIT handler table when the primary `mach_vm_allocate` path is blocked. This suggests the exploit authors encountered environments where the primary path was restricted, confirming that **some hardening exists but is not universal**.

---

## 3. Technical Details

### 3.1 Symbol Resolution Chain

| Step | Symbol | Source Library |
|---|---|---|
| 1 | `dlsym` | Resolved via Wasm R/W primitive from libobjc export trie |
| 2 | `_mach_vm_allocate` | Resolved via `dlsym` from `libdyld.dylib` |
| 3 | `_mach_vm_protect` | Resolved via `dlsym` from `libdyld.dylib` |
| 4 | `mprotect` | Alternative — resolved as backup for permission changes |

### 3.2 Memory Usage

The allocated RWX pages serve two purposes:

1. **Shellcode staging** — ARM64 instructions are written to the page, then signed with the rolling PACDB hash chain
2. **Return value buffer** — the Wasm trampoline reads return values from the page's linear memory

### 3.3 No Legitimate Use Case

The WebContent process has **no legitimate reason** to allocate RWX memory outside the JIT cage. All legitimate JIT compilation goes through JSC's `ExecutableAllocator`, which:
- Allocates within the JIT cage region
- Uses the kernel's JIT code signing mechanism
- Is subject to JIT operation list validation

Any `mach_vm_allocate` with `VM_PROT_EXECUTE` from the WebContent process is, by definition, anomalous.

---

## 4. Impact Assessment

**Severity: High**

This sandbox policy gap enables:

1. **Arbitrary executable memory allocation** — the attacker can create as many RWX pages as needed
2. **JIT cage bypass** — code in these pages is not subject to JIT cage restrictions
3. **Shellcode staging** — combined with the PACDB hash forgery (Report B), allows execution of arbitrary ARM64 code
4. **Persistence within session** — allocated pages survive until the WebContent process exits

Without this capability, the attacker would be confined to the JIT cage and could not execute custom shellcode.

---

## 5. Suggested Mitigations

1. **Block `mach_vm_allocate` with `VM_PROT_EXECUTE` from WebContent** — add a sandbox rule that denies `mach_vm_allocate` / `mach_vm_protect` calls that request execute permission, except when called from the JIT compiler's designated code path.

2. **Enforce MAP_JIT for all executable allocations** — require that all executable memory within the WebContent process use the `MAP_JIT` flag, which constrains allocations to the JIT cage and enables per-thread W^X toggling via `pthread_jit_write_protect_np`.

3. **Audit sandbox profiles across platforms** — verify that both iOS and macOS WebContent sandbox profiles consistently restrict executable memory allocation. The fallback path (`Lg()`) suggests inconsistent enforcement.

4. **Monitor for anomalous `mach_vm_allocate` calls** — add telemetry to detect RWX allocations from WebContent processes, which are always indicative of exploitation.

---

## 6. Evidence Source

Identified through static reverse engineering of an in-the-wild, multi-stage iOS/macOS browser exploit chain. The `mach_vm_allocate` invocation is in a dedicated JIT page allocator class, with a fallback path that navigates JSC's internal JIT handler table when the primary path is unavailable. The exploit resolves `_mach_vm_allocate` from `libdyld.dylib` at runtime via `dlsym`. Full source artifacts and detailed analysis are available upon request.

---

*Prepared for Apple Security Bounty Program.*
