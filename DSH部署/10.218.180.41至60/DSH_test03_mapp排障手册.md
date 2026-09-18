# DSH test03 排障手册（mapp 版 · 症状决策树）

> 适用边界：**部署完成后服务器上的运行期故障**。构建机上的故障（类型错误、打包失败、依赖断链）
> 一律见《DSH_构建打包指南_Windows交叉构建linux-x64运行时.md》§3.6 官方缺口总账（F1~F7）与 §7 常见坑速查表。
> 操作账号：mapp（全程免 root）。术语见 `DSH部署/CONTEXT.md`。

---

## 1. 第一分钟：通用状态三连

任何故障先跑这三条，输出留好：

```bash
systemctl --user status dsh-web-45@test03 --no-pager | head -6   # Active 行 + Main PID
ss -lntp | grep 7103 || echo "7103 未监听"                        # 端口与进程对账
tail -40 /data/dsh/dsh-logs/dsh-web-45-test03.log                # 服务日志尾部（崩溃原因必在此）
```

判定基线：

- `Active: active (running)` 且 7103 由同一 PID 监听 → 实例活着，故障在更上层（nginx/网络/浏览器）
- `Active: activating (auto-restart)` 或反复出现新 PID → **崩溃循环**，转 §2.2
- `Active: failed` / `inactive` → 转 §2.1

注意：`systemctl --user status` 的 `Loaded:` 行若为 `disabled`，实例不会开机自启 ——
顺手 `systemctl --user enable dsh-web-45@test03`。

mapp 默认读不了用户级 journal（无 `systemd-journal` 组），崩溃退出码看不到属正常；
管理员可 `usermod -aG systemd-journal mapp` 解除。进程级诊断靠服务日志即可。

---

## 2. 症状决策树

### 2.1 页面 502 Bad Gateway（nginx 活着，后端不在）

```
502 ──→ systemctl status 是 active 且 7103 在听？
        ├─ 否 → 实例死了/没起。看服务日志尾部找退出原因（转 §2.2 / §2.3）
        └─ 是 → 实例活着，查 nginx 侧：
                · code.dsh.internal 等其他 vhost 能开吗？能 → nginx/VIP 正常，
                  是 7103 后端无响应（进程僵死/引导中）→ 等 60s 重试，仍无响应转 §2.2
                · 不能 → 跳板机/防火墙问题，见部署手册 §1.1 链路与跳板机 /ngStatus
```

对照：`code.dsh.internal`（code-server）能开而 test03 502 ⇒ 故障被隔离到 DSH 实例本身。

### 2.2 崩溃循环（反复重启 / 每次看都恰好是活窗口）

判据：短时间内 Main PID 变化、`grep -c "token=" 服务日志`（每次成功启动打印一条 token，
条数 ≈ 启动次数）。**token 总数远大于预期 = 崩溃循环。**

OOM 排除：`free -h` 看水位 + `journalctl -k | grep -i oom`（需权限）。
本机 62GB 实测 OOM 概率极低；优先怀疑启动期引导失败（见 §3 对照表 B 类）。

### 2.3 启动即退 / 插件树加载失败

服务日志特征与处置见 §3 对照表 A/B 类。共同套路：

1. 日志找到最内层 `[cause]` 的**第一句**（外层 Error 是包装，无信息量）
2. 对照 §3 表定位根因
3. 处置后 `systemctl --user restart` 并**等足 45 秒**再判生死
   （引导要加载全部插件条目，3 秒的活窗口会骗人）

---

## 3. 日志特征 → 根因 → 处置 对照表

### A 类：进程活、页面/接口异常

| 日志/浏览器特征 | 根因 | 处置 |
|---|---|---|
| 页面 401 | token 轮换（**每次重启必变**） | `grep -o 'token=[A-Za-z0-9_-]*' 服务日志 \| tail -1` 拿新 token |
| 对话报 `no API key for provider route "deepseek-official"` | LLM 两份配置缺失：`$DSH_HOME/settings.yaml`（moma 提供方 + 默认模型）与实例 env 的 `MOMA_API_KEY`（占位符未替换） | settings.yaml 按部署手册 §1.5 成稿落位；env 里 key 填真值后 `systemctl --user restart`；已有会话在模型选择器切到 Qwen3.8-27B |
| 浏览器 `Failed to load plugins — N entries did not activate — waiting for services: sessions` | 对应包的 `lib/client.js`（浏览器端服务模块）不在快照里 —— client 面 tsdown 未成功 | 构建侧问题，见构建指南 F7；重出 wheel 部署 |
| 探活路径通、页面元素齐、仅个别功能异常 | 检查 F12 Network 对应 RPC 的响应 | 按 RPC 报错继续排查 |

### B 类：启动期退出（崩溃循环主因）

| 日志特征（最内层 cause） | 根因 | 处置 |
|---|---|---|
| `No "exports" main defined in .../profiles/node_modules/@deepseek-ai/dsh-api-session-controller/package.json` | 代理桩缺 `.` 主入口：staging 里该包 `lib/index.js` 缺失 → 桩生成器静默跳过 `.` 子路径 → web profile 按裸包名导入根入口必炸 | 已随 0.1.5rc2 修复版 wheel 解决（staging 补齐 index.js，桩重建自动含 `.`）；若复现属构建侧回归，见构建指南 F3/F7 |
| `Invalid URL` at `vfsResolveHook` | 同上的伴生症状：桩的 `.` 重导出（file:///snapshot URL）在引导解析链上触发 | 同上；该错误在 0.1.5rc2 修复版上为**非致命残留**（进程存活、API 正常），仅日志噪音 |
| `Cannot find module .../node-addon-system-linux-x64/bin/glibc/system.node` | flock 原生插件二进制不在快照（构建产物不入库，Windows 交叉构建无来源） | 已随 0.1.5rc2 修复版解决（bin/ 取自官方 npm 0.1.2）；若复现见构建指南 F6 |
| `dsh: plugin tree failed to load`（外层包装） | 上三条之一的包装形态 | 永远找最内层 `[cause]` |
| `SyntaxError` 指向 sea-main/prelude | SEA 引导补丁损坏 | 本地 `node --check` 补丁后的 prelude 文件；重出 exe |
| `code=killed, status=9/KILL`（journal）+ `free -h` 水位告急 | OOM | 收缩其他进程 / 加内存；本机 62GB 实测未复现 |

### C 类：历史已修复案例（仅备查，勿复现权宜脚本）

| 案例 | 处置状态 |
|---|---|
| preset 扫描 `child.isDirectory is not a function`（0.1.5rc1/初版 rc2 exe） | ✅ pkg SEA prelude 补丁（构建指南 F1 + `patches/@yao-pkg__pkg@6.21.0.patch`），0.1.5rc2 修复版已验证 |
| flock `Cannot find module ... system.node`（初版 rc2 exe） | ✅ 0.1.5rc2 修复版已内置三件二进制（F6） |
| 服务器端手工补桩 `.`（python 脚本批处理 profiles/node_modules） | ⛔ **已废弃** —— 新桩自愈机制含 `.`，手工脚本会随后续启动被覆盖，勿再使用 |

---

## 4. 与其他文档的衔接

- 术语（载体/代理桩/桩自愈/伴随占位/profile…）：`DSH部署/CONTEXT.md`
- 构建期故障（tsc/tsdown/pkg/pnpm）：构建指南 §3.6 F1~F7 + §7 常见坑速查表
- 首次部署 / runtime 升级 / 重装：部署手册 §3、§8.1
- LLM 提供方与默认模型：部署手册 §1.5、§4；`dsh-deploy-files/test03-settings.yaml` 成稿
