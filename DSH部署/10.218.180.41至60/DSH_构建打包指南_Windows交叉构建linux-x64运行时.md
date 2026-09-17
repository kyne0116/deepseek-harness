# DSH 构建打包指南（Windows 构建机交叉构建 linux-x64 运行时）

> 适用：在本 Windows 构建机上，从 deepseek-harness 源码（fork，跟踪上游）交叉构建出可在内网
> Linux 服务器部署的 DSH 运行时 wheel（exe 载体）。与 CI 的原生平台构建走**同一套脚本**，仅宿主
> 为 Windows，因此有一层交叉构建的额外准备。
> 本文是构建机侧手册；服务器侧衔接见《DSH_test03_mapp部署手册.md》与
> 《DSH_test03_升级修复client-modules_操作手册.md》。
> 命令均为 Git Bash 语法；路径以本机实际安装为准（下文用 `D:\06_Programs\nodejs24.19` 示例）。

---

## 1. 适用场景与产物

| 产物 | 路径 | 参考大小 |
|---|---|---|
| 运行时 exe（Linux x64，pkg --sea） | `dist-exe/deepseek-harness-sdk-runtime-linux-x64` | 约 300 MB |
| ripgrep sidecar | `dist-exe/deepseek-harness-sdk-runtime-linux-x64-rg` | 约 5.5 MB |
| **最终交付物：runtime wheel** | `dist-python/deepseek_harness_runtime_bin-<ver>-py3-none-manylinux_2_28_x86_64.whl` | 约 98 MB |

- wheel 内只装 exe + rg sidecar（macOS 还有 spawn-helper），node 载体树（`runtime/node/`）不进 wheel。
- **版本号唯一来源是仓库根 `package.json`**。仓库写法与 wheel 文件名按 PEP 440 换算：
  `0.1.5-rc.2` → `0.1.5rc2`，即 `deepseek_harness_runtime_bin-0.1.5rc2-py3-none-manylinux_2_28_x86_64.whl`。
- exe 内部是一个完整的 node_modules 闭包（pkg /snapshot VFS），闭包成员由
  `python/sdk-runtime/package.json`（`dsh-python-runtime-closure`）声明，经 `pnpm deploy` 物化。

## 2. 构建机环境基线

| 组件 | 本机实测 | 备注 |
|---|---|---|
| Node | v24.19.0（`D:\06_Programs\nodejs24.19`） | pkg 目标 node24，与宿主大版本一致即可 |
| pnpm | 11.7.0（经 corepack 启动） | 见下方 npm_execpath 关键差异 |
| uv | 0.8.5+ | 打 wheel 用（`uv build --wheel`） |
| Python 3 | 3.x（Anaconda） | 跑 `scripts/build-python-release.py` 与辅助取证 |
| Docker/WSL | 不需要 | 交叉构建路线不依赖容器（node-pty 用目标 prebuild） |

**Windows 关键差异（第一坑）**：构建脚本在 Windows 上要求 pnpm 暴露 JS 入口（`npm_execpath`），
而 `pnpm exec` **不会**注入该变量，直接报：

```
Error: build-exe-for-python-sdk: pnpm must expose a JavaScript entrypoint through npm_execpath or PNPM_HOME on Windows.
```

处置：所有构建命令显式带上（corepack 场景）：

```bash
export npm_execpath="D:/06_Programs/nodejs24.19/node_modules/corepack/dist/pnpm.js"
```

网络：pnpm 走 npmmirror 正常；pkg 首次会从 nodejs.org 下载目标基座二进制
（`node-v24.x-linux-x64.tar.gz` 约 50 MB，另加一份 win 宿主版用于生成 SEA blob），缓存在
`~/.pkg-cache`，之后增量构建不再下载。

## 3. 一次性准备（已在本仓库落地，同步上游时注意保留）

本节改动**以补丁形式随本文档携带**（`DSH部署/patches/`，`git format-patch` 导出），仓库主线保持与官方一致、不携带代码分叉。重建运行时前先应用补丁：

```bash
git am DSH部署/patches/*.patch    # 上游演进导致冲突时，按下列小节说明手工重放
```

并逐条核对：上游若已自行修复，以上游为准（第 9 节有分类清单与上游状态）。

### 3.1 物化 linux-x64 平台包（`pnpm-workspace.yaml`）

```yaml
supportedArchitectures:
  os: [current, linux]
  cpu: [current, x64]
```

原因：`@vscode/ripgrep-linux-x64` 等平台受限 optional 依赖默认只在匹配平台安装。不物化的话，
构建在"复制 rg sidecar"一步报 `target ripgrep binary is missing at .../ripgrep-linux-x64/bin/rg`。

### 3.2 node-pty 交叉守卫放宽（`scripts/build-exe-for-python-sdk*.ts`）

node-pty 1.2.0-beta.15 自带 `prebuilds/linux-x64/pty.node`（NAPI 产物，随 npm 包分发）。
构建脚本原逻辑要求 linux 构建必须在 linux 宿主做；现改为：**目标 prebuild 存在时允许交叉**，
仅"本机编译产物"仍强制宿主架构匹配。Windows 上无需容器即可出 linux exe。

### 3.3 wheel 可执行位的 Windows 处理（`python/sdk-runtime/hatch_build.py`、`scripts/build-python-release.py`）

Windows 文件系统不表达 POSIX exec 位，两处 `S_IXUSR` 检查在 Windows 宿主必然失败。
已改为 `os.name != "posix"` 时跳过检查，**但打包后必须给 zip 内两条 payload 补写 0o755**
（第 4.4 步），使产物形状与 CI 一致。

### 3.4 闭包清单补 `@deepseek-ai/dsh-session-title-llm`（`python/sdk-runtime/package.json`）

base bundle 挂载的 `session-title-llm` 行（`@deepseek-ai/dsh-session-title-first-prompt-llm`）
静态导入该包；缺失则 **web 启动直接失败**。上游已在 commit 6aa2e4633c 修复，本仓库（rc.2 基线）
需保留同款行：`"@deepseek-ai/dsh-session-title-llm": "workspace:^"`。

### 3.5 产品修复（非构建问题，但随本次 wheel 交付）

`packages/client/modules`：exe 在 `$DSH_HOME/profiles/node_modules` 用 ESM 代理桩替代软链，
桩清单不含 `dsh.client`，导致客户端插件扫描全部落空（boot 图为空）。扫描器现按
`dsh.moduleFallback.targets` 跳回真实包继续扫描。**上游尚无此修复**，回馈上游见第 9 节。

## 4. 标准构建流程

### 4.0 会话级环境变量（每次开终端都要）

```bash
cd /d/02_Dev/Workspace/GitHub/harness/deepseek-harness
export CI=true                 # 必须：非 TTY 下 pnpm 清理 node_modules 需要确认，无它则中止
export npm_execpath="D:/06_Programs/nodejs24.19/node_modules/corepack/dist/pnpm.js"
```

### 4.1 全量构建（首次 / 改过 TS 源码 / 改过客户端代码）

```bash
DSH_BUILD_CLIENT_PROFILE=official pnpm exec tsx scripts/build-exe-for-python-sdk.ts \
  --targets=node24-linux-x64
```

流水线各步（耗时为参考值）：

| 步骤 | 做什么 | 参考耗时 |
|---|---|---|
| verify-runtime-closure | 校验闭包清单闭合（预设插件 + workspace peer） | 秒级 |
| `pnpm run build` | 全仓 tsc + tsdown 出各包 `lib/`（含 web 前端 dist） | 15~25 min |
| `pnpm deploy` 闭包暂存 | 把闭包物化到 `python/sdk-runtime/src/deepseek_harness_runtime/runtime/node/` | 5~10 min |
| pkg --sea 打包 | 下载基座（首次）/ 读缓存 → 生成 blob → 注入 exe | 5~10 min |
| sidecar 与同步 | 拷 `-rg`，产物同步进 python runtime 目录 | 秒级 |

**成功标志**（结尾四行）：

```
build-exe-for-python-sdk: products:
  D:\...\dist-exe\deepseek-harness-sdk-runtime-linux-x64  (300.x MB)
  D:\...\dist-exe\deepseek-harness-sdk-runtime-linux-x64-rg  (5.5 MB)
build-exe-for-python-sdk: synced ...
```

### 4.2 增量构建（`lib/` 产物已存在，仅重打包）

```bash
CI=true pnpm exec tsx scripts/build-exe-for-python-sdk.ts --targets=node24-linux-x64 --skip-build
```

跳过全仓编译，保留 deploy → pkg → sync（约 5~8 min）。**注意**：deploy 每次都会清空重建暂存目录。

### 4.3 改过闭包清单 / 依赖后

```bash
CI=true pnpm --config.verify-deps-before-run=false install --no-frozen-lockfile
CI=true pnpm exec tsx scripts/build-exe-for-python-sdk.ts --targets=node24-linux-x64 --skip-build
```

### 4.4 打 runtime wheel（含 exec 位补写）

```bash
python scripts/build-python-release.py --package runtime --platform linux-x64 \
  --runtime-exe dist-exe/deepseek-harness-sdk-runtime-linux-x64 --output-dir dist-python
```

Windows 宿主打 POSIX wheel 时，随后把 zip 内两条 payload 的权限位补成 0o755（对齐 CI 产物）：

```bash
python - <<'PY'
import zipfile, os
src = 'dist-python/deepseek_harness_runtime_bin-0.1.5rc2-py3-none-manylinux_2_28_x86_64.whl'
tmp = src + '.fix'
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(tmp, 'w') as zout:
    for info in zin.infolist():
        if 'runtime/deepseek-harness-sdk-runtime-' in info.filename:
            info.external_attr = (0o755 << 16) | (info.external_attr & 0xFFFF)
        zout.writestr(info, zin.read(info.filename))
os.replace(tmp, src)
print('exec bits patched')
PY
```

> 通用经验：**不要用 `命令 | tail` 的方式跑构建**——管道会吞退出码，失败也显示 exit 0。
> 直接执行看完整输出，或后台运行看输出文件。

## 5. 本地发布前冒烟（强烈建议，勿省）

用暂存的 node 载体起一次 `dsh web`，**交付前拦截闭包缺口与空图**（比到服务器上发现便宜一个量级）：

```bash
# 1) 起 web（临时 DSH_HOME，独立端口，别用 7103）
rm -rf /tmp/dsh-smoke-home && mkdir -p /tmp/dsh-smoke-home
DSH_HOME="$(cygpath -w /tmp/dsh-smoke-home)" \
  node python/sdk-runtime/src/deepseek_harness_runtime/runtime/node/node_modules/@deepseek-ai/dsh/lib/bin.js \
  web --port 7188 --no-open
```

成功标志：打印 `dsh web: http://127.0.0.1:7188/?token=<TOKEN>`。
失败形态一：`Cannot find package '@deepseek-ai/...'` → 闭包缺包，回第 3.4/7 节。
失败形态二：`plugin tree failed to load` → 看堆栈最深处哪个包/行出的问题。

```bash
# 2) 验收 boot 图（另开终端）
TOKEN=<上面抓到的token>
curl -s -c /tmp/jar "http://127.0.0.1:7188/?token=$TOKEN" -o /dev/null     # 303 拿 cookie
curl -s -b /tmp/jar "http://127.0.0.1:7188/" -o /tmp/idx.html
python - <<'PY'
import json
html = open('/tmp/idx.html', encoding='utf8').read()
key = 'globalThis["__DSH_BOOT__"] = '
i = html.find(key)
boot, _ = json.JSONDecoder().raw_decode(html[i+len(key):])
print('rev:', boot['rev'], '| entries:', len(boot['entries']), '| batches:', len(boot['batches']))
PY
# 3) 验收 bootstrap combo（预期 HTTP 200 text/javascript）
curl -s -b /tmp/jar -D- -o /dev/null "http://127.0.0.1:7188/plugins/??@deepseek-ai/dsh-client-modules/client.js&rev=<图中rev>" | head -1
```

**判定**：entries > 0（本次实测 53 entries / 2 batches）且 combo 200。结束后杀掉 node 进程、删临时 home。

## 6. 产物自检清单

| 检查项 | 命令/方法 | 预期 |
|---|---|---|
| ELF 魔数 | `head -c 4 dist-exe/...-linux-x64 \| od -A n -t x1` | `7f 45 4c 46` |
| wheel 内 exe 带修复代码 | zip 流式 grep 特征串（如 `moduleFallbackTarget`） | FOUND |
| wheel 内闭包含关键包 | zip 流式 grep 包描述串（如 session-title-llm 的 description） | FOUND |
| payload exec 位 | `zipinfo` 或 python 读 external_attr | `0o755` |
| 版本 | 服务器侧 `--version` 或 wheel 文件名 | 与根 package.json 的 PEP 440 形态一致 |
| 空图指纹对照 | 页面 `__DSH_BOOT__.rev` 是否等于 `240c4d8dcf0d` | **等于即为空图**（`sha1('{"entries":[],"batches":[]}')` 前 12 位），本产品"插件加载失败"故障的特征值 |

## 7. 常见坑速查表

| # | 症状 | 根因 | 处置 |
|---|---|---|---|
| 1 | `pnpm must expose a JavaScript entrypoint ... on Windows` | `pnpm exec` 不注入 `npm_execpath` | `export npm_execpath=<corepack>/dist/pnpm.js` |
| 2 | `target ripgrep binary is missing at .../ripgrep-linux-x64/bin/rg` | Windows 宿主默认不物化 linux 平台 optional 包 | §3.1 `supportedArchitectures` + 重装依赖 |
| 3 | `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` | 依赖配置变更后 pnpm 要清 node_modules，非 TTY 等确认 | 命令带 `CI=true` |
| 4 | `Cannot install with "frozen-lockfile"` | `CI=true` 使 frozen-lockfile 默认开 | 清单变更时加 `--no-frozen-lockfile` |
| 5 | pnpm 自动依赖检查抢跑 `install --production`，甚至裁掉 root devDependencies | pnpm 11 `verifyDepsBeforeRun` 默认 install | 关键命令带 `--config.verify-deps-before-run=false`；发现 root 依赖被裁就重跑完整 `pnpm install` 恢复 |
| 6 | 冒烟报 `Cannot find package '@deepseek-ai/...'`，启动即崩 | 闭包缺口；`verify-runtime-closure` 的 workspace glob（`packages/*/*`+`vendor/*`）**不含 `apps/*`**，app 层 peer 缺口它看不见 | 先 `git show origin/master:python/sdk-runtime/package.json` 对照上游补缺失项（本次 session-title-llm 即上游 6aa2e4633c）；最终以 §5 冒烟为准 |
| 7 | wheel 构建报 `runtime executable is not executable` / `lost its executable bit` | Windows fs 无 POSIX exec 位 | §3.3 已跳过检查 + §4.4 补 0o755 |
| 8 | 后台构建"成功"（exit 0）实际失败 | `| tail` 管道吞退出码 | 去掉管道直跑，或看 `$PIPESTATUS` |
| 9 | 页面报 `HTML did not preload @deepseek-ai/dsh-client-modules/client.js`、boot 图 rev=`240c4d8dcf0d` | exe 代理桩清单无 `dsh.client`，扫描全空（产品 bug，已修） | 保留 §3.5 修复；回归测试在 `packages/client/modules/tests/node-half.client.spec.ts` |

## 8. 与部署侧的衔接

- wheel 上服务器后按《DSH_test03_mapp部署手册》§3 的解压/权限位流程 + 《DSH_test03_升级修复client-modules_操作手册》替换重启。
- **联调高发坑（非构建，但同链路）**：DSH 的 `/api` 信任门要求请求 `Origin` 与服务器收到的 `Host` 头**完全一致**（含端口）。全链路 nginx（跳板机 + DSH 机）必须 `proxy_set_header Host $http_host;`（`$host` 会剥端口 → `/api` 全 403 → 页面"自动重连中"），并建议 `proxy_buffering off` + `proxy_read_timeout 3600s` 保 SSE。成稿见 nginx 材料目录 `DSH配置/`、`159和160跳板机配置/` 下的 `simbest.conf`。

## 9. 附：本次仓库改动清单（便于拆分提交与回馈上游）

| 文件 | 类别 | 内容 |
|---|---|---|
| `packages/client/modules/src/index.ts` | **产品修复** | `nearestPackage` 识别 `dsh.moduleFallback` 代理并跳回真实包；无 internals 分支裸名回退解析。**上游没有，建议提 PR** |
| `packages/client/modules/tests/node-half.client.spec.ts` | 测试 | 代理布局回归用例 ×3（无 internals / v1 / v2） |
| `python/sdk-runtime/package.json` + `pnpm-lock.yaml` | 闭包 | 补 `@deepseek-ai/dsh-session-title-llm`（同上游 6aa2e4633c） |
| `pnpm-workspace.yaml` | 构建辅助 | `supportedArchitectures` 物化 linux-x64 平台包 |
| `scripts/build-exe-for-python-sdk.ts`、`...-native-pty.ts`、`...-native-pty.spec.ts` | 构建辅助 | 目标 prebuild 存在时允许 linux 交叉构建 |
| `python/sdk-runtime/hatch_build.py`、`scripts/build-python-release.py` | 构建辅助 | Windows 宿主跳过 exec 位检查 |

回馈上游建议：① client-modules 代理扫描修复（PR，上游 master 尚无）；② `verify-runtime-closure.ts` 的 workspace glob 漏 `apps/*` 导致 app 层 peer 缺口不可见（issue）；③ 闭包清单项上游已自修，无需重复。
