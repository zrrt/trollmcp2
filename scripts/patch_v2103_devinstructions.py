import io
p = r'Resources\TrollMCPDeveloperInstructions.md'
s = io.open(p, encoding='utf-8').read()
old = "- **核心白名单**（约 11 个）直接可用：tool_search, ping, device.info, device.probe, workspace.info, artifact.list, artifact.read_text, artifact.find, model.config, injection.status, browser.status。"
new = "- **核心白名单**（约 13 个）直接可用：tool_search, ping, device.info, device.probe, workspace.info, artifact.list, artifact.read_text, artifact.find, model.config, injection.status, browser.status, apps.control。"
assert old in s, 'old not found'
s = s.replace(old, new)
anchor = "- **工具名用点号分层**（如 `injection.enable`、`binary.symbols`）。"
assert anchor in s, 'anchor not found'
add = anchor + "\n\n- **任意 App UI 控制链路（v2.9.103）**：先 `injection.enable`（注入 TrollMCPAgent v4.1，构建时随包自动编译），再 `apps.open` 打开目标 App，等 agent HTTP（127.0.0.1:4792）就绪后用 `apps.control`（action: status/ui_tree/tap/swipe/type/scroll）直接控制 UI；`apps.open_and_input` 已改为 HTTP 链路（打开→等待就绪→type），不再依赖沙盒内 UserDefaults 队列。"
s = s.replace(anchor, add)
io.open(p,'w',encoding='utf-8',newline='').write(s)
print('OK')
