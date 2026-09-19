const fs = require('fs');

function decodeAllLayers(filename) {
  const src = fs.readFileSync(filename, 'utf8');
  console.log('\n' + '='.repeat(80));
  console.log('FILE:', filename, '(' + src.length + ' bytes)');
  console.log('='.repeat(80));
  
  // Find all base64 blocks
  const b64re = /"([A-Za-z0-9+/]{40,}[A-Za-z0-9+/=]*)"/g;
  let match;
  const blocks = [];
  while ((match = b64re.exec(src)) !== null) {
    blocks.push({ b64: match[1], pos: match.index, len: match[1].length });
  }
  
  console.log('Found', blocks.length, 'base64 blocks');
  
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i];
    try {
      const decoded = Buffer.from(b.b64, 'base64').toString('utf8');
      console.log('\n--- Block', i, '(b64 len:', b.len, '→ decoded:', decoded.length, 'chars) ---');
      
      // Check if this has sub-blocks
      const subB64 = decoded.match(/"([A-Za-z0-9+/]{40,}[A-Za-z0-9+/=]*)"/g);
      if (subB64) {
        console.log('  Contains', subB64.length, 'sub-blocks');
        // Recursively decode sub-blocks
        for (let j = 0; j < subB64.length; j++) {
          const subDecoded = Buffer.from(subB64[j].slice(1,-1), 'base64').toString('utf8');
          console.log('  Sub-block', j, '(decoded:', subDecoded.length, 'chars)');
          
          // Check for deeper nesting
          const deepB64 = subDecoded.match(/"([A-Za-z0-9+/]{40,}[A-Za-z0-9+/=]*)"/g);
          if (deepB64) {
            console.log('    Contains', deepB64.length, 'deep sub-blocks');
            for (let k = 0; k < deepB64.length; k++) {
              const deepDecoded = Buffer.from(deepB64[k].slice(1,-1), 'base64').toString('utf8');
              console.log('    Deep block', k, '(decoded:', deepDecoded.length, 'chars)');
              
              // Write out the deepest decoded content
              const outFile = '_deep_' + filename.replace('.js','') + '_b' + i + '_s' + j + '_d' + k + '.js';
              fs.writeFileSync(outFile, deepDecoded);
              console.log('    Written to:', outFile);
              
              // Show overview
              console.log('    First 500 chars:', deepDecoded.substring(0, 500));
              
              // Check for class/function names
              const classNames = deepDecoded.match(/class\s+\w+/g);
              if (classNames) console.log('    Classes:', classNames.join(', '));
              const funcNames = deepDecoded.match(/function\s+\w+/g);
              if (funcNames) console.log('    Functions:', funcNames.join(', '));
            }
          } else {
            // This is the final content
            const outFile = '_layer_' + filename.replace('.js','') + '_b' + i + '_s' + j + '.js';
            fs.writeFileSync(outFile, subDecoded);
            console.log('  Written to:', outFile);
            console.log('  First 500 chars:', subDecoded.substring(0, 500));
            
            const classNames = subDecoded.match(/class\s+\w+/g);
            if (classNames) console.log('  Classes:', classNames.join(', '));
            const funcNames = subDecoded.match(/function\s+\w+/g);
            if (funcNames) console.log('  Functions:', funcNames.join(', '));
          }
        }
      } else {
        // Terminal decoded content
        console.log('  First 300 chars:', decoded.substring(0, 300));
        const classNames = decoded.match(/class\s+\w+/g);
        if (classNames) console.log('  Classes:', classNames.join(', '));
        const funcNames = decoded.match(/function\s+\w+/g);
        if (funcNames) console.log('  Functions:', funcNames.join(', '));
      }
    } catch(e) {
      console.log('Block', i, ': decode error');
    }
  }
}

const files = [
  'final_payload_A_16434916.js',
  'final_payload_A_16434916_inner.js',
];

for (const f of files) {
  decodeAllLayers(f);
}
