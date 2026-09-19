const fs = require('fs');

// Manual Wasm disassembler for small modules
function disassembleWasm(filename) {
  const buf = fs.readFileSync(filename);
  const bytes = new Uint8Array(buf);
  
  console.log('\n=== ' + filename + ' (' + bytes.length + ' bytes) ===');
  console.log('Magic:', Array.from(bytes.slice(0, 4)).map(b => '0x' + b.toString(16)).join(' '));
  console.log('Version:', Array.from(bytes.slice(4, 8)).join('.'));
  
  let offset = 8;
  const sectionNames = ['Custom','Type','Import','Function','Table','Memory','Global','Export','Start','Element','Code','Data','DataCount'];
  
  while (offset < bytes.length) {
    const sectionId = bytes[offset++];
    let size = 0, shift = 0, b;
    do {
      b = bytes[offset++];
      size |= (b & 0x7f) << shift;
      shift += 7;
    } while (b & 0x80);
    
    const sectionStart = offset;
    const name = sectionNames[sectionId] || 'Unknown(' + sectionId + ')';
    console.log('\nSection ' + sectionId + ' (' + name + '): ' + size + ' bytes');
    
    if (sectionId === 1) { // Type section
      const count = readLEB(bytes, offset);
      console.log('  Types: ' + count.value);
      let off = count.next;
      for (let i = 0; i < count.value; i++) {
        const form = bytes[off++]; // 0x60 = func
        const paramCount = readLEB(bytes, off);
        off = paramCount.next;
        const params = [];
        for (let j = 0; j < paramCount.value; j++) {
          params.push(valtype(bytes[off++]));
        }
        const resultCount = readLEB(bytes, off);
        off = resultCount.next;
        const results = [];
        for (let j = 0; j < resultCount.value; j++) {
          results.push(valtype(bytes[off++]));
        }
        console.log('  Type ' + i + ': (' + params.join(', ') + ') -> (' + results.join(', ') + ')');
      }
    }
    
    if (sectionId === 7) { // Export section
      const count = readLEB(bytes, offset);
      console.log('  Exports: ' + count.value);
      let off = count.next;
      for (let i = 0; i < count.value; i++) {
        const nameLen = readLEB(bytes, off);
        off = nameLen.next;
        const ename = Buffer.from(bytes.slice(off, off + nameLen.value)).toString('utf8');
        off += nameLen.value;
        const kind = bytes[off++]; // 0=func, 1=table, 2=mem, 3=global
        const kindNames = ['func', 'table', 'memory', 'global'];
        const idx = readLEB(bytes, off);
        off = idx.next;
        console.log('  Export "' + ename + '": ' + (kindNames[kind] || 'unknown') + ' ' + idx.value);
      }
    }
    
    if (sectionId === 6) { // Global section
      const count = readLEB(bytes, offset);
      console.log('  Globals: ' + count.value);
    }
    
    if (sectionId === 5) { // Memory section
      const count = readLEB(bytes, offset);
      console.log('  Memories: ' + count.value);
    }
    
    if (sectionId === 10) { // Code section
      const count = readLEB(bytes, offset);
      console.log('  Functions: ' + count.value);
      let off = count.next;
      for (let i = 0; i < count.value; i++) {
        const bodySize = readLEB(bytes, off);
        off = bodySize.next;
        console.log('  Function ' + i + ': ' + bodySize.value + ' bytes');
        // Show raw bytes of function body
        const bodyBytes = Array.from(bytes.slice(off, off + Math.min(bodySize.value, 40))).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ');
        console.log('    Body: ' + bodyBytes);
        off += bodySize.value;
      }
    }
    
    offset = sectionStart + size;
  }
}

function readLEB(bytes, offset) {
  let result = 0, shift = 0, b;
  const start = offset;
  do {
    b = bytes[offset++];
    result |= (b & 0x7f) << shift;
    shift += 7;
  } while (b & 0x80);
  return { value: result, next: offset };
}

function valtype(b) {
  switch (b) {
    case 0x7f: return 'i32';
    case 0x7e: return 'i64';
    case 0x7d: return 'f32';
    case 0x7c: return 'f64';
    case 0x70: return 'funcref';
    default: return '0x' + b.toString(16);
  }
}

const files = [
  '_wasm_from_yAerzw_d6cb72f5.wasm',
  '_wasm_from_9e7e6ec78463c5e6bdee39e9f3f33d6fa296ea72.wasm',
  '_wasm_from_d9a260b1c2f63ab5e5aac4261d8a0be5a8b64da0.wasm',
];

for (const f of files) {
  try {
    disassembleWasm(f);
  } catch(e) {
    console.log('Error processing ' + f + ': ' + e.message);
  }
}
