# DSH 方案 B 部署手册：每人一实例 + 反代认证分流（内网泛子域直达）

> 本文对应《DSH企业部署架构选型指南.md》**§5.2 方案 B**，是其**唯一被展开到可执行程度**的
> 方案；通用要点见该指南附录 B。

> **定位**：本文是《DSH 企业部署架构选型指南》§5.2 B 架构（每人一实例 + 反代）在
> **纯内网、零基础**环境下的逐步执行手册——接入方式为**泛子域直达**
> （`https://<账号>.dsh.internal`）。每步含命令与验证，按序执行即可交付。
>
> **版本锚定**：DSH `0.1.5-rc.2`（commit `c291e7961a`）；**部署制品锚定
> `deepseek-harness-runtime-bin==0.1.5rc1`**（官方 PyPI 平台 wheel，自包含，见选型指南 §5.8）。
> 机制性事实（F 编号）引用自选型指南 §2，本手册不重复论证。
>
> **2026-09-10 修订**：① 离线制品由「npm 打包 + 内网装 Node」改为官方 runtime wheel
> （服务器零 Node/npm/pnpm 依赖）；② 修正实例端口/authority 的注入方式；
> ③ 补 `--trusted-host`（漏配则页面能开、`/api` 全 403）；④ 修正 token 抓取命令。

## 0. 目标架构与参数决策

```
员工浏览器 ── https://zhangsan.dsh.internal ──→
        ┌─────────────────────────────┐
        │ 反代 Nginx（443，泛证书）      │  ← 信任自建根 CA
        └──────────────┬──────────────┘
                       │ 按子域查 map
        ┌──────────────┼──────────────┐
        ▼              ▼             ▼
   dsh-web@zhangsan dsh-web@lisi  …（systemd 模板，绑 127.0.0.1:71xx）
   DSH_HOME=/srv/dsh/<账号>         运行时一份 /usr/local/bin/dsh（§6 的 wheel）
   每实例必须带 --trusted-host <账号>.dsh.internal  ← 漏配则 /api 全 403（选型指南 F2b）
        │
        └──→ LLM 出口（见 §9 决策）
```

**开工前定死的参数**（下文以这些值示例，**实际部署时必须替换为你的真实环境参数**）：

| 参数 | 示例值 | 说明 |
| --- | --- | --- |
| 内网域名 | `dsh.internal` | 私有域；若公司持有真实公网域，可改用 `dsh.<公司域>`（split DNS） |
| 服务器 IP | `10.0.0.15` | **示例 IP**，替换为你的内网主服务器实际 IP。此服务器承载 DNS + 反代 + 全部实例（起步单机） |
| 服务器 OS | BigCloud Enterprise Linux For Euler 21.10 LTS（x86_64） | 其他 systemd 发行版等价。**必须 glibc ≥ 2.28**（manylinux_2_28 下限），部署前用 `ldd --version` 确认 |
| 实例端口段 | `7100 + 序号`（7101、7102…） | 只绑 127.0.0.1 |
| **实例 authority** | `<账号>.dsh.internal` | **每个实例一个**，必须经 `--trusted-host` 声明（选型指南 F2b），否则 `/api` 403 |
| 子域规则 | OA 账号规范化（附录 A） | `[a-z0-9-]` |
| 根证书有效期 | 10 年；服务证书 825 天 | 825 天上限兼容 iPhone 访问 |

**前置条件 checklist**：

- [ ] 一台内网服务器（起步规格 2C/4GB/40GB SSD，人数增长按选型指南 §9.1 扩）
- [ ] 一台**可出公网**的跳板机（下载制品用，仅此用途）
- [ ] 首批员工账号清单（≤5 人试点）
- [ ] LLM 出口路径已确认（§9 的三选一）

## 1. 阶段一：服务器基础初始化

```bash
# NTP（token/cookie 生命周期依赖时钟，F2）
yum install -y chrony && systemctl enable --now chronyd

# fd 上限（每用户 WebSocket 长连接）
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/dsh-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=65535
EOF

# 专用用户与目录布局
useradd -r -m -d /var/lib/dsh -s /usr/sbin/nologin dsh
mkdir -p /srv/dsh /srv/dsh-work /etc/dsh/tls /etc/dsh/instances
chown -R dsh:dsh /srv/dsh /srv/dsh-work
chmod 700 /srv/dsh
```

**验证**：`chronyc tracking` 显示同步；`su - dsh -s /bin/sh -c 'ulimit -n'` ≥ 65535（重登录后）。

## 2. 阶段二：离线制品准备（跳板机，可出公网）

纯内网服务器不执行任何下载。在跳板机准备**两样**制品，拷入内网（U 盘/内网传输）：

```bash
mkdir -p artifacts && cd artifacts

# ① DSH 运行时（官方 PyPI 平台 wheel）
#    自包含单文件可执行程序：内含 Node 运行时 + 全部依赖闭包 + 完整 Web 前端产物。
#    服务器侧【不需要】Node / npm / pnpm / 任何构建工具链。
pip download deepseek-harness-runtime-bin==0.1.5rc1 \
  --only-binary=:all: \
  --platform manylinux_2_28_x86_64 \
  --python-version 3.11 \
  --no-deps -d .
# → deepseek_harness_runtime_bin-0.1.5rc1-py3-none-manylinux_2_28_x86_64.whl
#   （arm64 机器改用 --platform manylinux_2_28_aarch64）

# ② Nginx（主线版 RPM，匹配 EulerOS/RHEL/CentOS 系）
curl -fLO https://nginx.org/packages/mainline/centos/8/x86_64/RPMS/nginx-1.27.4-1.el8.ngx.x86_64.rpm
```

拷贝 `deepseek_harness_runtime_bin-*.whl` 与 `nginx-*.rpm` **两件**进内网服务器 `/root/staging/`。

> **wheel 到底是什么？** 格式原理、文件名标签解码、与 jar / fat jar / jpackage 的类比、
> 以及 Node 生态为什么缺这一环，见选型指南 **附录 D**。本手册只讲怎么用。
>
> **版本对齐提醒**：wheel 只随正式 tag 发布，可能落后于仓库 master。本手册锚定
> `0.1.5rc1`（对应 tag `dsh-v0.1.5-rc.1`）。换版本时把上面的版本号与文件名一并更新，
> 并按选型指南 §10 复核前提事实是否失效。
>
> **没有 pip 的跳板机**：可直接从 PyPI 取 wheel 链接——
> `curl -s https://pypi.org/pypi/deepseek-harness-runtime-bin/json`，
> 在 `releases["0.1.5rc1"]` 中选 `manylinux_2_28_x86_64` 那条的 `url` 下载。
>
> **为什么不再下载 Node**：旧版手册要求装 Node v22.14.0，但 DSH 的引擎下限是
> **`^22.19.0 || >=24.0.0`**（根 `package.json:8-10`），22.14 并不满足。改用 wheel 后
> 这个问题连同整棵 npm 依赖树的内网同步一起消失了。
>
> **制品画像**（便于 U 盘/内网传输估算）：Linux x86_64 wheel 约 **77MB**；`requires_python`
> 为 `>=3.10`；wheel 名是 `py3-none-<平台>` 形式，且**无任何 Python 依赖**
> （`requires_dist` 为空），因此服务器侧 `--no-index` 本地安装不会去解析任何依赖。
> 跳板机上 `--python-version` 填 3.10 及以上均可（它只影响 tag 校验，不影响内容）。

## 3. 阶段三：内网 DNS 泛解析（dnsmasq）

一条泛记录覆盖所有子域，**增减员工零 DNS 操作**：

```bash
yum install -y dnsmasq
cat >> /etc/dnsmasq.d/dsh.conf <<'EOF'
address=/.dsh.internal/10.0.0.15   # 替换为你的内网主服务器实际 IP
EOF
systemctl enable --now dnsmasq
```

- 公司**已有**内网 DNS：改为在现有 DNS 上加同等泛记录/条件转发（把 `dsh.internal` 转给本机 dnsmasq），不要双 DNS 并存。
- 员工电脑的 DNS 必须指向这套 DNS（DHCP 下发或手工配）。

**验证**（员工网段任一机器）：`nslookup zhangsan.dsh.internal` → `10.0.0.15`（应返回你配置的实际 IP）；
随手编一个 `nslookup whatever.dsh.internal` 也应返回同一 IP（泛解析生效）。

## 4. 阶段四：自建根 CA 与泛证书（OpenSSL，服务器上执行）

纯内网无公共 CA 可用，自建单层根 CA（起步够用；规模化时再加中间层）：

```bash
cd /etc/dsh/tls

# ① 根 CA（10 年）—— 私钥离线保存，不留在本机
openssl genrsa -out dsh-root-ca.key 4096
openssl req -x509 -new -key dsh-root-ca.key -sha256 -days 3650 \
  -out dsh-root-ca.crt -subj "/CN=DSH Internal Root CA/O=Corp"

# ② 服务私钥 + CSR
openssl genrsa -out dsh-wildcard.key 2048
openssl req -new -key dsh-wildcard.key \
  -out dsh-wildcard.csr -subj "/CN=*.dsh.internal"

# ③ 签泛证书：SAN 必须同时含通配符与裸域（通配符只匹配一层！门户/健康检查用裸域）
openssl x509 -req -in dsh-wildcard.csr \
  -CA dsh-root-ca.crt -CAkey dsh-root-ca.key -CAcreateserial \
  -days 825 -sha256 -out dsh-wildcard.crt \
  -extfile <(printf "subjectAltName=DNS:*.dsh.internal,DNS:dsh.internal\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")

# ④ 收尾：保护私钥，备份根 CA
chmod 600 dsh-wildcard.key dsh-root-ca.key
cat dsh-wildcard.crt dsh-root-ca.crt > fullchain.crt   # 供反代使用
# dsh-root-ca.key 移出服务器妥善保管（签新证书时才需要）
```

**验证**：`openssl x509 -in dsh-wildcard.crt -noout -text | grep -A1 "Subject Alternative"` 应列出两个 DNS。

## 5. 阶段五：根证书信任分发

| 对象 | 操作 |
| --- | --- |
| 本服务器 | `cp dsh-root-ca.crt /etc/pki/ca-trust/source/anchors/ && update-ca-trust` |
| Windows 域环境 | 根证书导入 AD 组策略：`gpedit → 计算机配置 → Windows 设置 → 安全设置 → 公钥策略 → 受信任的根证书颁发机构` |
| Windows 非域 | 管理员执行 `certutil -addstore Root dsh-root-ca.crt`（或门户/共享盘提供下载 + 操作指引） |
| macOS | 钥匙串访问 → 系统钥匙串 → 导入 → 双击设"始终信任" |
| 手机（BYOD） | 邮件发送 .crt 附件安装并信任；MDM 可统一下发 |

> 分发成本是自建 CA 的固定运维项：**每台员工设备只需装这一次根证书**（泛证书续期无需重发，见 §12）。

## 6. 阶段六：安装 DSH 运行时与 Nginx（内网服务器）

```bash
cd /root/staging

# ① 平台检查：manylinux_2_28 wheel 要求 glibc ≥ 2.28
ldd --version | head -1

# ② DSH 运行时（自包含单文件，无需 Node / npm / pnpm / 构建工具链）
#    该 wheel 无任何 Python 依赖，本地安装即可，不会联网解析依赖
pip install ./deepseek_harness_runtime_bin-0.1.5rc1-py3-none-manylinux_2_28_x86_64.whl

# 若服务器无 pip：wheel 本质是 zip，直接解包取二进制亦可
#   unzip -q deepseek_harness_runtime_bin-*.whl -d /opt/dshruntime
#   ln -sf /opt/dshruntime/deepseek_harness_runtime/runtime/deepseek-harness-sdk-runtime-linux-x64 \
#          /usr/local/bin/dsh
#   ⚠ 同目录的 -rg sidecar 必须一起保留，只拷主程序会启动失败

# ③ 验证（控制台命令强制要求非空 DSH_HOME，缺失即退出码 2）
DSH_HOME=/tmp/dsh-check dsh --version && rm -rf /tmp/dsh-check

# ④ Nginx（RPM）
yum localinstall -y nginx-1.27.4-1.el8.ngx.x86_64.rpm
nginx -v   # 验证
```

> **wheel 的两个边界**（详见选型指南 §5.8）：
> ① `dsh plugin --profile <n> …` **仍然需要 pnpm 在 PATH 上**——内网无法动态安装树外插件，
> 插件必须在跳板机预先打好、随 profile 预置；
> ② 控制台命令**绝不回退 `~/.dsh`**，`DSH_HOME` 必须显式提供（§7 的 systemd 单元已给）。

## 7. 阶段七：systemd 模板与首批实例

**建号脚本** `/usr/local/sbin/dsh-adduser`（账号→子域规范化见附录 A）：

```bash
#!/bin/bash
set -euo pipefail
USER="$1"; PORT="$2"; DOMAIN="${3:-dsh.internal}"   # 例：dsh-adduser zhangsan 7101
HOMED=/srv/dsh/$USER; WORKD=/srv/dsh-work/$USER

mkdir -p "$HOMED" "$WORKD" /etc/dsh/instances
chown -R dsh:dsh "$HOMED" "$WORKD"
chmod 700 "$HOMED"

# 实例参数：端口 + 该实例的 authority。
# authority 必须进 --trusted-host，否则反代转发真实 Host 后 /api 一律 403。
cat > "/etc/dsh/instances/$USER.env" <<EOF
DSH_PORT=$PORT
DSH_AUTHORITY=$USER.$DOMAIN
EOF
chmod 600 "/etc/dsh/instances/$USER.env"

echo "$USER $PORT $USER.$DOMAIN $HOMED $WORKD" >> /etc/dsh/instances.tab   # 实例注册表
systemctl enable --now dsh-web@$USER
```

**模板单元** `/etc/systemd/system/dsh-web@.service`：

```ini
[Service]
User=dsh
EnvironmentFile=/etc/dsh/instances/%i.env
Environment=DSH_HOME=/srv/dsh/%i
WorkingDirectory=/srv/dsh-work/%i
# --trusted-host 是【可变参数】(<authority...>)，必须放在最后，否则会吞掉后续参数
ExecStart=/usr/local/bin/dsh web --port ${DSH_PORT} --trusted-host ${DSH_AUTHORITY}
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

> **为什么不用 `$DSH_HOME/profile.d/webserver.yaml`**：**这个机制不存在**——DSH 从不扫描
> `profile.d`。DSH 的配置层只有三处（`packages/boot/app-boot/src/profile.ts:42-45`、
> `apps/cli/src/profile-boot.ts:73-74`）：bundle 自带 patch → 逐 profile 的
> `$DSH_HOME/profiles/<name>/cordis.patch.yml` → **home 级 `$DSH_HOME/cordis.patch.yml`**
> → `--patch <path>`。
>
> 即便写到正确路径，patch 也必须写成 `- id: webserver`（**非 insert 条目必须带 `id`**，
> 否则被静默跳过）且**重述全部 5 个键**——patch 是**整块替换 `config`，不做深合并**。
> 更麻烦的是这样会**丢掉 `port: !!js ctx.webStartup.port ?? 3080` 这个表达式**，
> 从此 `--port` 失效。**所以端口用命令行 flag 给，不要用 patch。**

```bash
dsh-adduser zhangsan 7101
dsh-adduser lisi 7102
```

**验证**：`ss -tlnp | grep 710`——每个端口**只**出现在 `127.0.0.1:` 上；`systemctl status dsh-web@zhangsan` 为 running。

## 8. 阶段八：Nginx 反代（泛证书 + 子域路由）

`/etc/nginx/conf.d/dsh.conf`：

```nginx
# 子域名 → 后端端口映射表（与 /etc/dsh/instances.tab 保持同步）
map $host $backend {
    zhangsan.dsh.internal 127.0.0.1:7101;
    lisi.dsh.internal     127.0.0.1:7102;
    default               "";
}

# 仅在确实是 WebSocket 升级时才发 Connection: upgrade，
# 否则会污染普通请求与 /plugins/events 的 SSE 长连接
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    server_name *.dsh.internal dsh.internal;

    # 泛证书配置
    ssl_certificate     /etc/dsh/tls/fullchain.crt;
    ssl_certificate_key /etc/dsh/tls/dsh-wildcard.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    if ($backend = "") {
        return 404;                        # 未注册子域
    }

    location / {
        proxy_pass http://$backend;
        proxy_http_version 1.1;            # WebSocket 必须走 HTTP/1.1

        # 【必须原样透传 Host】DSH 的 cookie 名与签名载荷均由 Host 派生，
        # 改写 Host 会直接掉登录；且该 authority 必须已在 --trusted-host 中声明，
        # 否则 /api 会在认证之前返回 403（页面能开、一发消息就失败）
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # 【必须关闭缓冲】/plugins/events 是 SSE，开启缓冲会导致事件收不到
        proxy_buffering off;

        # 下面两个 DSH 并不解析（无转发头适配），保留仅为兼容其他中间件；
        # 不要据此推断任何 DSH 侧行为
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # WebSocket 由服务端每 2s ping 维持（连丢 2 个心跳约 4~6s 即断开），
        # 连接几乎不会空闲——真正的约束是控制帧必须能往返，不是空闲超时
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

```bash
# 测试配置
nginx -t

# 启动或重载 Nginx
systemctl enable nginx
systemctl restart nginx
```

> 增减员工 = 改 `map` 表 + 建号脚本（§7）各一行，`nginx -s reload` 生效。

**验证**（员工机，已装根证书）：`curl -I https://zhangsan.dsh.internal` 返回 401（DSH 认证层拦下，反代与 TLS 全通）；`curl -I https://nobody.dsh.internal` 返回 404。

> ⚠️ **注意这个 401 不能作为「通过」的依据**：`/` 走的是静态回退路径，**不经过
> `/api` 信任围栏**。围栏只在 `/api` 与 WebSocket 升级上生效，且失败时返回的是 **403**
> 而不是 401。所以即便 `--trusted-host` 漏配，本步**照样返回 401**——必须按 §11 用
> 「发消息能收到回复」来确认。

## 9. 阶段九：LLM 出口决策与配置

纯内网服务器的模型流量必须有一条出口，三选一：

| 方案 | 适用 | 配置 |
| --- | --- | --- |
| ① 服务器白名单直连 | 有安全审批的出口通道 | 实例环境仅设 `DEEPSEEK_API_KEY`（key 集中在 §10 的 EnvironmentFile） |
| ② 走企业代理 | 已有统一代理 | 全局 `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`（DSH 遵循，F19） |
| ③ 网关/自建推理 | 合规要求 key 不出管理面或用内部模型 | 各实例 profile 统一 `DEEPSEEK_BASE_URL` 指向网关（F12） |

**密钥文件**（不入版本库、权限收紧）：

```bash
cat > /etc/dsh/llm.env <<'EOF'
DEEPSEEK_API_KEY=sk-xxxxxxxx
EOF
chmod 600 /etc/dsh/llm.env && chown root:dsh /etc/dsh/llm.env
# 模板单元 [Service] 段再追加一行（systemd 允许并列多个 EnvironmentFile）：
#   EnvironmentFile=/etc/dsh/llm.env
systemctl daemon-reload && systemctl restart 'dsh-web@*'
```

## 10. 阶段十：launch token 首登下发（0.1.2+，F2）

实例启动时会打印一次**带 token 的启动 URL**（journal 可见）。进程**打印的是回环地址**：

```
dsh web: http://127.0.0.1:7101/?token=<43 位 base64url>
```

代码中该 host 是硬编码的 `127.0.0.1`，**不含公网域名**。因此抓取后必须**手工把 authority
换成公网域名**再发给员工：

```bash
# 抓取指定实例当前进程的 token URL
journalctl -u dsh-web@zhangsan --no-pager \
  | grep -o 'http://127\.0\.0\.1:[0-9]*/?token=[A-Za-z0-9_-]*' | tail -1
# 输出示例：http://127.0.0.1:7101/?token=AbC…xyz
# 改写为：  https://zhangsan.dsh.internal/?token=AbC…xyz   ← 这一步不能省
```

把改写后的完整 URL 经 IM/邮件发给张三。他打开后换取 cookie → 之后 30 天直接访问干净域名即可。

> **token 是进程级、可重复兑换的**（并非"一次性"，也**不会**"用过即废"）。同一 token 在
> 该进程存活期内可无限次换取 cookie，只有**重启才作废**。这意味着 journal 里出现过的
> token 等同密码——请收紧 `journalctl` 读权限，不要把整段 journal 外发。

**运维规则速记**（详见选型指南附录 B.3）：

| 场景 | 处置 |
| --- | --- |
| 实例重启 | **无需**重发 token（未过期 cookie 跨重启有效，签名密钥是落盘的 secret） |
| 员工换浏览器/清 cookie/超 30 天 | 重新执行上面抓取命令，**改写 authority 后**发新 URL |
| 员工离职/设备丢失 | 删 `/srv/dsh/<账号>/.credentials.yaml` 的 **`records:` 段**中 `client-connection/browser-session` 条目，**然后重启该实例**（不重启不生效——secret 每次启动只读一次）；再加停 SSO 账号 |
| 从门户/IM 点链接跳进来撞 401 | cookie 是 `SameSite=Strict`，跨站深链**不携带 cookie**。引导员工用书签或直接输域名访问 |

## 11. 验收清单

**基础设施**：

- [ ] `ldd --version` ≥ 2.28（manylinux_2_28 前提）
- [ ] 任意编造的子域 `dig x.dsh.internal` → 10.0.0.15（泛解析）
- [ ] 员工机浏览器访问 `https://zhangsan.dsh.internal` 无证书告警（根 CA 信任 OK）
- [ ] `nmap -p 7101 10.0.0.15` 外部不可达（实例只绑回环）
- [ ] `ss -tlnp` 确认每个实例端口**只**监听 `127.0.0.1`

**功能与隔离**：

- [ ] token 首登后进入会话界面
- [ ] **【关键】在界面里真的发一条消息并收到模型回复** —— 这一步才验证 `/api` 通过了信任
      围栏（即 `--trusted-host` 配置正确）。只看到界面**不算通过**（选型指南 F2b）
- [ ] 浏览器开发者工具 Network 面板中**无 403** 响应
- [ ] 张三界面建会话产出文件 → 落在服务器 `/srv/dsh-work/zhangsan/`（F3，产出在服务器）
- [ ] 李四登录后看不到张三的任何会话/附件/凭据（F1 隔离）
      —— 注意这是**应用层**隔离；OS 层同用户不隔离，见选型指南 §9.2
- [ ] `systemctl stop dsh-web@zhangsan && systemctl start dsh-web@zhangsan`，张三刷新后历史会话完整（F4 落盘恢复）
- [ ] 重启实例后张三不掉线（cookie 跨重启）

**安全**：

- [ ] 服务器上 `grep -r sk- /srv/dsh/` 无明文 key 泄漏（key 在 EnvironmentFile/网关）
- [ ] `/srv/dsh` 权限 700、属主 dsh
- [ ] `journalctl -u dsh-web@*` 读权限已收紧（内含等同密码的 launch token）
- [ ] `/etc/dsh/instances/*.env` 权限 600
- [ ] 已按威胁模型决策是否分层隔离实例 UID（选型指南 §9.2）

## 12. 日常运维

**建号/销号**：

```bash
dsh-adduser wangwu 7103 && vi /etc/nginx/conf.d/dsh.conf   # map 加一行
nginx -s reload && <抓 token 发给员工>

# 销号：停实例 → 归档两目录 → 注销路由与实例参数
systemctl disable --now dsh-web@wangwu
tar czf /backup/dsh-wangwu-$(date +%F).tgz /srv/dsh/wangwu /srv/dsh-work/wangwu
rm -rf /srv/dsh/wangwu /srv/dsh-work/wangwu      # 确认归档后再删
rm -f /etc/dsh/instances/wangwu.env              # 别漏：实例参数文件
sed -i '/^wangwu /d' /etc/dsh/instances.tab
# 再从 nginx map 删掉 wangwu 行并 nginx -s reload
```

**备份**（每日 cron）：`/srv/dsh`（会话+凭据+设置）+ `/srv/dsh-work`（产出）+ `/etc/dsh`（注册表/证书）+ `/etc/nginx/conf.d/dsh.conf`（路由配置）。

**证书续期**：泛证书到期前（825 天），用**离线保管的根 CA key** 重跑 §4 的 ②③ 步、重组 fullchain、`nginx -s reload`。根证书 10 年一换（换根 = 全员设备重装，见 §5）。

**监控**：内存（第一瓶颈）、`dsh-web@*` 与 `nginx` 存活、磁盘增速（附件放开后重点，F8）、证书有效期告警（到期前 30 天）。

**扩容路线**：人数到数百 → 按选型指南 §5.3 加 hub 做按需回收（C 架构），或按 §9.1 分片加机器；token 抓取逻辑平移进 hub 即可。

## 13. 故障排查速查

| 症状 | 首查 |
| --- | --- |
| **页面能打开，但一发消息就失败** | **头号故障**：`/api` 信任围栏 403。检查该实例 `--trusted-host` 是否等于浏览器地址栏的 authority（选型指南 F2b）；DevTools Network 里找 403 |
| **所有实例都监听 3080 / 第二个实例起不来** | 端口注入未生效：确认用的是 `--port` flag 而非 patch 文件；`systemctl show dsh-web@<账号> -p EnvironmentFile` 看 env 是否加载 |
| `--trusted-host` 之后的参数丢失 | 它是**可变参数**，必须放在 `ExecStart` 最后 |
| 域名解析失败 | 员工机 DNS 是否指向内网 DNS；`dnsmasq` 存活；泛记录拼写 |
| 证书告警 | 设备是否装根证书（§5）；证书 SAN 是否含访问的域名形态 |
| 404（子域） | Nginx `map` 表没这个账号；reload 了吗 |
| 401 反复 | token 流程：抓的 URL 是否对应**当前**进程（重启后旧 token 已废）；cookie 是否被清；是否从门户跨站深链进来（`SameSite=Strict` 不带 cookie） |
| 页面通了但无回复 | 先排除上面的 403；再查 LLM 出口（§9）：代理变量、key 有效性、网关可达性 |
| 登录后突然掉线 | 是否换了子域/加了端口——cookie 绑定 `Host`；是否重启后删了 `.credentials.yaml` 的 browser-session 记录 |
| 实例起不来 | `journalctl -u dsh-web@<账号>`；端口冲突（`ss -tlnp`）；DSH_HOME 权限；**是否漏了 `-rg` sidecar**（用解包方式安装时） |
| 启动报 `DSH_HOME` 相关错误 | 控制台命令要求非空 `DSH_HOME`，绝不回退 `~/.dsh` |
| 打开会话极慢 | 磁盘是否 SSD；是否误把 DSH_HOME 放 NFSv3（F4 写租约失效） |
| 502 Bad Gateway | 后端实例是否运行；端口映射是否正确；`journalctl -u dsh-web@<账号>` 查日志 |
| SSE/实时更新不工作 | Nginx 是否漏了 `proxy_buffering off`（`/plugins/events` 是 SSE） |

## 附录 A. 账号→子域规范化规则

1. 转小写；`.` `_` 等转 `-`；只保留 `[a-z0-9-]`，其余删除；
2. 中文账号建议直接用工号（`e00123`）；
3. 规范化后冲突 → 追加序号（`wangwu2`）；
4. 子域即账号：`dsh-adduser <规范化账号> <端口>`，注册表 `/etc/dsh/instances.tab` 是唯一事实源。

## 附录 B. 离线制品清单（跳板机核对单）

| 制品 | 来源 | 用途 |
| --- | --- | --- |
| `deepseek_harness_runtime_bin-0.1.5rc1-py3-none-manylinux_2_28_x86_64.whl` | PyPI（跳板机 `pip download`） | §6 DSH 运行时（自包含，**无 Node 依赖**） |
| `nginx-1.27.4-1.el8.ngx.x86_64.rpm` | nginx.org | §8 反代 |
| `dsh-root-ca.crt` | §4 产出 | §5 全员分发 |

> 不再需要 Node.js 与 npm 依赖包——这两项已并入 runtime wheel。

## 附录 C. 升级 DSH 版本

跳板机下载新版本 wheel → 内网 `pip install --no-index <新 wheel>`（覆盖安装，运行时是一份共享代码，**不需要逐个实例操作**）→ `systemctl restart 'dsh-web@*'` → 按选型指南 §10 复核前提事实是否失效（pre-release 无兼容承诺）。

**升级前必做**：全量备份 `/srv/dsh`。当前 Session 格式为 **v3**，旧 v0/v1/v2 日志会经
**不可变相邻 generation 迁移**——迁移是重编码而非复制，但**低代日志不会自动删除**
（"Nothing deletes session files"），因此额外磁盘占用是**永久性**的（F20）。升级前按存量
会话体积预留空间，并把「人工清理旧 generation」写进运维流程（seam 不提供删除 API）。
