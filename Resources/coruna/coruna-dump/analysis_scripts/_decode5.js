const fs = require('fs');

// Decode XOR strings from part3 (the SA() method)  
function decodeXor(nums, key) {
  return nums.map(n => String.fromCharCode(n ^ key)).join('');
}

console.log('=== Key decoded strings from SA() method ===');
console.log('__TEXT:', decodeXor([13, 13, 6, 23, 10, 6], 82));
console.log('__text:', decodeXor([103, 103, 76, 93, 64, 76], 56));
console.log('_ZN3JSC16jitOperationListE:', decodeXor([30, 27, 15, 114, 11, 18, 2, 112, 119, 43, 40, 53, 14, 49, 36, 51, 32, 53, 40, 46, 47, 13, 40, 50, 53, 4], 65));

// Framework paths with version checks
console.log('\n=== Framework paths by iOS version ===');
console.log('dn >= (1417309523 ^ 1417213223) =', 1417309523 ^ 1417213223, ':');
console.log('  ', decodeXor([68, 56, 18, 24, 31, 14, 6, 68, 39, 2, 9, 25, 10, 25, 18, 68, 59, 25, 2, 29, 10, 31, 14, 45, 25, 10, 6, 14, 28, 4, 25, 0, 24, 68, 35, 4, 6, 14, 56, 3, 10, 25, 2, 5, 12, 69, 13, 25, 10, 6, 14, 28, 4, 25, 0, 68, 35, 4, 6, 14, 56, 3, 10, 25, 2, 5, 12], 107));
console.log('  offset =', 1701528182 ^ 1701551638);

console.log('dn >= (910569574 ^ 910469238) =', 910569574 ^ 910469238, ':');
console.log('  ', decodeXor([117, 9, 35, 41, 46, 63, 55, 117, 22, 51, 56, 40, 59, 40, 35, 117, 28, 40, 59, 55, 63, 45, 53, 40, 49, 41, 117, 25, 53, 40, 63, 23, 22, 116, 60, 40, 59, 55, 63, 45, 53, 40, 49, 117, 25, 53, 40, 63, 23, 22], 90));

console.log('dn >= (1433166135 ^ 1433277351) =', 1433166135 ^ 1433277351, ':');
console.log('  ', decodeXor([71, 59, 17, 27, 28, 13, 5, 71, 36, 1, 10, 26, 9, 26, 17, 71, 46, 26, 9, 5, 13, 31, 7, 26, 3, 27, 71, 43, 7, 26, 13, 37, 36, 70, 14, 26, 9, 5, 13, 31, 7, 26, 3, 71, 43, 7, 26, 13, 37, 36], 104));

console.log('dn >= (1902736235 ^ 1902838379) =', 1902736235 ^ 1902838379, ':');
console.log('  ', decodeXor([31, 99, 73, 67, 68, 85, 93, 31, 124, 89, 82, 66, 81, 66, 73, 31, 96, 66, 89, 70, 81, 68, 85, 118, 66, 81, 93, 85, 71, 95, 66, 91, 67, 31, 120, 95, 93, 85, 99, 88, 81, 66, 89, 94, 87, 30, 86, 66, 81, 93, 85, 71, 95, 66, 91, 31, 120, 95, 93, 85, 99, 88, 81, 66, 89, 94, 87], 48));

console.log('fallback:');
console.log('  ', decodeXor([73, 53, 31, 21, 18, 3, 11, 73, 42, 15, 4, 20, 7, 20, 31, 73, 32, 20, 7, 11, 3, 17, 9, 20, 13, 21, 73, 43, 3, 2, 15, 7, 50, 9, 9, 10, 4, 9, 30, 72, 0, 20, 7, 11, 3, 17, 9, 20, 13, 73, 43, 3, 2, 15, 7, 50, 9, 9, 10, 4, 9, 30], 102));

// Second set of framework paths (for S gadget)
console.log('\n=== Second framework set (S gadget) ===');
console.log('dn >= (1178168121 ^ 1178334029) =', 1178168121 ^ 1178334029, ':');
console.log('  ', decodeXor([122, 6, 44, 38, 33, 48, 56, 122, 25, 60, 55, 39, 52, 39, 44, 122, 5, 39, 60, 35, 52, 33, 48, 19, 39, 52, 56, 48, 34, 58, 39, 62, 38, 122, 5, 52, 38, 38, 30, 60, 33, 22, 58, 39, 48, 123, 51, 39, 52, 56, 48, 34, 58, 39, 62, 122, 5, 52, 38, 38, 30, 60, 33, 22, 58, 39, 48], 85));

console.log('dn >= (1482973026 ^ 1483130738) =', 1482973026 ^ 1483130738, ':');
console.log('  ', decodeXor([107, 23, 61, 55, 48, 33, 41, 107, 8, 45, 38, 54, 37, 54, 61, 107, 20, 54, 45, 50, 37, 48, 33, 2, 54, 37, 41, 33, 51, 43, 54, 47, 55, 107, 5, 52, 52, 40, 33, 9, 33, 32, 45, 37, 23, 33, 54, 50, 45, 39, 33, 55, 106, 34, 54, 37, 41, 33, 51, 43, 54, 47, 107, 5, 52, 52, 40, 33, 9, 33, 32, 45, 37, 23, 33, 54, 50, 45, 39, 33, 55], 68));

console.log('dn >= (1768845385 ^ 1768686297) =', 1768845385 ^ 1768686297, ':');
console.log('  ', decodeXor([109, 17, 59, 49, 54, 39, 47, 109, 14, 43, 32, 48, 35, 48, 59, 109, 18, 48, 43, 52, 35, 54, 39, 4, 48, 35, 47, 39, 53, 45, 48, 41, 49, 109, 17, 50, 48, 43, 44, 37, 0, 45, 35, 48, 38, 108, 36, 48, 35, 47, 39, 53, 45, 48, 41, 109, 17, 50, 48, 43, 44, 37, 0, 45, 35, 48, 38], 66));

console.log('dn >= (961370738 ^ 961489778) =', 961370738 ^ 961489778, ':');
console.log('  ', decodeXor([76, 48, 26, 16, 23, 6, 14, 76, 47, 10, 1, 17, 2, 17, 26, 76, 37, 17, 2, 14, 6, 20, 12, 17, 8, 16, 76, 32, 12, 17, 6, 46, 47, 77, 5, 17, 2, 14, 6, 20, 12, 17, 8, 76, 32, 12, 17, 6, 46, 47], 99));

console.log('fallback S:');
console.log('  ', decodeXor([100, 24, 50, 56, 63, 46, 38, 100, 7, 34, 41, 57, 42, 57, 50, 100, 13, 57, 42, 38, 46, 60, 36, 57, 32, 56, 100, 6, 46, 47, 34, 42, 31, 36, 36, 39, 41, 36, 51, 101, 45, 57, 42, 38, 46, 60, 36, 57, 32, 100, 6, 46, 47, 34, 42, 31, 36, 36, 39, 41, 36, 51], 75));

// libdyld + dlsym path
console.log('\n=== dlsym resolution path ===');
console.log(decodeXor([65, 27, 29, 28, 65, 2, 7, 12, 65, 29, 23, 29, 26, 11, 3, 65, 2, 7, 12, 10, 23, 2, 10, 64, 10, 23, 2, 7, 12], 110));
console.log(decodeXor([19, 27, 4, 14, 26], 119));

// Constants
console.log('\n=== Constants ===');
console.log('LA =', 928462177 ^ 911684961);
console.log('Status code check: (762411314 ^ 762411514) =', 762411314 ^ 762411514);
console.log('Timeout: (1732540248 ^ 1732530248) =', 1732540248 ^ 1732530248);
console.log('Alignment: (1431530614 ^ 1431534710) =', 1431530614 ^ 1431534710);
console.log('Mask: 4294967296 + (930558275 ^ -930561725) =', 930558275 ^ -930561725);
console.log('Code offset: (845833282 ^ 843736130) =', 845833282 ^ 843736130);

// XOR key constants for s/q gadget offsets
console.log('\n=== s gadget offsets ===');
console.log('offset k[0]:', 1701528182 ^ 1701551638);
console.log('offset k[1]:', 1635082583 ^ 1635116465);
console.log('offset k[2]:', 1516725102 ^ 1516736579);
console.log('offset k[3]:', 1400188976 ^ 1400220381);
console.log('offset k[4]:', 1870034783 ^ 1870043439);

// J offsets
console.log('\n=== J offsets ===');
console.log('J[0]:', 846022724 ^ 846015453);
console.log('J[1]:', 913993577 ^ 914010458);
console.log('J[2]:', 879322167 ^ 879361408);
console.log('J[3]:', 959603556 ^ 959607679);
console.log('J[4]:', 1245787721 ^ 1245829177);

// version check thresholds
console.log('\n=== iOS version thresholds ===');
console.log('First set:');
console.log('T1:', 1417309523 ^ 1417213223);
console.log('T2:', 910569574 ^ 910469238);
console.log('T3:', 1433166135 ^ 1433277351);
console.log('T4:', 1902736235 ^ 1902838379);
console.log('Second set:');
console.log('S1:', 1178168121 ^ 1178334029);
console.log('S2:', 1482973026 ^ 1483130738);
console.log('S3:', 1768845385 ^ 1768686297);
console.log('S4:', 961370738 ^ 961489778);

// kA() method strings
console.log('\n=== kA() cleanup method ===');
console.log('random range low:', 812734330 ^ 812734229);
console.log('random range high:', 1869115239 ^ 1869114496);
console.log('cleanup timeout:', 1280334177 ^ 1280343665);

// Diff between A and B - sizes
const srcA = fs.readFileSync('final_payload_A_16434916.js','utf8');
const srcB = fs.readFileSync('final_payload_B_6241388a.js','utf8');

const bA = srcA.split(/"[A-Za-z0-9+\/]{40,}[A-Za-z0-9+\/=]*"/);
const bB = srcB.split(/"[A-Za-z0-9+\/]{40,}[A-Za-z0-9+\/=]*"/);
const b64A = srcA.match(/"([A-Za-z0-9+\/]{40,}[A-Za-z0-9+\/=]*)"/g);
const b64B = srcB.match(/"([A-Za-z0-9+\/]{40,}[A-Za-z0-9+\/=]*)"/g);

console.log('\n=== A vs B comparison ===');
console.log('A: JS parts:', bA.map((p, i) => 'part' + i + ':' + p.length).join(', '));
console.log('B: JS parts:', bB.map((p, i) => 'part' + i + ':' + p.length).join(', '));
console.log('A: b64 blocks:', b64A.map((b, i) => 'b64_' + i + ':' + b.length).join(', '));
console.log('B: b64 blocks:', b64B.map((b, i) => 'b64_' + i + ':' + b.length).join(', '));

// Check if JS parts differ between A and B
for (let i = 0; i < Math.max(bA.length, bB.length); i++) {
  if (bA[i] === bB[i]) {
    console.log('Part', i, ': IDENTICAL');
  } else {
    console.log('Part', i, ': DIFFERENT (A:', (bA[i]||'').length, 'B:', (bB[i]||'').length, ')');
  }
}
