# Apple Security Bounty Report: Stable Unsigned GOT Entries Across iOS Versions in Private Frameworks

**Date:** March 2026
**Severity:** Medium-High
**Component:** Private framework GOT layout stability — HomeSharing, CoreML, PassKitCore, AppleMediaServices, SpringBoard, MediaToolbox
**Affected Platforms:** iOS 16.0–17.x, macOS (arm64e devices: A12+ / M1+)
**Category:** Insecure Design — Predictable Framework Memory Layout

---

## 1. Executive Summary

An in-the-wild exploit framework maintains a **version-indexed table of stable, unsigned GOT entry offsets** across six Apple private frameworks spanning iOS 16.0 through 17.1+. These offsets have remained consistent enough across point releases that the exploit can pre-compute them — selecting the correct framework and offset pair based on the victim's iOS version. This stability indicates that Apple's private frameworks contain **unsigned GOT entries at predictable locations** that survive compiler re-randomization, ASLR, and version updates, providing reliable PAC bypass gadgets to attackers.

---

## 2. Vulnerability Description

### 2.1 The Core Issue

The observed exploit does not brute-force gadget locations. Instead, it carries a **hardcoded lookup table** mapping iOS version ranges to specific (framework, offset) pairs:

| iOS Version | Primary Framework | Offset | Secondary Framework | Offset |
|---|---|---|---|---|
| ≥17.1 | HomeSharing | 56416 | PassKitCore | 25497 |
| ≥17.0 | CoreML | 34022 | AppleMediaServices | 56883 |
| ≥16.4 | CoreML | 62253 | SpringBoard | 39351 |
| ≥16.0 | HomeSharing | 39661 | CoreML | 4123 |
| Fallback | MediaToolbox | 61040 | MediaToolbox | 61040 |

The fact that these offsets are hardcoded — not discovered at runtime — means they are **stable across point releases** within each version bracket. An offset that changed with every minor update would require runtime scanning, not a static table.

### 2.2 Why This Matters

These stable offsets point to **unsigned GOT entries** within the named frameworks. These entries are:

1. **Not PAC-protected** — they reside in `__DATA` or `__DATA_CONST`, not `__AUTH_CONST`
2. **Writable** — the exploit modifies them via the arbitrary write primitive
3. **Used in PAC-authenticated call chains** — legitimate framework code reads these entries and passes the resolved addresses through PAC-authenticated indirect calls
4. **Predictable** — the same offset works across all devices running the same iOS version bracket

This converts what should be an ASLR-protected, PAC-authenticated call chain into a deterministic exploit primitive.

### 2.3 The Gadget Discovery Process

The exploit's gadget selection (from the platform config module `81502427`) operates as follows:

```
1. Read iOS version integer from config blob (T.Dn.dn)
2. Select framework and offset from the version lookup table
3. Parse the selected framework's Mach-O __TEXT segment from the dyld shared cache
4. Read the 3-instruction gadget pattern at the known offset
5. PAC-sign the gadget address using PACDB (lc.oe())
6. Store the signed pointer in the payload header
```

Steps 3–6 are **validation** — the exploit verifies the known offset still works on this specific device. But the offset itself is **pre-known** from the hardcoded table. The exploit does not perform a runtime scan; it goes directly to the expected location.

---

## 3. Technical Details

### 3.1 Affected Frameworks

| Framework | Path | Type | Used In Versions |
|---|---|---|---|
| HomeSharing | `/System/Library/PrivateFrameworks/HomeSharing.framework/HomeSharing` | Private | ≥17.1, ≥16.0 |
| CoreML | `/System/Library/Frameworks/CoreML.framework/CoreML` | Public | ≥17.0, ≥16.4, ≥16.0 |
| PassKitCore | `/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore` | Private | ≥17.1 |
| AppleMediaServices | `/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices` | Private | ≥17.0 |
| SpringBoard | `/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard` | Private | ≥16.4 |
| MediaToolbox | `/System/Library/Frameworks/MediaToolbox.framework/MediaToolbox` | Public | Fallback (all) |

### 3.2 What the Gadgets Provide

Each gadget is a short instruction sequence (typically 3 ARM64 instructions) that performs an indirect call through a nearby GOT entry. The pattern is:

```
ADRP    x16, GOT_page
LDR     x16, [x16, #GOT_offset]
BR      x16
```

or an authenticated variant:

```
ADRP    x16, GOT_page
LDR     x16, [x16, #GOT_offset]
BRAA    x16, x17
```

In the unauthenticated variant (`BR x16`), the GOT entry is loaded and branched to without PAC verification. The exploit overwrites this GOT entry with the target address, and the framework's own code jumps to it.

### 3.3 Extended PAC Mode

When the platform config indicates extended PAC mode (`T.Dn.zn === true`), the exploit performs additional PACDA signing of four ObjC method pointers (`ib`, `lb`, `ob`, `tb`) from dyld cache stages. These are embedded in the final payload's 23-field header structure, ensuring the gadgets work even when the target device enforces stricter pointer authentication.

---

## 4. Impact Assessment

**Severity: Medium-High**

This stability enables:

1. **Pre-computed exploit payloads** — the attacker does not need to perform runtime scanning, reducing exploit complexity and detection surface
2. **Cross-device reliability** — the same exploit binary works on all devices within a version bracket
3. **Resistance to minor updates** — point releases that don't restructure the affected frameworks leave the gadgets intact
4. **Broad version coverage** — the five-tier table covers iOS 16.0 through 17.1+, meaning the exploit has worked for over a year of iOS releases

This is rated Medium-High rather than Critical because it is an **enabler** rather than a standalone vulnerability — it requires the GOT-swap PAC bypass (Report A) and arbitrary R/W primitive to be useful. However, its stability is what makes the full chain reliable across the device population.

---

## 5. Suggested Mitigations

1. **Randomize GOT layout per-build** — compile private frameworks with randomized GOT entry ordering so that offsets change with every release, breaking pre-computed offset tables.

2. **Convert identified unsigned GOT entries to `__AUTH_CONST`** — any GOT entry in the affected frameworks that is used in an indirect call chain should be moved to the PAC-authenticated `__AUTH_CONST` segment.

3. **Add padding/canary entries to GOT tables** — insert random padding entries between GOT slots. This would cause hardcoded offsets to resolve to invalid entries, causing the exploit to fail or crash detectably.

4. **Instrument private framework GOT access** — add runtime monitoring for reads of the specific GOT entries at the identified offsets from non-framework code. Access from the WebContent process to private framework GOT entries is always anomalous.

5. **Review all `BR x16` (unauthenticated branch) gadgets** — systematically audit the six affected frameworks for `BR x16` patterns that load from unsigned GOT entries. Replace with `BRAA x16, xN` (authenticated branch) where possible.

---

## 6. Evidence Source

Identified through static reverse engineering of an in-the-wild, multi-stage iOS/macOS browser exploit chain. The version-indexed gadget table is embedded in a dedicated platform configuration module. Gadget selection logic is in the trigger mechanism modules, and the version thresholds are decoded from XOR-encoded configuration data. Full source artifacts and detailed analysis are available upon request.

---

*Prepared for Apple Security Bounty Program.*
