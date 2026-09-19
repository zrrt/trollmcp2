// Find jitCagePtr and jitOperationList in XOR-encoded form
const fs = require('fs');
const data = fs.readFileSync('final_payload_B_6241388a_inner.js', 'utf8');

// Find all XOR arrays and decode
const pattern = /\[([0-9, ]+)\]\.map\(x\s*=>\s*\{?\s*return\s+String\.fromCharCode\(x\s*\^\s*(\d+)\)\s*\}?\s*\)\.join\(\s*["']{2}\s*\)/g;
let m;
while ((m = pattern.exec(data)) !== null) {
    const nums = m[1].split(',').map(n => parseInt(n.trim()));
    const key = parseInt(m[2]);
    if (nums.length < 4) continue;
    const decoded = nums.map(x => String.fromCharCode(x ^ key)).join('');
    if (decoded.includes('jit') || decoded.includes('Jit') || decoded.includes('JIT') || 
        decoded.includes('Cage') || decoded.includes('cage') ||
        decoded.includes('Operation') || decoded.includes('operation') ||
        decoded.includes('_ZN3JSC') ||
        decoded.includes('Secure') || decoded.includes('Hash') || decoded.includes('Pin')) {
        console.log('key=' + key + ':', decoded);
    }
}

// Also check final_payload_A
const dataA = fs.readFileSync('final_payload_A_16434916_inner.js', 'utf8');
let m2;
const pattern2 = /\[([0-9, ]+)\]\.map\(x\s*=>\s*\{?\s*return\s+String\.fromCharCode\(x\s*\^\s*(\d+)\)\s*\}?\s*\)\.join\(\s*["']{2}\s*\)/g;
while ((m2 = pattern2.exec(dataA)) !== null) {
    const nums = m2[1].split(',').map(n => parseInt(n.trim()));
    const key = parseInt(m2[2]);
    if (nums.length < 4) continue;
    const decoded = nums.map(x => String.fromCharCode(x ^ key)).join('');
    if (decoded.includes('jit') || decoded.includes('Jit') || decoded.includes('JIT') ||
        decoded.includes('Cage') || decoded.includes('cage') ||
        decoded.includes('Operation') || decoded.includes('operation') ||
        decoded.includes('_ZN3JSC') || decoded.includes('_ZN3WTF') ||
        decoded.includes('Secure') || decoded.includes('Hash') || decoded.includes('Pin') ||
        decoded.includes('mach_vm') || decoded.includes('allocate')) {
        console.log('A key=' + key + ':', decoded);
    }
}

// Also check _wrapper_A.js
const dataW = fs.readFileSync('_wrapper_A.js', 'utf8');
let m3;
const pattern3 = /\[([0-9, ]+)\]\.map\(x\s*=>\s*\{?\s*return\s+String\.fromCharCode\(x\s*\^\s*(\d+)\)\s*\}?\s*\)\.join\(\s*["']{2}\s*\)/g;
while ((m3 = pattern3.exec(dataW)) !== null) {
    const nums = m3[1].split(',').map(n => parseInt(n.trim()));
    const key = parseInt(m3[2]);
    if (nums.length < 4) continue;
    const decoded = nums.map(x => String.fromCharCode(x ^ key)).join('');
    if (decoded.includes('jit') || decoded.includes('Jit') || decoded.includes('JIT') ||
        decoded.includes('Cage') || decoded.includes('cage') ||
        decoded.includes('Operation') || decoded.includes('operation') ||
        decoded.includes('_ZN3JSC') || decoded.includes('_ZN3WTF') ||
        decoded.includes('Secure') || decoded.includes('Hash') || decoded.includes('Pin') ||
        decoded.includes('mach_vm') || decoded.includes('allocate')) {
        console.log('W key=' + key + ':', decoded);
    }
}
