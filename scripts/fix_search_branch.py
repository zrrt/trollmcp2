# -*- coding: utf-8 -*-
import io

path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\BrowserManager.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

old = '''            } else if hasSpaceOrCN || !hasDot {
                let q = u.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? u
                return "已在 Bing 搜索：\\(u)（非网址，按搜索处理）| https://www.bing.com/search?q=\\(q)"
            } else {'''
new = '''            } else if hasSpaceOrCN || !hasDot {
                let q = u.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? u
                u = "https://www.bing.com/search?q=\\(q)"
            } else {'''
assert old in c, 'search branch not found'
c = c.replace(old, new)
with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('FIXED search branch')
