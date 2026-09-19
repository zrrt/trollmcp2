# Inside Coruna: Reverse Engineering a Nation-State iOS Exploit Kit From JavaScript

**March 2026** | **nadsec.online**

---

## TL;DR

When Google Threat Intelligence Group and iVerify published their Coruna reports on March 3, 2026, I pulled the 28 JavaScript modules from [matteyeux's public dump](https://github.com/matteyeux/coruna) and started digging into the raw source. I reverse-engineered the exploit chain from the obfuscated JavaScript - deobfuscating 191 unique XOR-encoded strings, extracting inline WebAssembly modules, reconstructing ARM64 gadget scanners, and documenting every class, method, and exploitation primitive across ~700KB of code. The result is a 6,630-line technical analysis covering 8 vulnerabilities - zero-days at the time of deployment, since patched by Apple - spanning WebKit RCE, PAC bypass, JIT cage escape, and sandbox escape on iOS 16.0-17.2.

Google and iVerify approached the kit from network captures, binary analysis, and forensic artifacts. I approached it from the other direction - the raw JavaScript.

This post covers what I found that their analyses didn't: the internal exploitation mechanics as implemented in JavaScript, including the PACDB rolling hash forgery algorithm, the GOT-swap confused-deputy PAC bypass, and three parallel WebKit RCE paths including an iOS-specific OfflineAudioContext/SVG exploitation path.

The complete 6,630-line technical analysis is available on [GitHub](https://github.com/Rat5ak/CORUNA_TECHNICAL_ANALYSIS).

---

## Background: What Is Coruna?

On March 3, 2026, Google TIG [published](https://cloud.google.com/blog/topics/threat-intelligence/coruna-powerful-ios-exploit-kit/) what they described as "a new and powerful exploit kit targeting Apple iPhone models running iOS version 13.0 up to version 17.2.1." They named it Coruna - the developer's internal codename found in a debug build left on one of the delivery servers.

The kit contains **23 exploits across 5 full exploit chains**, covering nearly every iPhone model released over four years. Google documented its journey:

1. **Early 2025** - First observed in use by a customer of a commercial surveillance vendor
2. **Summer 2025** - Deployed by **UNC6353** (suspected Russian espionage) on compromised Ukrainian websites via `cdn.uacounter[.]com`
3. **Late 2025** - Mass-deployed by **UNC6691** (Chinese financially-motivated actor) across fake cryptocurrency and gambling sites

The proliferation path tells a story. Australian national **Peter Williams** - a former executive at L3Harris subsidiary Trenchant - was [sentenced to 87 months](https://cyberscoop.com/l3harris-executive-peter-williams-sentenced-zero-day-exploits-russia/) on February 25, 2026 for stealing exploits from his employer and selling them to **Operation Zero**, a Russian exploit broker that was [sanctioned by US Treasury](https://home.treasury.gov/news/press-releases/sb0404) the same week. iVerify told WIRED the kit "might have been initially developed for the US government" and noted its similarities to the **Operation Triangulation** exploits documented by Kaspersky in 2023. Google confirmed that two Coruna exploits (Photon and Gallium) use the same vulnerabilities as Triangulation.

So: a toolkit likely built for US intelligence, stolen by an insider, sold to Russian brokers, deployed against Ukrainian targets, and ultimately ending up on Chinese crypto scam sites targeting random iPhone users. The full lifecycle of a nation-state exploit.

**Update (March 7):** Two days after Google's publication, CISA added [CVE-2023-41974](https://nvd.nist.gov/vuln/detail/CVE-2023-41974) to their Known Exploited Vulnerabilities catalog. It's a kernel use-after-free in iOS (reported by Felix Poulin-Belanger, patched in iOS 17). The NVD entry directly references Google's Coruna blog post. This is the kernel privilege escalation component of the chain -- the stage that comes after everything documented in this analysis. My original analysis covered WebKit RCE through PAC bypass to shellcode execution in the WebContent process. Since then, I've obtained and analyzed the kernel exploit binary itself - a 2MB ARM64 DYLIB recovered by matteyeux from a compromised iPhone X. The full kernel exploit analysis is [below](#stage-5-kernel-exploitation-dumpbin) and in a [standalone report](https://github.com/Rat5ak/CORUNA_TECHNICAL_ANALYSIS).

---

## How I Got Here

When Google TIG and iVerify dropped their Coruna publications on March 3, 2026, the JavaScript source was already public - [matteyeux](https://github.com/matteyeux/coruna) had posted the dump on GitHub. I grabbed the 28 modules (~700KB total) and started pulling them apart.

### What I Had to Work With

The obfuscation wasn't sophisticated but it was *thorough*:

- **XOR-encoded strings** - Every meaningful string (function names, symbol paths, framework identifiers) was encoded as an integer array with XOR key: `[16, 22, 0, 69, 22, 17, 23, 12, 6, 17].map(x => String.fromCharCode(x ^ 101)).join("")`
- **Obfuscated integers** - Constants encoded as XOR pairs: `(1111970405 ^ 1111966034)` instead of writing the actual value
- **Minified variable names** - Every variable, class, and method was a 2-6 character random identifier (`bvVGhS`, `PtqWRQ`, `khTYss`)
- **No comments, no whitespace** - Standard minification on top of the above

I deobfuscated 191 unique strings, extracted and disassembled inline WebAssembly modules, demangled C++ symbol references, and mapped every class to its functional purpose. The result is a [6,630-line technical analysis](https://github.com/Rat5ak/CORUNA_TECHNICAL_ANALYSIS) documenting the complete chain.

### What's Different About This Analysis

Google's and iVerify's publications approached Coruna from the *outside*:

| | **Google TIG** | **iVerify** | **This Analysis** |
|---|---|---|---|
| **Approach** | Network captures, binary analysis | Forensic artifacts, device analysis | JavaScript source reverse engineering |
| **Scope** | All 5 chains, CVE mapping, attribution | Detection IOCs, implant behavior | Deep internals of one chain variant |
| **Exploit detail** | CVE IDs + codenames | Infection flow | Full algorithm reconstruction |
| **PAC bypass** | "non-public exploitation techniques" | Not covered | Complete GOT-swap mechanism documented |
| **JIT cage escape** | Not detailed | Not covered | PACDB rolling hash algorithm reconstructed |

Google identified **what** the exploits target. This analysis documents **how** they work, instruction by instruction, as implemented in JavaScript.

---

## Architecture Overview

The Coruna kit I recovered from `b27.icu` consists of 15 unique JavaScript modules (28 files including inner payloads) organized as a custom module system. Each module self-registers using a SHA1 hash as its identifier and declares dependencies on other modules. The loader resolves dependencies and executes modules in order.

The chain follows this flow:

```
Visitor lands on watering-hole page
    │
    ├── Fingerprinting (iOS vs macOS, WebKit version, Lockdown Mode check)
    │
    ▼
WebKit RCE (3 parallel paths - selected by platform/version)
    │
    ├── Path 1: NaN-Boxing Type Confusion (macOS primary - YGPUu7)
    ├── Path 2: JIT Structure Check Elimination (macOS alt - KRfmo6)
    └── Path 3: OfflineAudioContext Heap Corruption + SVG R/W (iOS - Fq2t1Q)
    │
    ▼
Arbitrary Read/Write Primitive (Class P or Class ut)
    │
    ▼
Wasm call_indirect Dispatch Hijack (class ct)
    → Converts Wasm sandbox into native function call primitive
    │
    ▼
PAC Bypass via Unsigned GOT-Swap (classes ta, ia, ca)
    → Apple frameworks authenticate attacker-supplied addresses
    │
    ▼
mach_vm_allocate RWX from WebContent Sandbox
    → Executable pages outside JIT cage
    │
    ▼
JIT Cage Escape via PACDB Hash Forgery (class hc)
    → Arbitrary shellcode passes kernel verification
    │
    ▼
ARM64 shellcode execution in WebContent process
    │
    ▼
Final Payloads → C2 callback to b27.icu
    → Process info, User-Agent, URL exfiltrated
    │
    ▼
Kernel exploit (dump.bin) downloaded via C2
    → Injected into powerd daemon
    → IOSurfaceRoot (CVE-2023-41974) → kernel R/W
    → Privilege escalation → sandbox escape → rootfs remount
    │
    ▼
PlasmaLoader → persistent root implant + crypto theft
```

In Google's terminology, my analysis primarily covers the **cassowary** (CVE-2024-23222) and **seedbell** exploit chain variant - the WebContent R/W + PAC bypass + sandbox escape path targeting iOS 16.x-17.2. But the JavaScript source contains the complete implementation of techniques that Google described only at the CVE level.

The next sections walk through each stage. I'll focus on the internals that Google and iVerify didn't cover - the actual exploitation algorithms as they exist in the JavaScript.

---

## WebKit RCE: Three Paths In

Coruna doesn't rely on a single WebKit vulnerability. The kit contains **three independent exploit paths** into the WebKit renderer, selected at runtime based on platform and Safari version:

| Path | Module | Platform | Vulnerability Class |
|------|--------|----------|-------------------|
| **Path 1** | `YGPUu7_8dbfa3fd.js` | macOS (primary) | NaN-Boxing Type Confusion |
| **Path 2** | `KRfmo6_166411bd.js` | macOS (alternate) | JIT Structure Check Elimination |
| **Path 3** | `Fq2t1Q_dbfd6e84.js` | iOS | OfflineAudioContext Heap Corruption + SVG R/W |

All three paths converge on the same output: an arbitrary memory read/write primitive stored at `T.Dn.Pn` (a global state slot). From there, the post-exploitation chain is platform-independent.

Google identified the WebKit RCE components by codename - **cassowary** (CVE-2024-23222) maps to one of these paths. But their publication describes the vulnerability at the CVE level. The JavaScript source reveals exactly how each vulnerability is triggered, including the JIT warmup strategies, the specific integer overflow conditions, and the heap grooming sequences.

### Path 1: NaN-Boxing Type Confusion (YGPUu7)

**Source:** `YGPUu7_8dbfa3fd.js` (~10KB) - macOS primary path

This is the cleanest of the three RCE paths and the one that best illustrates how the Coruna developers think about exploitation. It targets JavaScriptCore's value representation itself - the NaN-boxing scheme that every JS value in memory depends on.

**How JSC NaN-Boxing Works**

In JavaScriptCore's 64-bit engine, every JavaScript value is encoded as an IEEE 754 double. Pointers. Integers. Booleans. All of them. The trick is that IEEE 754 defines a huge range of bit patterns as "Not a Number" - and JSC encodes non-double values in that NaN space. The upper bits of a value tell JSC whether it's looking at a double, a pointer, or an integer:

| Bits 63:44 | Meaning |
|------------|---------|
| Normal float range | Actual double value |
| NaN range markers | JSCell pointer (object/string/etc.) |
| Specific tag patterns | Integer, boolean, null, undefined |

A JSCell (the base type for all heap objects) starts with an 8-byte header:

| Bits | Field | Purpose |
|------|-------|---------|
| `[63:52]` | StructureID | Index into JSC's structure table (12 bits) |
| `[51:48]` | Indexing type | Array storage mode (4 bits) |
| `[47:40]` | Cell type | Object kind identifier (8 bits) |
| `[39:32]` | Flags | GC and allocation metadata |
| `[31:0]` | Butterfly | Pointer to property/element storage (32 bits) |

The exploit's goal: forge a double value whose bit pattern JSC will interpret as a valid JSCell pointer.

**Forging the Fake Object**

The `r.kr` function constructs synthetic NaN-boxed values using aliased typed array views - a `Float64Array` and `Uint32Array` sharing the same `ArrayBuffer`. Writing integers to the `Uint32Array` and reading the same bytes as a `Float64Array` lets you splice arbitrary bit patterns into IEEE 754 doubles:

```javascript
const r = new ArrayBuffer(64);
const i = new Uint32Array(r);      // integer view
const s = new Float64Array(r);     // double view (same memory)

// Random 12-bit StructureID to avoid collision with real structures
const n = e(1,8)<<8 | e(1,8)<<4 | e(1,8)<<0;
const h = e(1, 16777215);  // random butterfly value

// Forge a fake JSCell header as a double:
const a = (cellType, flags) => {
    i[1] = n<<20 | 4<<16 | cellType;   // structureID | indexingType=4 | cellType
    i[0] = flags<<24 | h;              // flags | butterfly
    const e = s[0];                    // reinterpret as IEEE 754 double
    if (isNaN(e)) throw new Error(""); // MUST NOT land in actual NaN range
    return e;
};
```

The `isNaN()` guard is critical. If the forged bit pattern falls within the IEEE 754 NaN range (`0x7FF0000000000001`-`0x7FFFFFFFFFFFFFFF`), JSC would read it as NaN instead of a pointer - the confusion fails. The random StructureID stays in the range `0x111`-`0x888`, keeping the double's exponent field below the NaN threshold.

Before triggering, the exploit sprays 400 identical empty arrays to populate JSC's structure table with predictable entries:

```javascript
let t = new Array(400);
t.fill([]);
```

Plus 16 auxiliary object arrays with nested structures (`a0` through `a15`) to create predictable StructureIDs.

**The Base64 Trigger**

The actual type confusion lives inside a `new Function()` constructed from a base64-encoded string. Decoded:

```javascript
for (let t = 0; t < 2; t++) {
    if (b === true) {
        if (!(a === -2147483648)) return -1;   // INT32_MIN guard
    } else {
        if (!(a > 2147483647)) return -2;      // INT32_MAX guard
    }
    if (k === 0) a = 0;
    if (a < g) {
        if (k !== 0) a -= 2147483647 - 7;     // integer underflow!
        if (a < 0) return -3;
        let t = l[a];                          // OOB read
        if (d) {
            l[a] = r;                          // OOB write
        }
        return t;
    }
}
```

The trick: pass a value near `INT32_MAX` (2147483647), then subtract `2147483640`. The result is a small positive index - but through a code path JSC's JIT already speculated was unreachable. The function gets warmed up with **1,000,000 iterations** to force JIT compilation before switching to exploit mode.

**What Falls Out**

After the trigger fires, the exploit reads back the corrupted memory through the aliased typed arrays and recovers the actual StructureID that JSC assigned:

```javascript
const S = {
    Qr: i[1] >> 20 & 0xFFF,    // structureID (12 bits)
    zr: i[1] >> 16 & 0xF,      // indexing type
    Fr: 0xFFFF & i[1],          // lower structure bits
    Lr: i[0] >> 24 & 0xFF,     // flags
    Rr: 0xFFFFFF & i[0]        // butterfly (24 bits)
};
```

The StructureID and butterfly values are verified against the forged values - if they match, JSC is treating the fake double as a real object. The indexing type difference gives the **NaN offset** (`T.Dn.Mn = 65536 * (S.zr - 4)`), a correction factor stored globally and used by all subsequent stages to translate between double-encoded and raw pointer representations.

From here, YGPUu7 constructs the Class P memory primitive - `addrof`, `read32`, `read64`, `write32`, `write64` - all rooted in this single type confusion. The WebKit renderer is now fully compromised.

### Path 2: JIT Structure Check Elimination (KRfmo6)

**Source:** `KRfmo6_166411bd.js` (~24KB) - macOS alternate path

Where YGPUu7 attacks JSC's value representation, KRfmo6 attacks the JIT compiler itself. It tricks JSC's DFG/FTL optimization pipeline into eliminating a structure check - the runtime guard that ensures an object still has the type the JIT assumed when it compiled the code.

**Dual-Path Architecture**

KRfmo6 is unique among the three paths because it runs **two independent exploit attempts** - one in the main thread, one in a Web Worker:

```javascript
if (navigator.constructor.name === "Navigator") {
    // Main thread: stack corruption via recursive try/catch
    et();       // apply version-specific offsets
    ht(t);      // main-thread path
} else {
    // Web Worker: JIT optimization bug
    self.onmessage = t => {
        l = t.data.dn;   // receive WebKit version from parent
        et();             // apply offsets
        ct();             // worker exploit path
    };
}
```

The main thread launches a Worker from an inline `Blob` URL. Three message types coordinate them: type `0` (progress), type `1` (Worker failed - retry with a new one), and type `2` (Worker succeeded - main thread continues with a stack corruption trigger). This retry mechanism makes KRfmo6 significantly more reliable in the field than YGPUu7's single-shot approach.

**42 Version-Adaptive Offsets**

Before either path runs, `et()` adjusts a table of 42 JSC internal structure offsets based on the WebKit version number. Three version thresholds (170000, 170100, 170200) trigger different offset sets - these correspond to Safari/WebKit builds where Apple reorganized internal structures:

```javascript
function et() {
    if (l >= 170000) {
        tt["01"] = 96;  tt["02"] = 88;
        tt["27"] = 77464;  tt["28"] = 77472;
    }
    if (l >= 170100) {
        tt["27"] = 78488;  tt["28"] = 78496;
    }
    if (l >= 170200) {
        tt["27"] = 78528;  tt["28"] = 78536;
    }
}
```

Offsets `tt["27"]` and `tt["28"]` - values like 77464, 78488, 78528 - are offsets into JSC's JIT code region. These change with nearly every WebKit release, and getting them wrong means crashing instead of exploiting. The Coruna developers clearly had access to multiple WebKit builds for testing.

**Triggering the Structure Mismatch**

The Worker path `ct` creates two objects via `Reflect.construct()` that share the same constructor but end up with different internal Structures (JSC's hidden class system):

```javascript
function n() {}
let r = Reflect.construct(Object, [], n);
let i = Reflect.construct(Object, [], n);

r.p1 = [1.1, 2.2];   // r gets Structure S1 - p1 is a double array
r.p2 = [1.1, 2.2];

i.p1 = 3851;          // i gets Structure S2 - p1 is an integer
i.p2 = 3821;
delete i.p2;           // reshape i
delete i.p1;
i.p1 = 3853;          // reattach properties with different types
i.p2 = 4823;
```

Now `r.p1` is a double array and `i.p1` is an integer - but both objects were created with constructor `n`, so JSC's JIT may speculate they share the same Structure.

The critical function `h(t, n)` is then JIT-compiled over millions of iterations, alternating between `r` and `i`. It contains **72 redundant `while` loops** - specifically designed to bloat JSC's DFG control flow graph and trigger aggressive optimization passes:

```javascript
// 72 of these (two groups of 36), filling the DFG graph:
while (h < 1) { s.guard_p1 = 1; h++ }
while (h < 1) { s.guard_p1 = 1; h++ }
// ... 70 more ...

let u = o.p1;        // JIT speculates: always a double array
if (t) u = e;        // branch never taken during warmup
c[0] = u[1];         // read second element of "array"
l[0] = l[0] + 16;    // shift the butterfly pointer by 16 bytes
u[1] = c[0];         // write back - but butterfly is now displaced
```

After enough iterations, the JIT eliminates the structure check on `o.p1` - it "knows" `p1` is always a double array. When the exploit finally passes `i` (where `p1` is an integer), the JIT reads through a corrupted pointer, giving a **16-byte relative read/write displacement**.

**Building R/W Primitives (pm.ws)**

That 16-byte displacement is fragile - `pm.ws()` turns it into stable `addrof`, `read`, and `write` primitives:

```javascript
// addrof: leak any object's heap address
m.ps = function(n) {
    o.b1 = n;                    // store target object
    pm.gRWArray1[2] = t;        // set up displaced target
    h(1, 1.1);                  // trigger displaced read
    return L(e[0]);             // recover leaked pointer
};

// read 64 bits at arbitrary address
m.ys = function(addr) {
    a[1] = l;
    e[0] = K(addr);             // encode address as float
    e[1] = x;
    return L(f());              // displaced read returns value
};

// write 64 bits at arbitrary address
m.bs = function(addr, val) {
    a[1] = l;
    e[0] = K(addr);
    e[1] = x;
    e[2] = K(val);
    w();                        // displaced write
};
```

**Upgrading to Absolute R/W (pm.Us)**

The displacement primitives are still relative to the corrupted object. `pm.Us()` upgrades to absolute addressing by creating a controlled `Array`, leaking its internal backing store pointer, and hijacking `Array.prototype.length` to read/write anywhere:

```javascript
m.ns = function(t) {          // absolute read32
    m.bs(n + 8, t + 8);      // redirect array backing store to target
    let i = e();              // read via .length property
    m.bs(n + 8, r);          // restore original backing store
    return i >>> 0;
};

m.rs = function(t) {          // absolute read64
    return m.ns(t) + (m.ns(t+4) & 0x7FFFFFFF) * 4294967296;
};
```

The `& 0x7FFFFFFF` mask on the high word is **PAC bit stripping** - clearing the pointer authentication bits that ARM64e adds to every pointer. Without this mask, the leaked addresses would include PAC signatures that make them unusable as raw pointers.

After validation and cleanup, the resulting R/W primitive is stored at `T.Dn.Pn` - the same global slot YGPUu7 writes to. The rest of the chain doesn't care which path got there first.

### Path 3: OfflineAudioContext Heap Corruption + SVG R/W (iOS)

**Source:** `Fq2t1Q_dbfd6e84.js` (~29KB) - iOS-only path

This is the most complex of the three paths and architecturally distinct from both macOS approaches. Where Paths 1 and 2 exploit JSC's type system or JIT compiler directly, Path 3 builds its R/W primitive entirely through **heap corruption of DOM objects** - no JIT tricks at all. It chains two separate WebKit vulnerabilities:

1. **`OfflineAudioContext.decodeAudioData`** - heap corruption via crafted audio buffers
2. **SVG `feConvolveMatrix.orderX.baseVal`** - arbitrary R/W via corrupted SVG filter attributes

The entire module is `async` - reflecting the need for multiple `decodeAudioData` round-trips to corrupt memory incrementally. The macOS paths are synchronous single-shot exploits. This one is a patient, iterative campaign against the heap.

**Phase 1: Heap Spray with Intl.NumberFormat**

The exploit begins by spraying **7,000 `Intl.NumberFormat` objects** onto the heap:

```javascript
for (let i = 0; i < 7000; i++)
    target[offset + i] = new Intl.NumberFormat("en-US", {})
```

Each `NumberFormat` gets its ICU internals initialized via `.format(1)`, `.format(2)`, `.format(3)`. Alongside the real spray, the code creates `NumberFormat` objects with an **invalid locale** - `"dowocjfjq["` - to exercise a different ICU code path and diversify the heap layout. Between allocation rounds, ~960 MB of temporary `ArrayBuffer` allocations (240 × 4 MB) are created and immediately discarded to trigger garbage collection and create heap gaps.

**Phase 2: Audio Buffer Corruption**

The exploit constructs custom audio buffers using a chunk-based container format with 6 chunk types (audio description, cookie data, packet table, audio data, channel layout, marker). Two buffer variants matter:

- **Warm-up buffer** (class `C`): Standard channel data, used for heap grooming
- **Exploit buffer** (class `p`): Channel data with carefully computed entry sizes that cause the audio decoder to write past its allocated region

The corruption sequence calls `decodeAudioData` **20 times**, alternating between the exploit buffer and a deliberately malformed buffer (to trigger error-path allocations in the decoder). After each round, it scans all 7,000 `NumberFormat` objects:

```javascript
// Check for corruption: format(1.02) should produce exactly 4 characters
let result = target[i].format(1.02);
if (result.length !== 4) {
    // This NumberFormat's internal buffer was overwritten by the audio decoder
    // Extract leaked pointer from the corrupted string:
    let leaked = result.charCodeAt(17) | (result.charCodeAt(18) << 16) | ...
}
```

A valid `format(1.02)` returns `"1.02"` - 4 characters. If the length differs, the object's internal ICU string buffer has been overwritten by the audio decoder's heap overflow. The corrupted string contains heap pointers readable via `charCodeAt()`. This retries up to 12 rounds with increasing heap offsets.

**Phase 3: SVG feConvolveMatrix R/W Primitive**

With a corrupted `NumberFormat` providing initial memory reads, the exploit builds a **stable R/W channel** through SVG filter elements:

```javascript
et[0] = document.createElementNS("http://www.w3.org/2000/svg", "feConvolveMatrix")
et[1] = document.createElementNS("http://www.w3.org/2000/svg", "feConvolveMatrix")
et[2] = document.createElementNS("http://www.w3.org/2000/svg", "feConvolveMatrix")
```

Three `feConvolveMatrix` elements, each with its `orderX` attribute extracted:
- `ot = et[0].orderX` - lower 32 bits of target address
- `st = et[1].orderX` - upper 32 bits of target address
- `at = et[2].orderX` - data read/write channel

The key insight: `feConvolveMatrix.orderX.baseVal` is an `SVGAnimatedInteger`. When you write to `baseVal`, WebKit writes directly to the element's backing store in native memory. By corrupting the element's internal `m_value` pointer (using the NumberFormat leak), writes to `baseVal` become writes to **arbitrary memory locations**.

Class `z` wraps this into a clean API:

| Method | Operation |
|--------|-----------|
| `Si(addr)` | Set target: writes `addr >> 32` to `st.baseVal`, `(addr - 28) & 0xFFFFFFFF` to `ot.baseVal` |
| `Ai(val)` | Write: sets `at.baseVal` via DataView uint32 round-trip |
| `Ti()` | Read: reads `at.baseVal` back via DataView uint32 |
| `tA(obj)` | Get JSCell address: writes object to backing store, reads internal pointer |

The subtraction of 28 in `Si()` is an offset compensation - the SVG element's internal structure places the actual value 28 bytes after the pointer the exploit controls.

**Phase 4: Dyld Cache Walking**

With R/W established, the exploit needs to find runtime symbols. On macOS, the other paths use pre-built Mach-O parsers. On iOS, Path 3 walks the **dyld shared cache** inline:

1. **Find MH_MAGIC_64**: Starting from the leaked address, align to 655,360 bytes and scan backward looking for `0xfeedfacf`
2. **Parse load commands**: Read `LC_SEGMENT_64` entries to find `__TEXT` (for ASLR slide) and `__LINKEDIT` (for symbol table base)
3. **Walk the compressed export trie**: Same LEB128+trie structure as the shared cache, parsed in JavaScript to resolve `_pthread_main_thread_np`
4. **Decode ARM64 instructions**: Read ADRP+LDR pairs at the resolved function to extract the `_main_thread` pointer address

**Phase 5: Stack Scanning for Bridge**

The final challenge: connecting the corrupt R/W primitive (which operates through SVG elements) to the exploit's JavaScript execution context. The exploit previously placed four **NaN-boxed magic markers** into a 200-element array (`tt`):

| Offset | Marker Value |
|--------|-------------|
| +0 | `0xfffe000000055432` |
| +8 | `0xfffe000000066533` |
| +24 | `0xfffe000000022334` |
| +32 | `0xfffe000000099234` |

Using the thread list from `_pthread_main_thread_np`, the exploit traverses run loop observers, finds stack frames with sufficient size (≥40,960 bytes), and scans for all four markers. When found, offset +16 gives the **address of the `tt` array itself** - bridging the SVG R/W world to the JavaScript heap.

From there: write the SVG handles into array slots, read back their JSCell addresses, patch reference counts (+16384) and type flags (+16384) to prevent GC collection, and construct the same Class P memory primitive that Paths 1 and 2 produce. The output goes to `T.Dn.Pn`.

**Three Paths, One Destination**

| Aspect | NaN-Boxing (5.1) | JIT Optimization (5.2) | Audio/SVG (5.3) |
|--------|------------------|------------------------|------------------|
| **Platform** | macOS (primary) | macOS (fallback) | iOS |
| **Bug class** | Type confusion | Structure check elimination | Heap overflow + DOM corruption |
| **R/W primitive** | Wasm memory views | Array butterfly displacement | SVG feConvolveMatrix.orderX |
| **Sync/Async** | Synchronous | Synchronous | Async (await throughout) |
| **Retry mechanism** | Single attempt | Worker retry | 12 rounds × 40 decodeAudioData |
| **Self-contained** | No | Yes | Yes |
| **Complexity** | ~15KB | ~24KB | ~29KB |

The iOS path is the most sophisticated - it has to overcome the absence of JIT-based primitives by building R/W entirely through DOM object corruption. The async design, the retry loops, the heap grooming with garbage locales, the thread-list walk, the stack scanning - all of it reflects the harder exploitation environment on iOS compared to macOS.

---

## Post-Exploitation: From R/W to Shellcode

This is where Coruna gets interesting - and where Google's and iVerify's publications go quiet. Google described the post-WebKit-RCE chain as using "non-public exploitation techniques." iVerify didn't cover it at all. The JavaScript source reveals exactly what those techniques are.

The post-exploitation chain has four stages, each building on the last:

```
Arbitrary R/W Primitive (T.Dn.Pn)
    │
    ▼
Wasm call_indirect Dispatch Hijack (class ct → T.Dn.Wn)
    → Turns Wasm sandbox into native function call primitive
    │
    ▼
PAC Bypass via Unsigned GOT-Swap (classes ta, ha, ia, ca)
    → Apple's own frameworks authenticate attacker-supplied pointers
    │
    ▼
mach_vm_allocate RWX Pages (class oc/hc)
    → Executable memory from inside the WebContent sandbox
    │
    ▼
PACDB Rolling Hash Forgery (hc.kg())
    → Arbitrary shellcode passes kernel JIT verification
    │
    ▼
ARM64 shellcode execution - game over
```

### Stage 1: Wasm call_indirect Dispatch Hijack

**The problem:** You have arbitrary memory read/write, but you can't *call* anything. Memory corruption lets you read and write data, but invoking a native function requires control flow - and on ARM64e, every indirect branch is PAC-verified.

**Coruna's solution:** Build a 306-byte WebAssembly module inline in JavaScript, compile it, then hijack the JIT cage's dispatch pointer to redirect Wasm function calls to arbitrary addresses.

Class `ct` (stored globally as `T.Dn.Wn`) constructs the Wasm module from a `Uint8Array` with XOR-obfuscated bytes. The first four bytes decode to `\0asm` (the Wasm magic number). The module exports four items:

| Export | Type | Purpose |
|--------|------|---------|
| `"f"` | Function | Main entry - 16 `i32` params (= 8 register pairs) |
| `"o"` | Function | Internal shim - its compiled address is the hijack target |
| `"m"` | Memory | Shared buffer for capturing return values |
| `"t"` | Table | Internal `call_indirect` dispatch table |

After compilation, `ct` locates the JIT-compiled address of export `"o"` and reads the `_jitCagePtr` - the internal WebKit/JSC pointer that controls which JIT code page the Wasm dispatcher jumps to:

```javascript
this.hf = a.tA(this.if);           // Native address of compiled 'o'
this.Fh = { lf: s.sc(this.En.uc, 0x0n) };  // PAC-signed _jitCagePtr
```

The `call(target, args)` method then performs the swap:

```javascript
call(t, a) {
    // 1. Read current JIT cage pointer (save for restore)
    const h = s.Ci(c);

    // 2. Overwrite _jitCagePtr with attacker's target address
    i.call({ _h: this.Fh.lf, xh: S(t), x1: l });

    try {
        // 3. Call Wasm export f(16 i32 args) - dispatcher follows
        //    the swapped pointer to attacker's target function
        s.zi(c, n);
        this.sf(...this.rf);

        // 4. Read return value from Wasm memory
        return this.nf[0];
    } finally {
        // 5. Restore original JIT cage pointer
        s.zi(c, h);
    }
}
```

The 16 `i32` Wasm parameters map to 8 `BigInt64` values - matching ARM64's 8 general-purpose argument registers (`x0`-`x7`). Every subsequent native function call in the entire exploit chain flows through `ct.call()`.

### Stage 2: PAC Bypass via Unsigned GOT-Swap

This is the technique Google described as "non-public." It's also the most elegant part of the entire chain.

**The problem:** On ARM64e, every indirect branch instruction verifies a PAC signature. You can't just overwrite a function pointer and jump to it - the CPU will fault. Classic ROP/JOP is dead on modern Apple silicon.

**Coruna's solution:** Don't forge PAC signatures. Instead, temporarily swap **unsigned** GOT (Global Offset Table) entries in Apple's own frameworks, then trigger a legitimate PAC-authenticated call path that reads those GOT entries as data operands. The CPU verifies the code's control flow (all PAC checks pass - it's real signed code), but the *data* it operates on has been swapped.

This is a **confused-deputy attack** - Apple's own PAC-authenticated code becomes the deputy, unwittingly dispatching to attacker-controlled targets.

**The Class Hierarchy**

Four classes cooperate to make this work:

| Class | Role | Stored At |
|-------|------|-----------|
| `ta` | PAC engine core - gadget discovery, dispatch coordinator | `T.Dn.On` |
| `ha` | Authenticated call primitive - fake ObjC object construction | `T.Dn.Nn` |
| `ia` | GOT-swap dispatcher - the actual swap-trigger-restore sequence | internal |
| `ca` | `Intl.Segmenter` JIT trigger - forces execution through the swapped path | internal |

**How the GOT-Swap Works (Class `ia`)**

Class `ia` uses **seven anchor symbols** resolved from the dyld shared cache - GOT entries in `CoreGraphics`, `libxml2`, `ActionKit`, and other system frameworks. Two of these (`Yl` and `Wl`) are the swap targets. The `call()` method runs a four-phase sequence:

**Phase 1 - Build fake dispatch structures** in allocated memory: an entry point structure, a 768-byte fake vtable, nested fake objects carrying the target function pointer and PAC signature bits.

**Phase 2 - Swap the GOT entries:**

```javascript
const saved_Yl = a.Ci(this.En.Yl);  // save original GOT[Yl]
const saved_Wl = a.Ci(this.En.Wl);  // save original GOT[Wl]

a.zi(this.En.Yl, this.En.$l);   // GOT[Yl] = _HTTPConnectionFinalize
a.zi(this.En.Wl, this.En.Zl);   // GOT[Wl] = _dlfcn_globallookup
```

**Phase 3 - Trigger** via `Intl.Segmenter` JIT (class `ca`). The JIT-compiled code reads the swapped GOT entries, follows the chain of fake objects, and dispatches to the attacker's target - all through legitimate PAC-authenticated instruction sequences.

**Phase 4 - Restore and return:**

```javascript
} finally {
    a.zi(this.En.Yl, saved_Yl);  // restore original GOT[Yl]
    a.zi(this.En.Wl, saved_Wl);  // restore original GOT[Wl]
}
return a.Ci(this.Dh + 0x10n);    // read result from buffer
```

**Why This Bypasses PAC**

The key insight: GOT entries in the `__DATA` segment are **plain unsigned pointers**. Unlike `__AUTH_GOT` entries (which carry PAC signatures), regular GOT entries can be modified without authentication. But the code that *reads* those GOT entries is fully PAC-authenticated - every indirect branch in its execution passes hardware verification.

The CPU authenticates the *code's* control flow but cannot verify that the *data* it operates on is legitimate. The exploit never modifies code or signed pointers - it only changes unsigned data that signed code happens to read. And the `finally` block restores the original values immediately, minimizing the corruption window.

This is fundamentally different from ROP. There are no gadget chains, no stack pivots, no return address corruption. The attack surface is the semantic gap between PAC-protected control flow and unprotected data flow.

### Stage 3: Executable Memory via mach_vm_allocate

**The problem:** You can now call arbitrary native functions through the GOT-swap mechanism, but you're still executing *existing* code at known addresses. To run custom shellcode, you need writable-executable (RWX) memory - and Apple's WebContent sandbox restricts memory allocation.

**Coruna's solution:** Invoke the `mach_vm_allocate` Mach kernel trap directly from JavaScript, requesting pages with `VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE` permissions.

Class `hc` (extending `oc`) handles this. Its constructor resolves the kernel trap stubs from `libsystem_kernel.dylib`:

```javascript
this.ug = this.jn.wo('_mach_vm_allocate');
this.Kg = this.jn.Eo('_mach_msg_trap$...', '_mach_msg2_trap$...');
```

The `Eo()` fallback pattern handles ABI differences across macOS versions - the Mach message trap changed names between releases.

The `gg()` method provides two allocation paths based on capability flags:

**Path A - Direct:** Call `_mach_vm_allocate` through the Wasm trampoline, passing size and flags via the working buffer (`this.ig`), and read the allocated address from the result.

**Path B - Indirect:** When the direct path is unavailable, `Lg()` walks four levels of JSC internal pointers - `JSFunction → FunctionExecutable → JITCode → handler table → kernel trap entry` - to locate the trap handler, then invokes through that.

Both paths write parameters into a pinned 16KB `Uint32Array` buffer, invoke the kernel trap, and read the result back from the same buffer at a version-dependent offset. The allocated page comes back with RWX permissions - writable so the exploit can copy shellcode into it, executable so the shellcode can run.

But there's a catch: Apple's JIT cage requires that executable pages carry a **valid code integrity hash**. Simply writing ARM64 instructions to the page isn't enough - the kernel will refuse to execute them without a matching signature. That's where the final stage comes in.

### Stage 4: PACDB Rolling Hash Forgery

This is the crown jewel of the Coruna exploit chain - and the technique I haven't seen documented anywhere else. Not in Google's publication, not in iVerify's, not in any prior JIT cage escape writeup.

Apple's JIT cage doesn't just restrict *where* code can execute - it verifies *what* code executes. Before a JIT page is marked executable, the kernel computes a cryptographic hash of its contents using the hardware PAC instruction `PACDB`. The JIT compiler computes the same hash when it writes code. If they don't match, the page stays non-executable.

The Coruna developers reverse-engineered this hash algorithm from JavaScriptCore's source and reimplemented it in JavaScript.

**The Algorithm**

The `kg()` method on class `hc` returns a signing function. It selects one of three variants based on hardware capability flags - on modern ARM64e, it uses the PACDB path:

```javascript
const sign = (code, offset, dest) => {
    let hash = K._(offset);           // Seed from page offset

    for (let i = 0; i < code.length; i++) {
        const val = (code[i] ^ hash) >>> 0;   // XOR instruction with running hash

        // Use hardware PACDB as a keyed hash function:
        const h = lc.cc(sc(val), ctx1).et >>> 7;
        const t = lc.cc(sc(val), ctx2);

        // Combine via shift-and-XOR:
        hash = (h ^ (t.it >>> 23 | t.et << 9)) >>> 0;

        // Write hash to verification buffer
        ac.sr(dest + 4*i, hash);
    }
    return hash;
};
```

Each `lc.cc()` call invokes the actual hardware `PACDB` instruction through the GOT-swap mechanism. The algorithm has four critical properties:

1. **PAC as a MAC** - The exploit repurposes the hardware `PACDB` instruction (designed for pointer authentication) as a keyed message authentication code. Each instruction word gets "signed" using the processor's secret PAC key - the same key that protects function pointers.

2. **Rolling dependency** - Each instruction's hash depends on all previous hashes via the XOR chain. Changing any single instruction invalidates every subsequent hash value.

3. **Dual-context mixing** - Two different PAC context discriminators (`ctx1`, `ctx2`) are used per word, with results combined through bit shifts and XOR. This doubles the effective hash width.

4. **Offset-seeded** - The initial seed comes from the page offset, binding the signature to the code's memory location. The same shellcode at a different address produces a different hash chain.

**The Upload Pipeline**

With the signing function in hand, `Ig()` executes the complete code upload:

```
1. gg(size)      → mach_vm_allocate → RWX page at address P
2. PAC-sign P    → lc.oe(P, 0x47EAn) → authenticated destination pointer
3. Copy code     → rg(copyFunc, shellcode, len, offset, signedP)
4. kg()(code)    → rolling PACDB hash → hash chain written to buffer
5. Write hash    → ac.sr(hashDest, finalHash) → verification slot populated
6. Kernel check  → hash matches code → page marked executable
7. Execute       → jump to P → attacker-controlled ARM64 runs
```

The PAC-signed destination pointer (step 2) uses context discriminator `0x47EA` - ensuring the copy can't be redirected to a different page. The allocated pages are initialized with `0xCC` (`INT 3` - x86 software breakpoint) before shellcode is written, so any uninitialized bytes will trap rather than execute stale data. This is the same defensive pattern the legitimate JIT compiler uses.

**Why the Kernel Can't Tell the Difference**

The JIT cage verification was designed to ensure JIT-compiled code hasn't been tampered with between compilation and execution. The hash is computed by the JIT compiler (running in-process) and verified by the kernel before granting execute permission.

Coruna has everything needed to forge valid hashes:
- **The algorithm** - reverse-engineered from JavaScriptCore
- **The PAC keys** - hardware PAC keys are per-process, not per-privilege-level. Any code in the process can invoke `PACDB` with the same keys
- **The write primitive** - arbitrary memory writes place both shellcode and its hash in the correct locations

The kernel sees a JIT page with code and a matching hash computed using the correct PAC key. It has no way to distinguish this from a legitimate JIT compilation. The page is marked executable, and the exploit's ARM64 shellcode runs with full WebContent process privileges.

The chain is complete. From a JavaScript type confusion to arbitrary native code execution, through four escalation stages - each one building on the last, each one bypassing a different layer of Apple's defense-in-depth.

---

## Payloads and C2

Once shellcode is running, the final payload modules (`final_payload_A` and `final_payload_B`) handle post-exploitation. Both variants share identical logic - the difference is that Payload A uses a PAC-authenticated code pointer path while Payload B uses an unsigned fallback with additional runtime checks.

The shellcode is embedded as XOR-encoded `Uint32Array` dwords - 88 dwords in variant A, 27-44 in variant B. After decoding, the ARM64 instructions perform:

1. **Process information gathering** - reads the process ID, parent PID, and sandbox profile
2. **User-Agent and URL exfiltration** - captures `navigator.userAgent` and `document.URL` from the JavaScript context and writes them into the shellcode's data region
3. **C2 callback** - transmits collected data to `b27.icu` via XHR over an `ArrayBuffer`-based state machine

The C2 communication (`xA()`) uses a simple state machine that polls the `ArrayBuffer` for completion flags - the shellcode writes status codes to shared memory, and the JavaScript side reads them back to track progress. This avoids any DOM-visible network requests from the JavaScript layer; the actual HTTP request is made from native code.

Notably, the exploit **never drops a file to disk**. Everything - the JavaScript modules, the shellcode, the C2 data - exists only in memory. The entire chain from watering-hole landing to data exfiltration happens within the browser process.

---

## Stage 5: Kernel Exploitation (dump.bin)

Everything above happens inside the WebContent sandbox. The shellcode has arbitrary code execution in the renderer process, but it can't touch the kernel, can't access other apps' data, and can't persist across reboots. The C2 state machine solves this: once the browser-side chain calls home to `b27.icu`, the server sends back a second-stage binary - the kernel exploit.

Researcher **[matteyeux](https://github.com/matteyeux/coruna)** captured this binary in the wild. On an iPhone X running iOS 16.6, matteyeux identified the `powerd` system daemon behaving anomalously and used lldb to dump the injected DYLIB from the running process's memory. The result: `dump.bin` - a 2MB ARM64 dynamic library containing the kernel exploitation stage, captured mid-execution.

### The Binary

| Property | Value |
|----------|-------|
| **Format** | Mach-O 64-bit ARM64 DYLIB |
| **Size** | 2,097,152 bytes (2.00 MB) |
| **Single export** | `_driver` - 29,972 bytes, the monolithic exploit entry point |
| **Imports** | 265 symbols from IOKit, Mach/VM, CoreFoundation, CommonCrypto, libSystem |
| **Functions** | 649 total (median 180 bytes, 9 exceed 2KB) |
| **CVE** | CVE-2023-41974 - kernel use-after-free, added to CISA KEV 2025-01-29 |

This is **not** embedded in the JavaScript modules. It's fetched at runtime through the C2 channel:

```
Browser exploit achieves code execution
    → ArrayBuffer C2 channel established with b27.icu
    → DOWNLOAD command → server sends dump.bin
    → Binary injected into powerd daemon (long-lived, elevated privileges)
    → _driver() executes the kernel exploit
```

### IOSurfaceRoot: The Attack Surface

The exploit targets **IOSurfaceRoot** - the IOKit user client for GPU surface management. IOSurface has been a recurring iOS kernel attack surface (CVE-2023-32434 in Operation Triangulation used the same driver). The exploit:

1. **Opens a connection** - `IOServiceMatching("IOSurfaceRoot")` → `IOServiceOpen`
2. **Creates a surface** - with controlled `kIOSurfaceIsGlobal`, `kIOSurfaceWidth`, `kIOSurfaceHeight` properties to shape the kernel heap
3. **Triggers the vulnerability** - via `IOConnectCallMethod` / `IOConnectTrap6` - direct trap calls that bypass normal method dispatch

The `IOConnectTrap4` and `IOConnectTrap6` imports are a signature of IOKit exploitation - they hit the driver's `externalTrap` handler directly with precise argument control, enabling the timing and layout needed for reliable heap corruption.

### From Bug to Root

The `_driver` function - at 29,972 bytes, the largest of 649 functions by 2.6× - orchestrates a six-phase exploitation sequence:

**Phase 1: Environment fingerprinting.** Before triggering anything, the exploit checks for Corellium virtual devices (`/usr/libexec/corelliumd`), parses the kernel version (`xnu-%d.%d.%d~%d`), queries the SoC type (`T8020`/A12, `T8120`/A16), and reads `developer_mode_status`. If it's running on an analysis environment, it exits.

**Phase 2: Kernel memory primitives.** After triggering the IOSurface vulnerability, the exploit builds kernel read/write through `mach_vm_read_overwrite` and `mach_vm_write`. It scans kernel memory for 39 ARM64 instruction patterns (20 fixed-byte + 19 wildcard) - byte-level gadget signatures - to defeat KASLR and locate critical kernel structures without symbols.

**Phase 3: Privilege escalation.** With kernel R/W established, it manipulates Mach ports via `task_get_special_port` / `task_set_special_port` and invokes `host_security_set_task_token` - a highly privileged operation that sets the security token on a task. The exploit forges entitlements by patching `cs_blob` structures in kernel memory, injecting `task_for_pid-allow` - the ultimate privilege entitlement granting full control over any process.

**Phase 4: Sandbox and AMFI bypass.** The exploit interacts with the sandbox subsystem (`sandbox_check` with `SANDBOX_CHECK_NO_REPORT`) and patches Apple Mobile File Integrity (AMFI) in kernel memory. It uses `IOServiceSetAuthorizationID` - a private IOKit API - to impersonate other processes' entitlements when interacting with kernel drivers.

**Phase 5: Root filesystem remount.** A complete rootfs remount chain: identify the root partition (`/dev/disk0s1s1`), manipulate the APFS root snapshot (`orig-fs`), mount a writable copy at the OTA update path (`/private/var/MobileSoftwareUpdate/mnt1`), and create RAM disks for temporary storage. This achieves persistent write access on the normally read-only root volume.

**Phase 6: Post-exploitation setup.** The binary references high-value system daemons - `backboardd` (UI event dispatch), `SpringBoard` (home screen), `AppleSEPManager` (Secure Enclave) - as potential injection targets or monitoring points. It retrieves the device serial number (`IOPlatformSerialNumber`) and boot manifest hash for C2 fingerprinting.

The exploit is aware of Apple's Page Protection Layer (PPL) - it references the `__PPLTEXT` kernel segment, which is the hardware-enforced code integrity boundary introduced on A12+. On A11 and earlier (like the captured iPhone X), PPL doesn't exist; on A12+, the exploit must work around it.

The complete static analysis of `dump.bin` - all 265 imports categorized, function size distribution, ARM64 gadget patterns, entitlement XML blobs, and attack surface reconstruction - is available in the [standalone kernel exploit report](https://github.com/Rat5ak/CORUNA_TECHNICAL_ANALYSIS).

---

## Post-Exploitation: PlasmaLoader & PLASMAGRID

After kernel exploitation achieves root and persistence, the chain's final objective isn't surveillance - it's **theft**.

Google TIG and iVerify documented the post-kernel payload as **PlasmaLoader** (also tracked as **PLASMAGRID**) - a root-daemon stager that establishes persistent C2 and enables the operator's financial objectives. Key characteristics:

- **Root-level persistence** - PlasmaLoader installs as a system daemon, surviving reboots via the rootfs remount achieved by the kernel exploit
- **"lazarus"-seeded DGA** - When primary hardcoded C2 servers are unreachable, PlasmaLoader falls back to algorithmically generated domains: 15-character `.xyz` domains seeded with the string `"lazarus"`, validated against Google Public DNS before use
- **Cryptocurrency theft** - UNC6691's documented objective. The implant targets cryptocurrency wallet apps and exchange credentials on compromised devices
- **No DGA in earlier stages** - The DGA exists *only* in PlasmaLoader (Stage 3). The browser exploit delivery (Stage 0) uses static domains with CloudFront CDN fronting. The C2 channel (Stage 1) uses a hardcoded URL. The kernel exploit (Stage 2) is downloaded over the Stage 1 channel. This is a common misunderstanding - early speculation attributed DGA behavior to the entire chain, but it's confined to the post-exploitation implant

The "lazarus" seed string is notable but likely coincidental - it doesn't indicate a connection to the DPRK-attributed Lazarus Group. UNC6691 is assessed by Google as a Chinese financially-motivated actor, not a North Korean state operation.

## Version Coverage

The kit I recovered from `b27.icu` covers a specific subset of the full Coruna arsenal (which Google documented as 23 exploits across 5 chains). My subset targets:

| Component | Coverage |
|-----------|----------|
| **iOS versions** | 16.0 - 17.2 |
| **macOS** | Safari/WebKit on Apple Silicon |
| **WebKit RCE paths** | 3 (NaN-boxing, JIT optimization, Audio/SVG) |
| **Post-RCE chain** | Platform-independent after R/W primitive |
| **Version-adaptive offsets** | 42 JSC internal structure offsets, 3 version thresholds |
| **Payload variants** | 2 (A: PAC-authenticated, B: unsigned fallback) |

The version-adaptive offset table (`tt[]` with 42 entries and thresholds at WebKit builds 170000/170100/170200) is one of the clearest indicators of professional development. Someone had access to multiple WebKit builds and systematically mapped internal structure changes across releases. This isn't something you do in a weekend CTF.

---

## Attribution: UNC6691

Google's March 2026 report tracked Coruna through three operator generations:

| Period | Operator | Profile | Usage |
|--------|----------|---------|-------|
| Early 2025 | Commercial surveillance customer | Unknown | Targeted surveillance |
| Summer 2025 | **UNC6353** | Suspected Russian espionage | Compromised Ukrainian civil society websites via `cdn.uacounter[.]com` |
| Late 2025 - present | **UNC6691** | Chinese financially-motivated | Mass-deployed via gambling and crypto lure sites |

The kit I analyzed - recovered from `b27.icu` - belongs to the UNC6691 deployment. Google assessed that UNC6691 acquired the Coruna framework in December 2025, after it had "passed through several hands." Google documented multiple UNC6691 delivery domains:

- `b27.icu` (the instance I recovered)
- `h4k.icu`
- `7p.game`
- `spin7.icu`
- `k96.icu`
- `seven7.vip`
- Additional domains per GTIG reporting

All follow the same pattern: a fraudulent gambling site or fake cryptocurrency exchange (e.g., impersonating WEEX) serves as the visible lure page, while the Coruna exploit chain loads via hidden iFrame in the background. The user sees a gambling site. Their phone gets rooted.

UNC6691's objective is financial - specifically cryptocurrency theft. This represents the final stage of exploit proliferation: a toolkit built for intelligence purposes, repurposed for profit by actors who acquired it on the secondary market.

---

## Infrastructure: Still Live

On March 9, 2026, I verified the delivery infrastructure. **All 13 original Coruna exploit JavaScript payloads are still live on `b27.icu`** - served over HTTPS with `Content-Type: application/javascript`, byte-identical to the copies in matteyeux's public dump (SHA1 verified for each file).

A full iOS/macOS browser exploit chain is sitting on the open internet, actively served from a domain hosting a Chinese gambling site.

### Architecture

```
Visitor → b27.icu (DNS: CNAME → d35oc5m182mh0p.cloudfront.net)
    → AWS CloudFront CDN edge (SYD3-P2, HIO52, etc.)
    → Origin: nginx/1.18.0 (Ubuntu)
    → 7P.GAME gambling lure page (3,207 bytes)
    → Hidden iFrame loads exploit JS modules
```

- **CDN**: AWS CloudFront distribution, DNS via AWS Route53
- **Origin**: nginx/1.18.0 on Ubuntu, behind CloudFront
- **Current frontend**: 7P.GAME - a Chinese-language gambling site with TikTok pixel tracking, Vite-built SPA, iOS homescreen icon configuration. This is **not** an unrelated domain takeover - GTIG confirmed UNC6691 uses gambling lures as delivery vehicles
- **Payload delivery**: Cookie-based URL derivation - `sha256(COOKIE + ID)[:40]` generates the payload filename, matching the SHA1-hash filenames of the exploit modules

### Registration History

| Date | Event |
|------|-------|
| 2025-06-01 | Domain registered via Gname.com (Singapore). Registrant: **Hong Kong, China** |
| 2025-07-08 | DNS shows direct IP `15.152.32.229` (not yet CloudFront-fronted) |
| ~2025-12 | UNC6691 acquires Coruna framework (per GTIG) |
| 2026-03-06 | WHOIS updated - registrant country now shows **US** (operational cover change) |
| 2026-03-09 | Current: CloudFront-fronted, 9 unique IPs over lifetime, all 13 payloads still live |

The original registrant was in Hong Kong/China - consistent with UNC6691's documented Chinese origin. The registrar (Gname.com) and DNS provider (share-dns.com) remained the same throughout, with three distinct nameserver configurations (`a4/b4` → `a/b` → `a5/b5`), all within the same provider. Four WHOIS records in nine months indicates active domain management, not an abandoned domain.

The infrastructure evolved from direct IP hosting to CloudFront-fronted delivery - deliberate hardening over time. The exploit payloads persisted through all infrastructure changes, byte-identical to the originals.

I reported the live exploit chain to Apple PSIRT, Google TIG, and AWS abuse.

---

## What This Tells Us

A few observations from spending months inside this codebase:

**The engineering quality is exceptional - at every stage.** The browser chain has 12+ cooperating classes with clean separation of concerns. Lazy initialization. `finally` blocks for cleanup. Retry mechanisms. Fallback paths. Two independent WebKit RCE implementations for macOS alone. The kernel exploit mirrors this: 649 well-factored functions, anti-analysis detection, multi-SoC offset tables, and a rootfs remount chain that handles APFS snapshots, RAM disks, and entitlement forging. This isn't a proof-of-concept - it's a product, maintained across OS versions by a professional development team.

**The JavaScript-level sophistication is underappreciated.** Google and iVerify analyzed Coruna from network captures and binary forensics. The JavaScript source reveals a different dimension: the Mach-O parser reimplemented in JS, the ARM64 instruction pattern matcher, the compressed export trie walker, the inline Wasm module construction. These are systems-programming techniques implemented in a language designed for web pages.

**PAC is a speed bump, not a wall.** Coruna bypasses ARM64e pointer authentication without forging a single signature. The confused-deputy GOT-swap technique exploits the gap between PAC-protected control flow and unprotected data flow. Apple's own signed code becomes the attack vector. This is a design-level limitation that software updates alone can't fully address.

**The PACDB hash forgery is the real finding.** The rolling hash algorithm that signs JIT pages - reimplemented in JavaScript, using the hardware's own PAC keys - is something I haven't seen documented in any prior public research. It's the technique that makes the JIT cage escape possible, and it's the technique that's hardest to mitigate without architectural changes to how JIT code signing works.

**The kernel exploit is the standard - IOSurface again.** CVE-2023-41974 targets IOSurfaceRoot, the same driver family as Operation Triangulation's CVE-2023-32434. IOSurface remains one of the highest-value iOS kernel attack surfaces: userspace-accessible, complex, and historically difficult for Apple to harden without breaking GPU functionality. Its addition to CISA's Known Exploited Vulnerabilities catalog (January 29, 2025) came over a year after Apple's iOS 17 patch - a reminder of the gap between patch availability and confirmed exploitation.

**The proliferation story matters.** A toolkit built for US intelligence, stolen by an insider, sold to Russian brokers, deployed against Ukrainian civil society, and ending up on Chinese crypto scam sites hitting random iPhone users. Every stage of that journey was predictable, and every stage was preventable. The technical excellence of the exploit chain is inseparable from the policy failure that let it spread. UNC6691's acquisition of Coruna in December 2025 - repurposing a surveillance tool for cryptocurrency theft via gambling lure sites - is the end state of uncontrolled proliferation.

**The infrastructure is still live.** As of my last check, all 13 exploit payloads were still being served from `b27.icu`, byte-identical to the originals. A full-chain iOS exploit sitting on the open web, behind a CloudFront CDN, fronted by a gambling site. This underscores why disclosure matters - and why I've reported it to Apple, Google, and AWS.

---

## Resources

- **Full technical analysis (6,630 lines):** [GitHub](https://github.com/Rat5ak/CORUNA_TECHNICAL_ANALYSIS) - complete class taxonomy, algorithm reconstruction, code samples, and module dependency maps
- **Kernel exploit report (CVE-2023-41974):** [GitHub](https://github.com/Rat5ak/CORUNA_TECHNICAL_ANALYSIS) - standalone static analysis of dump.bin, all 265 imports categorized, attack surface reconstruction
- **Coruna exploit dump + artifacts:** [GitHub](https://github.com/Rat5ak/CORUNA_IOS-MACOS_FULL_DUMP) - samples, extracted Wasm/binaries, decoded payloads, analysis scripts
- **Original public dump (matteyeux):** [github.com/matteyeux/coruna](https://github.com/matteyeux/coruna) - where the Coruna JavaScript modules and kernel exploit binary first appeared publicly
- **Google TIG - "Coruna: A Powerful iOS Exploit Kit":** [cloud.google.com/blog](https://cloud.google.com/blog/topics/threat-intelligence/coruna-powerful-ios-exploit-kit/)
- **GTIG March 2026 - UNC6691 attribution:** [cloud.google.com/blog](https://cloud.google.com/blog/topics/threat-intelligence/) - Chinese financially-motivated actor profile, PlasmaLoader documentation
- **iVerify - Coruna detection and PlasmaLoader analysis:** [iverify.io/blog](https://iverify.io/blog)
- **CVE-2023-41974 (CISA KEV):** [NVD](https://nvd.nist.gov/vuln/detail/CVE-2023-41974) - kernel use-after-free in IOSurfaceRoot, added to KEV 2025-01-29
- **US Treasury - Operation Zero sanctions:** [treasury.gov](https://home.treasury.gov/news/press-releases/sb0404)

---
*Thanks to [matteyeux](https://github.com/matteyeux/coruna) for posting the Coruna exploit dump publicly - including the kernel binary that made this analysis possible.*
*I'm Nadsec - independent security researcher. Analysis performed on the publicly available Coruna JavaScript dump posted by [matteyeux](https://github.com/matteyeux/coruna).*

*Find me: [Twitter/X](https://x.com/Nadsec11) · [Bluesky](https://bsky.app/profile/nadsec.online) · [Mastodon](https://cyberplace.social/@Nadsec) · [Medium](https://medium.com/@Nadsec) · [GitHub](https://github.com/Rat5ak) ·*
