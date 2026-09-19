const fs = require('fs');
function readLEB(bytes, offset) {
  let result = 0, shift = 0, b;
  do { b = bytes[offset++]; result |= (b & 0x7f) << shift; shift += 7; } while (b & 0x80);
  return { value: result, next: offset };
}
function valtype(b) {
  const m = {0x7f:'i32',0x7e:'i64',0x7d:'f32',0x7c:'f64',0x70:'funcref'};
  return m[b] || '0x'+b.toString(16);
}
const buf = fs.readFileSync('_wasm_from_KRfmo6_166411bd.wasm');
const bytes = new Uint8Array(buf);
console.log('165-byte module (' + bytes.length + ' bytes)');
let offset = 8;
const sn = ['Custom','Type','Import','Function','Table','Memory','Global','Export','Start','Element','Code'];
while (offset < bytes.length) {
  const sid = bytes[offset++];
  let sz = readLEB(bytes, offset); offset = sz.next;
  const ss = offset;
  console.log('Section', sid, '(' + (sn[sid]||'?') + '):', sz.value, 'bytes');
  if (sid === 1) {
    const c = readLEB(bytes, offset); let o = c.next;
    for (let i = 0; i < c.value; i++) { o++; const p = readLEB(bytes, o); o = p.next; const pr = []; for (let j = 0; j < p.value; j++) pr.push(valtype(bytes[o++])); const r = readLEB(bytes, o); o = r.next; const rr = []; for (let j = 0; j < r.value; j++) rr.push(valtype(bytes[o++])); console.log('  Type', i + ':', '(' + pr.join(',') + ') -> (' + rr.join(',') + ')'); }
  }
  if (sid === 7) {
    const c = readLEB(bytes, offset); let o = c.next;
    for (let i = 0; i < c.value; i++) { const nl = readLEB(bytes, o); o = nl.next; const nm = Buffer.from(bytes.slice(o, o+nl.value)).toString(); o += nl.value; const k = bytes[o++]; const idx = readLEB(bytes, o); o = idx.next; console.log('  Export', JSON.stringify(nm), ':', ['func','table','mem','global'][k], idx.value); }
  }
  if (sid === 10) {
    const c = readLEB(bytes, offset); let o = c.next;
    for (let i = 0; i < c.value; i++) { const bs = readLEB(bytes, o); o = bs.next; console.log('  Func', i, ':', bs.value, 'bytes'); o += bs.value; }
  }
  offset = ss + sz.value;
}
