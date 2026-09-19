const fs = require('fs');

// Extract Wasm modules from the exploit files 
// Pattern: Uint8Array([0,97,(XOR_EXPR),...])
// 0x00 0x61 0x73 0x6d = \0asm = Wasm magic

const files = [
  'yAerzw_d6cb72f5.js',
  'KRfmo6_166411bd.js', 
  'b903659316e881e624062869c4cf4066d7886c28.js.js',
  '9e7e6ec78463c5e6bdee39e9f3f33d6fa296ea72.js.js',
  '7994d095b1a601253c206c45c120a80c4c0f3736.js.js',
  'd9a260b1c2f63ab5e5aac4261d8a0be5a8b64da0.js.js'
];

for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  
  // Find WebAssembly.Module construction context
  const wasmIdx = src.indexOf('WebAssembly.Module');
  if (wasmIdx === -1) continue;
  
  console.log('\n=== ' + f + ' ===');
  console.log('WebAssembly.Module at char offset:', wasmIdx);
  console.log('Context (200 chars):', src.substring(wasmIdx - 100, wasmIdx + 100));
  
  // Find Uint8Array([0,97,...]) patterns - these are Wasm binaries
  // They use XOR obfuscation like (1448504664 ^ 1448504619)
  const re = /Uint8Array\(\[([^\]]+)\]\)/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    const content = m[1];
    if (content.startsWith('0,97,')) {
      console.log('\nWasm binary found at offset', m.index);
      console.log('Raw content (first 200 chars):', content.substring(0, 200));
      
      // Evaluate the XOR expressions
      try {
        const bytes = eval('[' + content + ']');
        console.log('Evaluated to', bytes.length, 'bytes');
        console.log('Magic:', bytes.slice(0, 4));
        console.log('Version:', bytes.slice(4, 8));
        
        const outFile = '_wasm_from_' + f.replace(/\.js\.js$/, '').replace('.js', '') + '.wasm';
        fs.writeFileSync(outFile, Buffer.from(bytes));
        console.log('Written to:', outFile);
        
        // Parse Wasm sections
        let offset = 8;
        while (offset < bytes.length) {
          const sectionId = bytes[offset];
          offset++;
          // Read LEB128 size
          let size = 0, shift = 0, b;
          do {
            b = bytes[offset++];
            size |= (b & 0x7f) << shift;
            shift += 7;
          } while (b & 0x80);
          
          const sectionNames = ['Custom','Type','Import','Function','Table','Memory','Global','Export','Start','Element','Code','Data','DataCount'];
          console.log('  Section', sectionId, '(' + (sectionNames[sectionId] || 'Unknown') + '):', size, 'bytes');
          offset += size;
        }
      } catch(e) {
        console.log('Eval error:', e.message);
      }
    }
  }
}
