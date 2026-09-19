const fs = require('fs');

// Decode the outer payload wrapper JS code
const src = fs.readFileSync('final_payload_A_16434916.js', 'utf8');

// The file is: let r={};globalThis.vKTo89.tI4mjA(hash, "base64_body")
// Extract the first large base64 body (the JS module code)
const allB64 = [];
const re = /"([A-Za-z0-9+/]{40,}[A-Za-z0-9+/=]*)"/g;
let m;
while ((m = re.exec(src)) !== null) {
  allB64.push({ b64: m[1], len: m[1].length });
}

console.log('Base64 blocks in outer file:', allB64.map((b,i) => 'Block ' + i + ': ' + b.len + ' chars').join('\n'));

// The first block is the tI4mjA body - decode it to get the wrapper JS
const wrapperJS = Buffer.from(allB64[0].b64, 'base64').toString('utf8');
console.log('\n--- Wrapper JS (layer 1) length:', wrapperJS.length, '---');

// This wrapper JS itself contains the inner module as a tI4mjA call plus the main code
// Write it out for inspection
fs.writeFileSync('_wrapper_A.js', wrapperJS);

// Find all class definitions
const classes = wrapperJS.match(/class\s+\w+(\s+extends\s+\w+)?/g);
console.log('\nClasses:', classes);

// Find all function definitions
const funcs = wrapperJS.match(/function\s+\w+/g);
console.log('Functions:', funcs);

// Find method names
const methods = wrapperJS.match(/\w+\s*\([^)]*\)\s*\{/g);
console.log('\nMethod-like patterns (first 30):');
if (methods) methods.slice(0, 30).forEach(m => console.log(' ', m));

// Look for YA, xA, yA specifically
console.log('\n--- Searching for YA, xA, yA ---');
const yaMatch = wrapperJS.match(/class\s+YA[\s\S]{0,500}/);
if (yaMatch) console.log('class YA:', yaMatch[0].substring(0, 300));

const xaMatch = wrapperJS.match(/function\s+xA[\s\S]{0,500}/);
if (xaMatch) console.log('\nfunction xA:', xaMatch[0].substring(0, 300));

const yaFuncMatch = wrapperJS.match(/function\s+yA[\s\S]{0,500}/);
if (yaFuncMatch) console.log('\nfunction yA:', yaFuncMatch[0].substring(0, 300));

// Look for SharedArrayBuffer
if (wrapperJS.includes('SharedArrayBuffer')) console.log('\nContains SharedArrayBuffer');
if (wrapperJS.includes('XMLHttpRequest') || wrapperJS.includes('XHR')) console.log('Contains XMLHttpRequest');
if (wrapperJS.includes('Atomics')) console.log('Contains Atomics');
if (wrapperJS.includes('Uint32Array')) console.log('Contains Uint32Array');

// Show all XOR-decoded strings in the wrapper
const xorRe = /\[([\d, ]+)\]\.map\(x\s*=>\s*\{return String\.fromCharCode\(x\s*\^\s*(\d+)\);\}\)\.join\(""\)/g;
let xm;
console.log('\n--- XOR strings in wrapper ---');
while ((xm = xorRe.exec(wrapperJS)) !== null) {
  const nums = xm[1].split(',').map(n => parseInt(n.trim()));
  const key = parseInt(xm[2]);
  const decoded = nums.map(n => String.fromCharCode(n ^ key)).join('');
  console.log('  ^' + key + ':', JSON.stringify(decoded));
}
