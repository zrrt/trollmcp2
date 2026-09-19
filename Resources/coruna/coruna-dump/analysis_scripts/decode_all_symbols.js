// Decode all XOR-encoded symbols from the JIT cage escape source files
console.log("=== CLASS hc SYMBOLS (from final_payload_B_6241388a_inner.js) ===\n");

// hc constructor - try block: this.ug = this.jn.wo(...)
const s1 = [50, 55, 35, 94, 58, 57, 43, 92, 94, 32, 8, 25, 12, 44, 1, 1, 2, 14, 12, 25, 2, 31, 85, 12, 1, 1, 2, 14, 12, 25, 8, 40, 0, 61, 27].map(x => String.fromCharCode(x ^ 109)).join('');
console.log("hc.ug (try, via wo):", s1);

// hc constructor - catch block: this.ug = this.jn.wo(...)
const s2 = [62, 59, 47, 82, 54, 53, 39, 80, 82, 44, 4, 21, 0, 32, 13, 13, 14, 2, 0, 21, 14, 19, 89, 0, 13, 13, 14, 2, 0, 21, 4, 36, 51, 42, 47, 50, 62, 87, 45, 14, 2, 10, 4, 19, 40, 47, 50, 62, 85, 45, 14, 2, 10, 36, 36, 36, 12].map(x => String.fromCharCode(x ^ 97)).join('');
console.log("hc.ug (catch, via wo):", s2);

// hc constructor - this.Kg = this.jn.Eo(..., ...)
// First argument:
const s3a = [12, 9, 29, 96, 25, 0, 16, 98, 99, 31, 58, 61, 56, 17, 38, 53, 53, 54, 33, 107, 63, 58, 61, 56, 16, 60, 55, 54, 22, 1, 29, 0, 12, 98, 103, 30, 50, 48, 33, 60, 18, 32, 32, 54, 62, 49, 63, 54, 33, 22, 3, 37, 29, 0, 12, 97, 99, 25, 26, 7, 16, 60, 62, 35, 58, 63, 50, 39, 58, 60, 61, 22, 53, 53, 60, 33, 39, 22].map(x => String.fromCharCode(x ^ 83)).join('');
console.log("hc.Kg Eo arg1:", s3a);

// Second argument:
const s3b = [21, 16, 4, 121, 0, 25, 9, 123, 122, 6, 35, 36, 33, 8, 63, 44, 44, 47, 56, 114, 38, 35, 36, 33, 9, 37, 46, 47, 15, 24, 4, 25, 21, 123, 126, 7, 43, 41, 56, 37, 11, 57, 57, 47, 39, 40, 38, 47, 56, 15, 4, 25, 21, 120, 122, 0, 3, 30, 9, 37, 39, 58, 35, 38, 43, 62, 35, 37, 36, 15, 44, 44, 37, 56, 62, 15].map(x => String.fromCharCode(x ^ 74)).join('');
console.log("hc.Kg Eo arg2:", s3b);

// hc constructor - this.Cg = this.jn.Eo(...)
const s4 = [15, 10, 30, 99, 26, 3, 19, 98, 98, 21, 40, 53, 51, 37, 36, 49, 50, 60, 53, 29, 53, 61, 63, 34, 41, 24, 49, 62, 52, 60, 53, 97, 96, 51, 34, 53, 49, 36, 53, 25, 61, 32, 60, 21, 61].map(x => String.fromCharCode(x ^ 80)).join('');
console.log("hc.Cg Eo arg:", s4);

// Check for jitCagePtr - try block symbol
const s5 = [19, 22, 2, 127, 6, 31, 15, 126, 124, 31, 41, 47, 57, 62, 41, 13, 30, 1, 122, 120, 9, 4, 45, 63, 36, 28, 37, 34, 63, 126, 123, 45, 32, 32, 35, 47, 45, 56, 41, 28, 37, 34, 10, 35, 62, 15, 57, 62, 62, 41, 34, 56, 24, 36, 62, 41, 45, 40, 9, 58].map(x => String.fromCharCode(x ^ 76)).join('');
console.log("jitCagePtr/similar symbol:", s5);

// Decode the runtime flag property names
console.log("\n=== RUNTIME FLAGS ===\n");
// CqGuvK appears in: Dn.Hn.CqGuvK
console.log("CqGuvK - appears directly in source as property name");
// AfvDJM appears in: Dn.Hn.AfvDJM  
console.log("AfvDJM - appears directly in source as property name");
// kUAR3K appears in: Dn.Hn.kUAR3K
console.log("kUAR3K - appears directly in source as property name");
// tfe3OF appears in: Dn.Hn.tfe3OF
console.log("tfe3OF - appears directly in source as property name");

console.log("\n=== CLASS ni SYMBOLS (from final_payload_A_16434916_inner.js) ===\n");

// ni constructor XOR-encoded symbol  
const fs = require('fs');
const dataA = fs.readFileSync('final_payload_A_16434916_inner.js', 'utf8');

// Find all XOR patterns in final_payload_A
const pattern = /\[([0-9, ]+)\]\.map\(x\s*=>\s*\{?\s*return\s+String\.fromCharCode\(x\s*\^\s*(\d+)\)\s*\}?\s*\)\.join\(\s*["']{2}\s*\)/g;
let m;
const seen = new Set();
while ((m = pattern.exec(dataA)) !== null) {
    const nums = m[1].split(',').map(n => parseInt(n.trim()));
    const key = parseInt(m[2]);
    if (nums.length < 4) continue;
    const decoded = nums.map(x => String.fromCharCode(x ^ key)).join('');
    if (!seen.has(decoded)) {
        seen.add(decoded);
        if (decoded.match(/[A-Z_]/) && decoded.length > 5) {
            console.log('XOR key=' + key + ' (len=' + decoded.length + '):', decoded);
        }
    }
}
