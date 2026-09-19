// Decode ALL XOR-encoded strings (not just long ones) from payload B
const fs = require('fs');
const data = fs.readFileSync('final_payload_B_6241388a_inner.js', 'utf8');

const pattern = /\[([0-9, ]+)\]\.map\(x\s*=>\s*\{?\s*return\s+String\.fromCharCode\(x\s*\^\s*(\d+)\)\s*\}?\s*\)\.join\(\s*["']{2}\s*\)/g;
let m;
const results = [];
while ((m = pattern.exec(data)) !== null) {
    const nums = m[1].split(',').map(n => parseInt(n.trim()));
    const key = parseInt(m[2]);
    const decoded = nums.map(x => String.fromCharCode(x ^ key)).join('');
    results.push({key, decoded, pos: m.index, len: decoded.length});
}
console.log("Total XOR-encoded strings found:", results.length);
console.log("\nAll decoded strings:");
results.forEach((r, i) => {
    console.log(`  ${i}: key=${r.key} len=${r.len}: "${r.decoded}"`);
});

// Also check CORUNA_TECHNICAL_ANALYSIS.md for references to these symbols
// to cross-reference the analysis
