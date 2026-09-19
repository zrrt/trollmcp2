const fs = require('fs');
const data = fs.readFileSync('final_payload_B_6241388a_inner.js', 'utf8');

// Find all XOR-encoded string patterns
const pattern = /\[([0-9, ]+)\]\.map\(x\s*=>\s*\{?\s*return\s+String\.fromCharCode\(x\s*\^\s*(\d+)\)\s*\}?\s*\)\.join\(\s*["']{2}\s*\)/g;
let match;
const seen = new Set();
while ((match = pattern.exec(data)) !== null) {
    const nums = match[1].split(',').map(n => parseInt(n.trim()));
    const key = parseInt(match[2]);
    const decoded = nums.map(x => String.fromCharCode(x ^ key)).join('');
    if (decoded.length > 3 && !seen.has(decoded)) {
        seen.add(decoded);
        console.log('XOR key=' + key + ':', decoded);
    }
}
