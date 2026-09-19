const fs = require('fs');
const path = require('path');

// Collect all XOR-decoded strings across the entire codebase
const dir = '.';
const files = fs.readdirSync(dir).filter(f => f.endsWith('.js') && !f.startsWith('_'));

const allStrings = new Map(); // decoded string → [{file, xorKey}]

for (const file of files) {
  const src = fs.readFileSync(path.join(dir, file), 'utf8');
  const re = /\[([\d, ]+)\]\.map\(x\s*=>\s*\{return String\.fromCharCode\(x\s*\^\s*(\d+)\);\}\)\.join\(""\)/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    try {
      const nums = m[1].split(',').map(n => parseInt(n.trim()));
      const key = parseInt(m[2]);
      const decoded = nums.map(n => String.fromCharCode(n ^ key)).join('');
      if (!allStrings.has(decoded)) allStrings.set(decoded, []);
      allStrings.get(decoded).push({ file, xorKey: key });
    } catch(e) {}
  }
}

// Categorize strings
const categories = {
  'Module Hashes': [],
  'Mach-O Segments & Sections': [],
  'Framework Paths': [],
  'Symbol Names': [],
  'ObjC Selectors': [],
  'Network/Protocol': [],
  'DOM/Browser': [],
  'Dyld/System': [],
  'Other': []
};

for (const [str, locations] of allStrings) {
  const fileCount = new Set(locations.map(l => l.file)).size;
  const entry = { str, fileCount, keys: [...new Set(locations.map(l => l.xorKey))], files: [...new Set(locations.map(l => l.file))] };

  if (/^[0-9a-f]{40}$/.test(str)) categories['Module Hashes'].push(entry);
  else if (str.startsWith('__')) categories['Mach-O Segments & Sections'].push(entry);
  else if (str.startsWith('/System/') || str.startsWith('/usr/')) categories['Framework Paths'].push(entry);
  else if (str.startsWith('_ZN') || str.startsWith('_OBJC') || str === 'dlsym') categories['Symbol Names'].push(entry);
  else if (str.includes('selector') || /^[a-z]+[A-Z]/.test(str) && str.length > 10) categories['ObjC Selectors'].push(entry);
  else if (['POST','GET','Content-Type','application/json','application/javascript','arraybuffer','XMLHttpRequest'].includes(str)) categories['Network/Protocol'].push(entry);
  else if (['script','error','src','div','style','opacity: 0.0','.js','.min.js.js'].includes(str)) categories['DOM/Browser'].push(entry);
  else if (str.includes('dyld') || str.includes('jit') || str.includes('arm64')) categories['Dyld/System'].push(entry);
  else categories['Other'].push(entry);
}

// Print summary
console.log('Total unique decoded strings:', allStrings.size);
console.log('Total files scanned:', files.length);
console.log('');

for (const [cat, entries] of Object.entries(categories)) {
  if (entries.length === 0) continue;
  console.log('=== ' + cat + ' (' + entries.length + ') ===');
  for (const e of entries) {
    console.log('  ' + JSON.stringify(e.str) + ' (XOR keys: ' + e.keys.join(',') + ', in ' + e.fileCount + ' files)');
  }
  console.log('');
}
