# DSH test03 修复升级手册（0.1.5rc1 → 0.1.5rc2 · client-modules 空图修复）

> 前提：test03 已按《DSH_test03_mapp部署手册.md》完成部署，当前运行 0.1.5rc1。
> 本次升级只替换 runtime 载体（wheel），nginx、systemd unit、实例 env 均不动。
> 产物：`deepseek_harness_runtime_bin-0.1.5rc2-py3-none-manylinux_2_28_x86_64.whl`（约 98 MB，构建机产出 `dist-python/`）

---

## 0. 本次修复内容（备查）

1. **客户端插件扫描无法识别 exe 模块回退代理**：打包 exe 在 `$DSH_HOME/profiles/node_modules` 下用 ESM 代理桩替代软链，代理清单不含 `dsh.client`，导致 boot 图组装为空（`__DSH_BOOT__` rev 恒为 `240c4d8dcf0d`，页面报 `HTML did not preload @deepseek-ai/dsh-client-modules/client.js`）。修复：扫描器命中代理清单时按 `dsh.moduleFallback.targets` 跳回真实包继续扫描。
2. **闭包清单缺 `@deepseek-ai/dsh-session-title-llm`**：`session-title-llm` 行的静态导入找不到包会让 web 启动直接失败。已按上游 master 同款修复补入 `python/sdk-runtime/package.json`（上游 commit 6aa2e4633c 同款）。
3. 构建辅助：允许 Windows 构建机用 node-pty 目标 prebuild 交叉出 linux-x64 exe；Windows 宿主打 wheel 时跳过 POSIX 可执行位检查并在产物内补写 0o755。

已在本机验证：node 载体 `dsh web` 冒烟 → boot 图 **53 entries / 2 batches**，bootstrap combo 200。

---

## 1. 上传产物（Windows → 服务器，mapp 可写目录）

```powershell
# Windows 侧
scp dist-python/deepseek_harness_runtime_bin-0.1.5rc2-py3-none-manylinux_2_28_x86_64.whl mapp@10.218.180.45:/data/dsh/pkg/
```

## 2. 停服务、备份、解压（服务器，mapp）

```bash
# 1) 停实例
systemctl --user stop dsh-web-test03
ss -lntp | grep 7103 || echo "7103 已释放"

# 2) 备份当前 runtime（回滚用）
cp -a /data/dsh/dshruntime/deepseek_harness_runtime/runtime \
      /data/dsh/dshruntime/deepseek_harness_runtime/runtime.rc1.bak

# 3) 解压新 wheel（覆盖 runtime/ 下同名 exe 与 rg sidecar）
python3 -m zipfile -e \
  /data/dsh/pkg/deepseek_harness_runtime_bin-0.1.5rc2-py3-none-manylinux_2_28_x86_64.whl \
  /data/dsh/dshruntime/
```

## 3. 修可执行位 + 验证版本（沿用部署手册 §3 的做法）

```bash
# 1) 按 wheel 内记录的权限位恢复，runtime/ 整体 0o755
python3 - <<'PY'
import os, zipfile
whl  = "/data/dsh/pkg/deepseek_harness_runtime_bin-0.1.5rc2-py3-none-manylinux_2_28_x86_64.whl"
base = "/data/dsh/dshruntime"
with zipfile.ZipFile(whl) as z:
    for info in z.infolist():
        mode = (info.external_attr >> 16) & 0o777
        if mode and os.path.isfile(os.path.join(base, info.filename)):
            os.chmod(os.path.join(base, info.filename), mode)
rt = os.path.join(base, "deepseek_harness_runtime", "runtime")
if os.path.isdir(rt):
    for root, dirs, files in os.walk(rt):
        for name in files:
            os.chmod(os.path.join(root, name), 0o755)
print("exec bits fixed")
PY

# 2) 版本核验（预期：0.1.5-rc.2）
DSH_HOME=/data/dsh/dsh-data/test03 PYTHONPATH=/data/dsh/dshruntime \
  python3 -c 'from deepseek_harness_runtime import main; main()' --version
```

> `$DSH_HOME/profiles/node_modules` 下的模块回退代理由启动时按新版本自动重建，无需手工清理。

## 4. 启动与验收

```bash
# 1) 启动
systemctl --user start dsh-web-test03
systemctl --user status dsh-web-test03        # 预期 active (running)
ss -lntp | grep 7103                          # 预期 127.0.0.1:7103 LISTEN

# 2) 抓新 token（重启后 token 会变）
grep -o 'token=[A-Za-z0-9_-]*' /data/dsh/dsh-logs/dsh-web-test03.log | tail -1
```

```bash
# 3) 本机验证 boot 图非空（核心验收项）
TOKEN=$(grep -o 'token=[A-Za-z0-9_-]*' /data/dsh/dsh-logs/dsh-web-test03.log | tail -1 | cut -d= -f2)
curl -s -c /tmp/dsh-jar -H "Host: test03.dsh.internal" \
  "http://127.0.0.1:8088/?token=$TOKEN" -o /dev/null
curl -s -b /tmp/dsh-jar -H "Host: test03.dsh.internal" http://127.0.0.1:8088/ \
  | grep -o 'plugins/??@deepseek-ai/dsh-client-modules/client.js' | head -1
```

判定标准：

- **预期**：命中 `plugins/??@deepseek-ai/dsh-client-modules/client.js`（HTML 预载了 bootstrap 批次）
- **若仍是旧症状**：页面 `__DSH_BOOT__` 为 `{"rev":"240c4d8dcf0d","entries":[],"batches":[]}`（空图特征哈希），说明升级未生效

```bash
# 4) 浏览器验收（用户机 hosts 指向 10.218.174.161）
#    打开 http://test03.dsh.internal:8088/?token=<新token>
#    预期：登录后完整渲染（左侧会话树、会话页、设置页），控制台无
#    "Failed to load plugins client-modules" 报错
```

## 5. 回滚（如需）

```bash
systemctl --user stop dsh-web-test03
rm -rf /data/dsh/dshruntime/deepseek_harness_runtime/runtime
mv /data/dsh/dshruntime/deepseek_harness_runtime/runtime.rc1.bak \
   /data/dsh/dshruntime/deepseek_harness_runtime/runtime
systemctl --user start dsh-web-test03
```

（回滚后以日志最新 token 为准重新分发。）
