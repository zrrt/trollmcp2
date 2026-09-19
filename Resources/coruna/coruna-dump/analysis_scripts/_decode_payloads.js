const fs = require('fs');

function fullyDecode(filename) {
  let src = fs.readFileSync(filename, 'utf8');
  
  for (let depth = 0; depth < 10; depth++) {
    const b64blocks = src.match(/"([A-Za-z0-9+/=]{50,})"/g);
    if (!b64blocks) break;
    
    let found = false;
    for (const block of b64blocks) {
      const b64 = block.slice(1, -1);
      try {
        const decoded = Buffer.from(b64, 'base64').toString('utf8');
        if (decoded.includes('function') || decoded.includes('class') || decoded.includes('const') || decoded.includes('let ')) {
          src = decoded;
          found = true;
          break;
        }
      } catch(e) {}
    }
    if (!found) break;
  }
  return src;
}

// Decode all XOR-encoded strings in the source
function decodeXorStrings(src) {
  const re = /\[([\d, ]+)\]\.map\(x\s*=>\s*\{return String\.fromCharCode\(x\s*\^\s*(\d+)\);\}\)\.join\(""\)/g;
  let match;
  const results = [];
  while ((match = re.exec(src)) !== null) {
    const nums = match[1].split(',').map(n => parseInt(n.trim()));
    const xorKey = parseInt(match[2]);
    const decoded = nums.map(n => String.fromCharCode(n ^ xorKey)).join('');
    results.push({ xorKey, decoded, position: match.index });
  }
  return results;
}

const files = [
  'final_payload_A_16434916.js',
  'final_payload_B_6241388a.js', 
  'final_payload_A_16434916_inner.js',
  'final_payload_B_6241388a_inner.js'
];

for (const file of files) {
  console.log('\n' + '='.repeat(80));
  console.log('FILE:', file);
  console.log('='.repeat(80));
  
  const decoded = fullyDecode(file);
  console.log('Decoded length:', decoded.length);
  
  // Write decoded version
  const outFile = '_decoded_' + file;
  fs.writeFileSync(outFile, decoded);
  console.log('Written to:', outFile);
  
  // Show XOR strings
  const xorStrings = decodeXorStrings(decoded);
  console.log('\nXOR-encoded strings found:', xorStrings.length);
  for (const s of xorStrings) {
    console.log('  XOR ^' + s.xorKey + ':', JSON.stringify(s.decoded));
  }
  
  // Show structure overview
  console.log('\nStructure overview (first 2000 chars):');
  console.log(decoded.substring(0, 2000));
  console.log('\n...\n');
  console.log('Last 1000 chars:');
  console.log(decoded.substring(decoded.length - 1000));
}
