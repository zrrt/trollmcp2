const fs = require('fs');
const data = fs.readFileSync('final_payload_B_6241388a_inner.js', 'utf8');

// The file is structured as: outer JS that base64-decodes and evals inner content
// Extract the base64 string
const b64match = data.match(/"(bGV0[A-Za-z0-9+/=]+)"/);
if (b64match) {
    const decoded = Buffer.from(b64match[1], 'base64').toString('utf8');
    fs.writeFileSync('_decoded_B.js', decoded);
    console.log('Decoded', decoded.length, 'bytes to _decoded_B.js');
} else {
    console.log('No base64 match found, trying alternate extraction...');
    // Try to find any large base64 blob
    const matches = data.match(/[A-Za-z0-9+/=]{100,}/g);
    if (matches) {
        for (let i = 0; i < matches.length; i++) {
            try {
                const dec = Buffer.from(matches[i], 'base64').toString('utf8');
                if (dec.includes('class') || dec.includes('function')) {
                    fs.writeFileSync('_decoded_B.js', dec);
                    console.log('Decoded match', i, ':', dec.length, 'bytes');
                    break;
                }
            } catch(e) {}
        }
    }
}
