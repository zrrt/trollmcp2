const fs = require('fs');

const src = fs.readFileSync('final_payload_A_16434916.js','utf8');
const parts = src.split(/"[A-Za-z0-9+\/]{40,}[A-Za-z0-9+\/=]*"/);

// Write parts 2 and 3 (the actual JS code containing xA, yA, YA)
for (let i = 1; i < parts.length; i++) {
  const outFile = '_part' + i + '_A.js';
  fs.writeFileSync(outFile, parts[i]);
  console.log('Part', i, ':', parts[i].length, 'chars → written to', outFile);
}

// Now do the same for Payload B
const srcB = fs.readFileSync('final_payload_B_6241388a.js','utf8');
const partsB = srcB.split(/"[A-Za-z0-9+\/]{40,}[A-Za-z0-9+\/=]*"/);
for (let i = 1; i < partsB.length; i++) {
  const outFile = '_part' + i + '_B.js';
  fs.writeFileSync(outFile, partsB[i]);
  console.log('Part B', i, ':', partsB[i].length, 'chars → written to', outFile);
}

// Decode XOR strings in the wrapper code
function decodeXorStrings(code) {
  const re = /\[([\d, ]+)\]\.map\(x\s*=>\s*\{return String\.fromCharCode\(x\s*\^\s*(\d+)\);\}\)\.join\(""\)/g;
  let match;
  while ((match = re.exec(code)) !== null) {
    const nums = match[1].split(',').map(n => parseInt(n.trim()));
    const key = parseInt(match[2]);
    const decoded = nums.map(n => String.fromCharCode(n ^ key)).join('');
    console.log('  XOR ^' + key + ': ' + JSON.stringify(decoded));
  }
}

console.log('\n--- XOR strings in Part 1 A ---');
decodeXorStrings(parts[1]);
console.log('\n--- XOR strings in Part 2 A ---');
decodeXorStrings(parts[2]);
console.log('\n--- XOR strings in Part 3 A ---');
decodeXorStrings(parts[3]);
