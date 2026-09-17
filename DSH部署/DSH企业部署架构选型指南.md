# DSH 企业部署架构选型指南

> **版本锚定声明**：本指南的全部结论仅对第 2 节登记的 DSH 版本负责。DSH 处于 pre-release
> 阶段（无兼容性承诺），未来迭代后请按第 10 节的方法复核，失效章节即更新。
>
> 本文区分三类陈述：**原生支持**（DSH 当前版本自带）、**需自建**（部署方补齐的平台层）、
> **硬限制**（当前版本做不到、选型时必须绕开的）。

## 1. 文档目的与适用范围

写给负责评估与部署 DSH 的架构师、运维负责人，回答两个问题：各规模下推荐哪种部署架构；
每种架构需要自建什么、绕开什么。不覆盖单机个人使用（直接 `dsh web` 即可）。

## 2. 版本登记

| 项 | 值 |
| --- | --- |
| DSH 版本 | `0.1.5-rc.2`（仓库 master） |
| 登记 commit | `c291e7961a`（master） |
| 登记日期 | 2026-09-10（对 `b0a7d2ce3b`/0.1.3-alpha.2 版全面复核后更新） |
| 状态 | pre-release：格式与接口随时可能变更，无兼容承诺（AGENTS.md "Pre-release stance"） |

> **制品锚定**：内网部署实际安装的是官方发布的 **`deepseek-harness-runtime-bin`** 平台
> wheel（自包含可执行程序，见 §5.8）。wheel **只随正式 tag 发布**，因此它的版本可能落后
> 于 master：截至本文登记时 PyPI 最新为 `0.1.5rc1`（对应 tag `dsh-v0.1.5-rc.1`），而
> master 已到 `0.1.5-rc.2`。**部署时以 wheel 的实际版本为准**，并用第 10 节方法复核。

### 前提事实清单（本指南结论的依赖，逐条附出处）

| # | 事实 | 出处 | 影响 |
| --- | --- | --- | --- |
| F1 | host 进程按**单用户**设计：匿名身份，无账号/租户体系 | `packages/identity/anonymous-user-id` | 多人隔离必须靠部署层 |
| F2 | webserver 包本身**无 TLS、无 origin 策略**；但 composition 层已对**全部 Host API** 要求浏览器会话：进程启动生成**进程级** launch token（启动 URL 携带，进程存活期内可重复兑换，**非一次性**），`GET /?token=…` 换签名 cookie（30 天、`HttpOnly`/`SameSite=Strict`、绑定 `Host` 规范化后的 host+port）；CLI 仍拒绝 `--host 0.0.0.0`，且**不解析任何转发头**（官方口径：认证≠支持网络部署） | `packages/host/webserver/README.md`、`.agents/notes/implemented/architecture/2026-08-24-browser-token-authentication.md`、`packages/client/connection/src/browser-auth.ts` | 反代/门户须把带 token 的启动 URL 下发给员工；SSO 与 DSH cookie 是叠加关系 |
| F2b | **反代部署的强制前置**：`/api` 信任围栏要求请求 `Host` 要么是 loopback、要么在 `trustedHosts` 中，否则**先于认证返回 403**。`trustedHosts` 只由 `--trusted-host <authority>` 与 all-interface 绑定推导出的 LAN 字面量组成 | `packages/client/connection/src/api-request-trust.ts`、`packages/client/connection/src/rpc-host.ts`、`packages/bundle/web-app/cordis.patch.yml:181-188` | **不传 `--trusted-host`，页面能打开但所有 `/api` 调用 403，应用完全不可用**——每位用户一个 authority，建号时必须写入 |
| F3 | 浏览器只是遥控器：**所有文件读写发生在服务器**（`fs-local` 在 host 进程执行） | `packages/fs/README.md` | 员工本机文件不可见，产出留在服务器 |
| F4 | 会话持久化在磁盘，**仅 JSONL 后端**（一会话一个追加式 `.jsonl.**zstd**`；SQLite 后端已移除）；实际路径 `$DSH_HOME/sessions/--<cwd-slug>--/<encoded-id>/session.v3.jsonl.zstd`，**多代（v0/v1/v2/v3）并存**；写入经 `SessionHandle` 单写者持有，并有**跨进程内核级写租约**（POSIX `flock`/Windows 命名信号量；持有者进程死亡即自动释放，崩溃者不阻塞后继）；**进程可随时回收重启** | `packages/session/session-persistence/README.md`、`packages/session/session-persistence-jsonl/README.md`、`.agents/notes/implemented/feature/2026-08-31-cross-process-session-write-lease.md` | 弹性调度的根基；租约在 NFSv3 上不可靠（见 §5.4） |
| F5 | 会话 cwd 创建时定死于 `SessionHeader`，不可变 | `docs/subsystems/persistence.md` | 工作目录随会话而非随人 |
| F6 | 沙箱 `workspace-write` 围栏 = **会话 cwd 根 + temp 根**，与工作区实体无关 | `packages/fs/fs-sandbox/README.md` | 读写隔离按 cwd 划界 |
| F7 | 工作区（GUI 分组实体）仅 web bundle 挂载；headless/ACP 无此概念；工作区是目录的登记记录，不是权限或存储边界 | `packages/bundle/web-app/cordis.patch.yml`、`docs/subsystems/workspace.md` | 权限与隔离不依赖工作区 |
| F8 | 附件上传支持**图片 + 任意类型文件**（通用文件逐字节落盘、无准入限制；图片才走校验/压缩管线）。两者落点不同：图片 `attachments/v1/objects/<sha256-prefix>/<sha256>`，通用文件 `attachments/v1/file-objects/<digest-prefix>/<digest>`，引用路径是 `attachments/v1/files/…` 下的只读硬链接 | `packages/attachment/attachment-local/README.md` | 文档素材可直接上传；`DSH_HOME` 容量按新对象类型重估 |
| F9 | 远程 Web **无产出文件下载/预览通道**。文件 chip 在远端**照常可用**（点击会调 Host 在**服务器上**打开文件，对远端用户无意义）；只有「在文件夹中显示」被 loopback 门控。历史上做过 `/f/<sessionId>/…` HTTP 通道且可用，被**主动裁掉**（"不为非 Host 机器的客户端提供预览"是明示的排除项） | `packages/client/ui-deliverables/README.md`、`.agents/notes/implemented/**/2026-07-31-web-workspace-file-links.md` | 取回产出需自建设施（SFTP/共享盘/门户） |
| F10 | `DSH_HOME` 解析：显式配置 → `$DSH_HOME` → `~/.dsh` | `packages/util/home-paths` | 每实例一 HOME 的隔离手段 |
| F11 | 技能 = 文件，**六级**发现根，按 rank 覆盖：100 `<项目>/.dsh/skills`、200 `<项目>/.agents/skills`、300 `customSkillDirs`、400 `$DSH_HOME/skills`、500 `$DSH_AGENTS_HOME`(默认 `~/.agents`)/skills、600 bundledSkillDir | `packages/skill/skill-filesystem/README.md` | 技能复用走文件共享；`customSkillDirs` 只是路径数组，**`watch` 是 provider 级开关（默认已 true）**，不能按目录单独开关 |
| F12 | LLM 凭据经 `DEEPSEEK_API_KEY` + 可选 `DEEPSEEK_BASE_URL` | 根 `AGENTS.md` | 可指企业网关集中管 key |
| F13 | headless bundle 不含 storage/workspace 插件；SDK/Headless/ACP 默认工具集自 0.1.3-alpha.2 起含 read/write/edit 文件编辑（Web minimal 不变） | `packages/bundle/headless/cordis.patch.yml`、`.agents/notes/implemented/feature/2026-09-05-base-default-file-editor.md` | 引擎模式实例极轻；默认即有写文件能力，沙箱档位须显式决策 |
| F14 | 远程绑定/SSH/无显示器时目录选择自动切 `-browse`（浏览器内浏览**服务器**目录树） | `packages/host/directory-picker-auto/README.md` | 远程选目录可用，但列的是服务器文件系统 |
| F15 | E2B 远程执行世界为 POC | `packages/e2b` | 不作为生产选项 |
| F16 | LLM 凭据为记录制：`api-key`（key 本体或 env 名引用）与 `grant`（登录令牌）按 `CredentialKey`（`<plugin>/<id>`）寻址落凭据 seam；交互式登录（授权流程）把提示发给**发起请求的页面**，headless 无人可问即拒绝 | `packages/credentials/README.md`、`packages/credentials/authorization/README.md` | 登录态单实例私有；集中管 key 仍走 F12 |
| F17 | 工具执行鉴权三件套：`ctx.approval` 一次性审批、`ctx.permissionPresets` 预设（打包 `sandbox/mode` + `approval/policy`，默认 `workspace-write`+`ask` 与 `danger-full-access`+`never`，**会话创建时钉死**）、沙箱执行模式围栏 | `packages/interaction/permission-presets/README.md`、`packages/fs/fs-sandbox/README.md` | 进程内软授权：防误操作够，防恶意绕过需容器 |
| F18 | ask-user：`ctx.userQuestions` 单 provider 问答 seam + 模型侧 `tool-ask-user` 工具（三套 agent preset 均挂载）；授权登录的提问**不复用**该 seam | `packages/interaction/user-questions/README.md`、`apps/cli/config/agent-presets/` | headless 下问答落拒绝，任务须自含答案 |
| F19 | 主进程出站请求遵循启动环境的 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/`NO_PROXY`（大小写均可）。**刻意例外**：OTel 遥测、workflow worker、code-runtime worker **不经代理**；无法解析的 scheme（如 SOCKS）报错后**退回直连** | `.agents/notes/implemented/architecture/2026-08-27-outbound-proxy-policy.md` | 第二条企业出口管控路径，但**有盲区**——做出口管控时不能假定全覆盖 |
| F20 | Session 格式当前为 **v3**（`SESSION_FORMAT_VERSION = 3`）：旧 v0/v1/v2 日志经**不可变相邻 generation** 迁移（原文件不改写、新旧并存，是**重编码**而非复制）；助手流按 attempt 聚合持久化 | `packages/core/session/src/types.ts`、`.agents/notes/implemented/architecture/2026-08-31-released-session-format-migrations.md` | **低代日志永不自动删除**（"Nothing deletes session files"）——迁移带来的额外占用是**永久性**的，不是阶段性，容量须按此预留 |

## 3. 核心结论速览

| 规模 | 推荐架构 | 需自建 | 详见 |
| --- | --- | --- | --- |
| <10 人，互信小团队 | A. 单实例共享 | 反代（可选） | §5.1 |
| 几十~几百人 | B. 每人一实例 + 反代认证分流 | 反代 + SSO、systemd 模板 | §5.2 |
| 数百~数千人 | C. B + 按需启动/空闲回收 | 调度器（hub + spawner） | §5.3 |
| 数千~万人，人均重度使用 | D. K8s 集群 + 数据目录外置 | K8s 平台、持久存储 | §5.4 |
| **万人级主力推荐** | E. 引擎模式（每任务一 headless 进程 + 企业门户） | 多租户门户、任务队列 | §5.5 |

> 共同底座：无论哪种架构，**反代认证与 LLM 网关必建**，且 0.1.2+ 起须解决 launch token
> 的下发（F2、F12）。**任何经反代访问的形态（B/C/D）还必须为每个 authority 传
> `--trusted-host`**，否则 `/api` 一律 403（F2b）——这是 B 架构能否跑通的开关，不是可选项。
> 共享层设计见 §6。

## 4. 架构决策依据（当前版本关键事实展开）

### 4.1 单用户边界

一个 host 进程 = 一份会话列表、工作区列表、设置、凭据（F1）。多人连同一实例互相可见、
共用同一把 key——多人使用必须以"实例"为单位划分，而非"登录账号"。

### 4.2 进程是"牲畜"，数据在盘上

实例 = **进程 + DSH_HOME + 回环端口**，代码一份只读共享（不是每人一份源码）。会话、
工作区记录、附件全部落盘在 `DSH_HOME`（F4、F10），进程随时可杀、可迁、可重建——
这是 C/D/E 三种弹性架构成立的前提。0.1.3 起会话写入有跨进程内核级租约（F4）：
持有者崩溃即自动释放、不阻塞后继进程——"牲畜化"比 0.1.1 时代更安全。

### 4.3 文件位置（全部在服务器，F3）

| 内容 | 位置 |
| --- | --- |
| 会话工作文件（产出） | 会话 cwd（如 `/srv/dsh-work/<user>/`） |
| 上传附件（图片 + 任意文件，F8） | `$DSH_HOME/attachments/v1/objects/<sha256…>` |
| 会话日志（一会话一个追加式 `.jsonl.zstd`，多代并存） | `$DSH_HOME/sessions/--<cwd-slug>--/<encoded-id>/` |
| 工作区记录 | `$DSH_HOME/storages/` |

升级注意（F20）：旧格式会话在迁移期间以相邻 generation 重编码并存，**且低代日志不会被
自动回收**——额外占用是永久性的。升级前须按存量会话体积预留空间，并把「人工清理旧
generation」写进运维流程（seam 本身不提供删除 API）。

### 4.4 读写权限的边界

沙箱围栏按**会话 cwd** 划界（F6）：workspace-write 模式下会话只能写自己 cwd 根与 temp。
同实例多会话靠不同 cwd 分目录互不写入；但这是进程内软围栏，非 OS 级隔离。

### 4.5 隔离强度决策（部署前必须做的一次选择）

**DSH 没有任何账号体系。** `packages/identity/` 下只有一个包 `anonymous-user-id`，其 README
明确写着 "one anonymous identifier per harness home... **Do not use it to identify a user**"。
全仓搜索 `tenant` / `multi-user` / 账号概念——零命中。因此：

> **DSH 的身份粒度就是"实例"（一个进程 + 一个 `DSH_HOME`）。**
> **人与人之间的数据隔离，只能靠"一人一实例"实现。**

#### 4.5.1 "一人一实例"买到的是哪一层隔离

这是最容易被误判的地方——**它只解决应用层**：

| 隔离层 | 一人一实例能否解决 | 说明 |
| --- | --- | --- |
| **应用层**（UI 里看不看得见） | ✅ **能** | 各自独立 `DSH_HOME`：会话、附件、设置、凭据互不可见 |
| **OS 层**（同机进程能否读到对方文件） | ❌ **不能** | 默认所有实例同一系统用户；**同 UID 下文件权限不构成边界** |
| **内核层**（沙箱） | ❌ **不能** | `workspace-write` 是**进程内软围栏**（F6/F17），只约束本会话 cwd |

#### 4.5.2 威胁模型：两个问题决定选哪一档

| 问题 | 是 | 否 |
| --- | --- | --- |
| **Q1** 员工之间只需"互不干扰、互不误看"？ | 应用层隔离**足够**，可停在此处 | 见 Q2 |
| **Q2** agent 可能接触**不可信内容**？（外部邮件 / 网页 / 他人上传的文档） | **必须**上 OS 级隔离 | 应用层隔离足够 |

**为什么 Q2 是分水岭**：agent 会执行**模型生成的 bash 命令**。若会话上下文混入不可信内容
（提示注入），模型可能被诱导读取同机其他目录——此时唯一的边界就是**文件系统权限**。
这不是理论担忧，而是"agent 能跑任意命令"这一设计的直接推论。

#### 4.5.3 三档落地变体

| 档位 | 做法 | 改动量 | 隔离强度 |
| --- | --- | --- | --- |
| **① 同 UID（默认）** | 所有实例 `User=dsh` | 零 | 应用层 |
| **② 按用户分 UID** | 建号时 `useradd <账号>`；单元改 `User=%i`；各 `DSH_HOME` 700 | **小**（建号脚本 +1 行） | 应用层 + OS 层 |
| **③ 一人一容器** | 每实例一容器，独立 mount namespace | **大**（需自撰 Dockerfile，仓库零容器产物） | 应用层 + OS 层 + 内核层 |

> **推荐**：绝大多数企业选 **②**——改动极小、收益明确，且不引入容器那套额外运维。
> 只有企业已有 K8s 平台、或明确要求内核级隔离时才上 ③（即 §5.4 的 D 架构）。

#### 4.5.4 与之相关的既有边界

- 实例内**无用户概念**：拿到 token/cookie 的人即拥有该实例**全部**会话（F2）；
- `DSH_HOME` 全部落盘于服务器（F3），**备份即等于备份全部员工数据，备份介质需按同等密级管理**；
- 产出落在各会话 cwd（如 `/srv/dsh-work/<账号>/`），档位 ② 下同样受 UID 保护。

## 5. 部署架构选项与适用场景

### 5.1 A. 单实例小团队共享

```
 员工浏览器 ×N ──→ [反代(建议)] ──→ dsh web (0.0.0.0 或 loopback+反代)
                                      DSH_HOME=/srv/dsh/shared
                                      工作目录 /srv/dsh-work/<人>/
```

- **适用**：<10 人、互信、可接受互相看到会话列表。
- **不适用**：任何有隐私/合规要求的场景。
- 要点：靠 per-person cwd + 沙箱围栏防互写；API key 共用；零额外设施。

### 5.2 B. 每人一实例 + 反代认证分流（code-server 模式）

```
                 员工浏览器
                     │ https://<用户>.dsh.corp.com        ← 对外仅 443
                     ▼
        ┌───────────────────────────────┐
        │  反向代理：TLS + SSO 认证 +     │   ← 需自建（F2）
        │  按子域名分流                   │
        └───────────────┬───────────────┘
        ┌───────────────┼────────────────┐
        ▼               ▼                ▼
   dsh-web@张三     dsh-web@李四      dsh-web@王五     ← systemd 模板单元
   127.0.0.1:7101   127.0.0.1:7102   127.0.0.1:7103     绑回环，不出网
   DSH_HOME=/srv/dsh/<用户>                              代码一份共享
```

- **适用**：几十~几百人；想要完整 Web GUI 体验。
- **不适用**：万人（单机内存先于端口成为瓶颈，见 §9）。
- **能力边界（选型前必读 §4.5）**：本方案提供**应用层**隔离（各自 `DSH_HOME`，UI 互不可见），
  **不提供 OS 级隔离**——默认所有实例以同一系统用户运行。若 agent 可能接触不可信内容
  （§4.5.2 的 Q2），必须叠加 §4.5.3 的档位 ②（按用户分 UID）或 ③（容器），否则隔离强度
  只有"防误看"，达不到"防攻击"。
- 要点：实例绑 loopback、数据各自 `DSH_HOME`（完整部署步骤见附录 B）；子域名路由优于路径路由。
- **每实例必须传 `--trusted-host <该实例的 authority>`（F2b）**：反代转发真实 `Host`
  （`zhangsan.dsh.internal`）后，该 Host 既非 loopback 也不在 `trustedHosts` 中，`/api`
  会在认证之前**返回 403**——表现为「页面能打开、一发消息就失败」。这是 B 架构最易踩的坑。
- **0.1.2+ 新增流程（F2）**：实例启动 URL 携带 **token（打印在进程输出）**，员工浏览器
  首次访问必须经这个带 token 的 URL 换 cookie（30 天有效）；token 重启即换新——systemd
  模板需捕获启动输出中的 token URL 并分发给对应员工。注意两点：① token 是**进程级**的，
  进程存活期内**可重复兑换**，因此能读 journal 的人即可获得完整 GUI 访问权，日志权限需收紧；
  ② 进程打印的是 **`http://127.0.0.1:<port>/?token=…`**（代码中该 host 是硬编码的），
  **不含公网域名**，下发前必须手工改写成 `https://<用户>.dsh.corp.com/?token=…`。

### 5.3 C. B + 按需启动/空闲回收（JupyterHub 模式）

在 B 之上加一个**调度器**：用户首次访问时由 hub 拉起他的实例，空闲 N 分钟自动回收。
按同时在线率 <10% 的常见假设，数千员工常驻实例数降至数百。

- **适用**：数百~数千人、全员用 Web GUI。
- 需自建：hub（认证后拉起/回收 systemd 单元或容器）、空闲探测、**捕获各实例启动输出中的
  token URL 并随跳转下发**（F2：用户须以带 token 的入口完成首次认证）。
- 依赖 F4：实例被回收后用户再访问时重新拉起，历史会话从盘上恢复。

### 5.4 D. K8s 集群 + 数据目录外置

```
  Ingress(认证) ──→ K8s Service ──→ Pod: dsh-web@<用户> （按需/常驻）
                                        │ DSH_HOME → NFS/PVC
                                        ▼
                              集中存储（会话/存储/附件）
```

- **适用**：数千~万人、人均重度使用 Web GUI；需要多节点分摊与故障自愈。
- 需自建：K8s 平台、持久存储、每用户 Namespace/配额。
- 收益：实例升级/迁移不停数据；按节点池横向扩容。
- **存储选型硬约束（F4）**：会话写租约依赖 advisory `flock`，**NFSv3 上不可靠**（退化为
  仅进程内排除，多 Pod 共享 `DSH_HOME` 时有日志撕裂风险）——外置存储避开 NFSv3，
  选 NFSv4+ / 块存储 PVC / 本地盘。

### 5.5 E. 引擎模式（万人级主力推荐）

不给每人常驻 GUI，员工在企业自建门户提交任务，后端**每个任务拉起一个 headless 实例，
跑完即退**：

```
 员工 ──→ 企业门户(多租户/审批/审计) ──→ 任务队列
                                          │ 每任务一进程
                                          ▼
                              dsh --profile headless "任务"     ← F13：极轻，
                              DSH_HOME=<任务/用户卷>               无 storage/workspace
                                          │
                              产出落服务器目录 → 门户取回/推送
```

- **适用**：万人级；任务型使用（生成简历、月度总结等"提交-取回"流）。
- 需自建：多租户门户、任务队列与调度、产出取回通道（补 F9）。
- 0.1.2+ 变化：任意文件上传（F8）使"文档素材预置服务器目录"降为可选；默认工具集含
  read/write/edit（F13）——引擎模式下沙箱档位（默认 `workspace-write`，F17）成为
  必须显式决策的第一道闸门。
- 为什么主力推荐：多租户、认证、审计全部由门户层承担（DSH 不必做账号体系）；进程生命周期
  = 任务生命周期，弹性最大；每实例内存开销只存在于任务期间。
- 集成面：headless CLI，或 JSON-RPC/SDK（`packages/sdk`）做进程内集成。

### 5.6 F. E2B 远程执行世界（登记，不推荐生产）

文件系统与子进程可切换到 E2B 远程沙箱（每会话独立执行世界），当前为 POC（F15），仅作
技术储备登记。

### 5.7 G. Electron 桌面应用（客户端形态登记，非服务器架构）

0.1.2 系列引入：复用 Web UI 的 Electron 壳，自带捆绑 Node.js + pnpm（员工机器零运行时
依赖），独占保留 profile `.dsh/profiles/desktop`，与 npm 安装的 CLI **共享 `.dsh` 数据根、
不共享可执行包与插件激活**（两条升级线独立）；一个 Desktop 版本号锁定 Electron + dsh 后端
精确组合，更新走事务化 staging/rollback；资产经 `dsh-app://` 协议分发，**不开放监听端口**
（`nodeIntegration: false` + `contextIsolation` + `sandbox`）。适用于企业桌面分发（免配
Node 环境），不改变本章服务器侧架构结论。

出处：`.agents/notes/implemented/architecture/2026-08-25-electron-desktop-packaging-and-updates.md`

### 5.8 部署制品：内网自包含二进制（runtime wheel）

**这是内网/离线部署的推荐制品，取代「上传源码在服务器上构建」。**

官方在 PyPI 发布平台 wheel **`deepseek-harness-runtime-bin`**，它把 `dsh` CLI 与**整棵
Node 依赖闭包**打成一个**单文件原生可执行程序**，并内置 Web 前端产物：

```bash
pip install deepseek-harness-runtime-bin     # 得到 /usr/local/bin/dsh
```

| 项 | 事实 | 出处 |
| --- | --- | --- |
| 内含 | Node 运行时 + 全部依赖 + **完整 web profile 前端资产** | `python/sdk-runtime/README.md` |
| 服务器前置 | **不需要 Node / npm / pnpm / 构建工具链**；只需 glibc ≥ 2.28（manylinux_2_28） | `python/sdk-runtime/platforms.json` |
| 已发布平台 | Linux x64/arm64、macOS x64/arm64、Windows x64 | 同上 |
| 制品体积 | Linux x86_64 wheel ≈ **77MB**（PyPI 单文件上限 100MB） | PyPI `0.1.5rc1` |
| 依赖 | **无 Python 依赖**（`requires_dist` 为空），`requires_python >= 3.10`；可用 `--no-index` 纯离线安装 | 同上 |
| 可执行文件 | `<site-packages>/deepseek_harness_runtime/runtime/deepseek-harness-sdk-runtime-linux-x64`，**必须与同目录 `-rg` sidecar 一起存在** | `python/sdk-runtime/src/deepseek_harness_runtime/__init__.py` |
| `DSH_HOME` | 控制台命令**强制要求非空 `DSH_HOME`，绝不回退 `~/.dsh`**（缺失即退出码 2） | 同上 |
| 限制 | `dsh plugin --profile <n> …` 仍**需要 pnpm 在 PATH 上**（普通运行不需要）——内网动态装插件走不通，插件须随 profile 预置 | `python/sdk-runtime/README.md` |

**为什么推荐它**：单文件、离线可搬运、服务器零运行时依赖、升级 = 换一个 wheel 文件；
相比「服务器上 `pnpm install && pnpm run build`」少了整条构建工具链和 251 个 npm 包的
内网同步难题（见 §9.2）。

**口径说明**：该 wheel 的定位是 Python SDK 的运行时载体，但官方 README 明确声明两个
carrier「执行同一套 dsh 命令语法与随附 profile，包括完整的 web profile 及其前端资产」，
因此用于 B/C/D 架构的实例托管是成立的。若企业另有内网 npm 源，`npx @deepseek-ai/dsh web`
（官方文档化的安装方式）同样可用，两者机制完全一致。

## 6. 共享层设计（一人创造、多人复用）

| 共享物 | 通道 | 说明 |
| --- | --- | --- |
| **技能**（首选，§6.1） | 文件 + git | 技能即 `SKILL.md` 文件（F11） |
| 插件（能力级代码） | 私有 npm registry | `dsh plugin add @company/dsh-xxx` 装入各 profile |
| LLM 凭据 | 企业网关 | 实例只配 `DEEPSEEK_BASE_URL`，key 集中在网关（F12） |
| 出站网络管控 | 环境代理变量 | 实例遵循 `HTTP_PROXY`/`NO_PROXY` 等（F19），LLM 网关之外的出口管控补充 |
| profile 组装模板 | git + 配置管理下发 | 保证全员组装一致 |

### 6.1 技能复用三通道

1. **项目级**：技能放 repo 的 `.dsh/skills/` 或 `.agents/skills/`，随代码 review、版本化——
   在该项目干活的任何实例自动发现；
2. **企业技能库**：独立 `company-skills` 仓库检出到共享路径，各实例 profile 给
   `skill-filesystem` 配 `customSkillDirs: [/srv/shared/company-skills]`（`watch: true`
   热加载，新技能免重启生效）；
3. **跨工具约定**：`~/.agents/skills`（`$DSH_AGENTS_HOME`）可指向同一共享库。

## 7. 认证与鉴权能力现状

"认证与鉴权"在当前版本分布在三个互不相干的平面上，选型时最容易混淆，逐面澄清：

### 7.1 LLM 提供商凭据平面（进程向外：DSH 怎么拿到模型服务的钥匙）

| 机制 | 说明 |
| --- | --- |
| 凭据记录 | 两种形态：`api-key`（存 key 本体或 env 名引用）、`grant`（OAuth 等登录令牌）；按 `CredentialKey`（`<plugin>/<id>`）寻址，落 `$DSH_HOME`（F16） |
| 授权流程（`ctx.authorization`） | 有些凭据"配不出来、只能登录取得"（如 `llm-pi-ai` 系 provider 的账号登录）：流程把"去浏览器继续 / 粘贴验证码"类提示发给**发起登录的那个页面**——交互随请求走，无全局注册表；流程自己完成凭据写入 |
| headless 行为 | 无人可问 → 交互直接拒绝（attempt 落 cancelled），不会挂起等待（F16） |

**部署含义**：登录态是**单实例私有**的（记录在各自 `DSH_HOME`，F1/F10）——B/C/D 架构下每实例各自登录一次；企业要集中管控，仍以 F12（env / 网关）优先，交互式登录只作补充。

### 7.2 工具执行鉴权平面（模型向内：DSH 怎么约束模型的行为）

| 机制 | 服务 | 说明 |
| --- | --- | --- |
| 一次性审批 | `ctx.approval`（user-approval） | 高危操作弹允许/拒绝，一次一事 |
| 权限预设 | `ctx.permissionPresets`（permission-presets） | 把 `sandbox/mode` + `approval/policy` 打包成用户可选档位；默认档 `workspace-write`（= workspace-write + ask）与 `danger-full-access`（= danger-full-access + never）；选择在**会话创建时钉死**，改设置只影响后续会话（F17） |
| 沙箱围栏 | sandbox 家族 | read-only / workspace-write / danger-full-access 执行模式；围栏按会话 cwd 划界（F6） |

**部署含义**：全部是**进程内策略**——防"模型误操作"足够；防"恶意会话蓄意绕过"需容器级隔离（§8）。

### 7.3 ask-user 能力（人机问答通道）

- **模型侧**：提问工具 `tool-ask-user`（三套 agent preset 均挂载，F18），模型可暂停任务、向人提一个问题、等回答后再继续；
- **服务侧**：`ctx.userQuestions` 是 provider 中立的问答 seam——一个 context 只有一个活跃 UI provider，问题发过去、答案等回来；
- **与授权的关系**：授权登录的提问**刻意不复用**这条 seam（生命周期不同：无 agent 上下文、必须送达发起页、可被浏览器回调撤销），走 §7.1 的独立交互通道；
- **部署含义**：引擎模式（E）下无人在场 → ask-user 与授权流程一样落拒绝。任务 prompt 须自含决策信息，或由门户预先收集答案注入。

### 7.4 Web 层用户认证：有进程级浏览器认证，无账号体系（F2 修订）

以上全是"DSH 进程自己"的认证与鉴权，**不是**浏览器用户的账号体系。0.1.2 起 composition
层对**全部 Host API**（RPC/WebSocket/Fetch）要求浏览器会话：进程启动生成 **launch
token**（打印于进程输出、随启动 URL 下发，形如 `http://127.0.0.1:<port>/?token=…`），
`GET /?token=…` 换签名 cookie（30 天、`HttpOnly`/`SameSite=Strict`、绑定 `Host` 规范化后的
host+port）；token 不落盘、重启即换新，**但在进程存活期内可重复兑换**（非一次性）。
删除 `$DSH_HOME/.credentials.yaml` 的 `records:` 段中 `client-connection/browser-session`
条目**并重启进程**可吊销全部 cookie（不重启不生效：签名 secret 每次启动只读一次）。
另需注意 `/api` 另有**信任围栏**，要求 `Host` 为 loopback 或在 `trustedHosts` 中，
否则 403——见 F2b。这同时修复了
旧版可伪造 `Host: localhost` 头冒充本地调用读取凭据的漏洞。

这是**进程级凭证**而非多用户身份——Web 层仍是匿名单用户，多用户隔离照旧靠 §5 的实例
划分与反代/门户；但 B/C/D 架构的首次访问流程因此多一步"下发启动 URL"（§5.2/§5.3）。
注意官方口径：**认证≠支持网络部署**——无 TLS、无转发头解释、无反代适配（含
forward_auth 类机制），SSO 层与 DSH cookie 层是叠加而非互替。

## 8. 安全边界与当前版本已知限制

| 限制 | 性质 | 对策 |
| --- | --- | --- |
| 无 TLS/账号体系/origin（F2 修订） | 硬限制 | 反代/VPN 强制；`0.0.0.0` 裸绑禁止；已有进程级 token+cookie 认证，但**不解析任何转发头**，且反代场景**必须显式传 `--trusted-host`**（F2b），与 SSO 叠加而非互替 |
| 无多租户（F1） | 硬限制 | 按架构 §5 划分实例；万人走门户 |
| 远程无产出下载（F9） | 硬限制 | SFTP/共享盘/门户取回通道 |
| 进程间软隔离 | 设计现状 | 强隔离需求上容器/VM；官方 SAFETY.md 明示未做安全审计、沙箱/审批/权限不保证隔离，可作立项依据直接引用 |
| 沙箱围栏为进程内策略（F6） | 设计现状 | 防"会话间误写"足够；防恶意绕过需容器 |
| 会话并发写入：session 级租约已内建（F4 修订） | 设计现状 | 同一会话跨进程互斥（`SessionAlreadyOwnedError`，内核级）；`DSH_HOME` 其余数据（settings/storages/凭据）并发语义未声明，仍建议一 HOME 一进程 |
| 会话写租约在 NFSv3 上失效 | 硬限制 | 外置存储选 NFSv4+/块存储/本地盘（§5.4） |
| 反代必须声明 authority（F2b） | 硬限制 | 每实例 `--trusted-host <用户>.dsh.internal`；漏配 = 页面能开、`/api` 全 403 |
| 实例间无 OS 级隔离 | 设计现状 | 默认全部实例同一系统用户，「用户间不可见」仅**应用层**成立。需真实隔离则按用户分 UID 或上容器（§9.2） |
| launch token 进程级可重复兑换（F2） | 设计现状 | token 打印进 journal/stdout，进程存活期内**可反复换取 cookie**；收紧 journal 读权限，按「等同密码」对待，重启才作废 |
| cookie `SameSite=Strict` 且无 `Secure` | 设计现状 | 从 SSO 门户/IM 的**跨站深链**跳转不携带 cookie → 撞 401；引导员工用书签或直接输域名。`Secure` 缺失是因为官方假设 loopback HTTP，反代场景由 TLS 层补足 |

## 9. 规模推演（容量方法）

- **端口不是第一瓶颈**：对外仅 443，实例端口全在回环；单机真正先撞墙的是内存与 fd。
- **内存**：每 Node 实例工程估算 100~300MB → 单机 2 万常驻实例需 2~6TB，不可行；
  常驻规模按 `单机内存 × 0.7 / 300MB` 估。
- **并发率**：按同时在线 <10% 估算常驻实例数（C/D 架构）；引擎模式（E）按任务 QPS ×
  平均任务时长估算峰值进程数。
- **升级预留（F20）**：Session 格式 v2 迁移以不可变相邻 generation 复制旧日志，升级后
  磁盘占用阶段性接近翻倍，旧 generation 回收前需按存量会话体积预留空间。
- 人数超过数百即应离开单机（B→C/D/E）。

### 9.1 硬件配置速查（工程估算）

> **口径声明**：DSH 官方未发布硬件基准。本节按 §9 方法论（每实例 100~300MB）+
> `b0a7d2ce3b` 代码复核推算，属工程估算——上线前建议以真实负载压测校准（0.1.2 系列
> 做了大量内存/启动优化，实际占用可能低于区间上限）。
>
> **2026-09-10 说明**：本次对 `c291e7961a`（0.1.5-rc.2）复核了**机制性事实**（认证、围栏、
> 配置层、session 租约均未变），但**未重新测量内存/启动开销**——本节数字仍来自
> `b0a7d2ce3b` 推算，请按上式自行压测校准。

**资源单元画像**：

| 资源单元 | 内存 | CPU | 依据 |
| --- | --- | --- | --- |
| Web GUI 实例（A/B/C/D） | 150~300MB 工作集；长会话/图片压缩峰值可冲 500MB+ | 空闲≈0；活跃低个位数 %；启动与日志 zstd 压缩有瞬时毛刺 | §9 方法论 |
| headless 任务进程（E） | 80~150MB | 任务期间 5~15%（随子进程负载） | F13 极轻 |
| 反代 + hub/spawner | 50~500MB | 1~2 核 | — |
| 内存可用系数 | 按**总内存 × 0.7** 规划实例（留 OS + 页缓存） | — | §9 |

**分方式配置**：

| 方式 | 规模 | 推荐配置 | 磁盘 |
| --- | --- | --- | --- |
| A 单实例 | <10 人 | 2C/4GB/40GB SSD（最低）；2C/8GB/100GB（舒适） | 随附件量 |
| B 每人一实例 | 50 人 | 8C/32GB/200GB SSD | 人均 2GB/年起 |
| | 100 人 | 16C/64GB/500GB SSD | 同上 |
| | 200 人 | **拆 2×(16C/64GB)**，反代按子域分片 | 各 500GB |
| C 按需回收 | 500 人（~50 常驻） | 8C/32GB/1TB SSD | 全员会话留存 + v2 迁移翻倍预留（F20）+ 附件配额 |
| | 1000 人（~100 常驻） | 16C/64GB/2TB SSD | 同上 |
| | 3000 人（~300 常驻） | 2×(16C/96~128GB/2TB) + hub 4C/8GB | 同上 |
| D K8s | Pod 规格 | request 512Mi/limit 1Gi 内存；request 100m/limit 1 CPU | PVC 每用户 10~20Gi 起 |
| | worker 节点 | 通用型 16C/64GB，每节点 ~100 GUI Pod | **必须共享存储**（附件随 `DSH_HOME` 走 PVC，attachment-local 明确存储本机私有）；NFSv4+/块存储，**禁 NFSv3**（F4） |
| | 万级（峰值在线 1000） | ~10 worker + 3 管理面节点 | Ingress 开 WebSocket + session affinity |
| E 引擎模式 | 门户+队列 | 8C/16GB/200GB | 常规 Web 服务 |
| | worker 池 | 例：1000 人×日均 10 任务×均时 2 分钟，峰值并发 ~300 → 2×(16C/64GB/500GB SSD 任务卷) | 按队列深度自动伸缩 |
| G 桌面 | 员工机 | 8GB 内存起（Electron 壳+捆绑 Node 合计 ~500MB） | — |
| LLM 网关（全员必建） | 纯转发+key 管理 | 2C/4GB | — |
| | 加审计/限流 | 4C/8GB | — |

**公式速查**：B 内存 ≥ 人数×300MB÷0.7+2GB；C 内存 ≥ 人数×10%（同时在线率）×300MB÷0.7+4GB；
E worker 内存 ≥ 峰值并发任务×150MB÷0.7。

**通用工程注意事项**：

1. **SSD 必须**：会话日志 append + zstd 压缩是常态 IO；
2. **fd 上限调高**：每用户 WebSocket 长连接 + 文件句柄，`ulimit -n` ≥ 65535；
3. **备份对象**：`DSH_HOME`（会话+凭据+设置）+ 各会话 cwd（产出）——两者均在服务器侧（F3）；
4. **时钟同步**：token/cookie 生命周期依赖时间判断（F2），NTP 必配；
5. **容量复核节奏**：v2 迁移翻倍（F20）+ 附件放开（F8）后，磁盘是最先需重估的资源；
6. **拉起风暴**（C）：集中登录时批量拉起实例会排队，hub 需限速（如每秒 ≤5 个）。

### 9.2 制品获取方式对比（内网落地用）

| 方式 | 服务器需 Node/npm | 服务器需构建工具链 | 需内网 npm 源 | 官方提供该制品 | 升级成本 |
| --- | --- | --- | --- | --- | --- |
| 上传源码，服务器构建 | **要**（Node ≥22.19 + pnpm 11.7.0） | **要**（TS + tsdown + Vite + devDeps） | **要**（251 包闭包） | — | 每次全量重建 |
| 自建镜像 → 导入 → 容器启动 | 否 | 否 | 构建期要 | **否**（仓库零 Dockerfile/Helm） | 重建 + 导入镜像 |
| **runtime wheel（推荐，§5.8）** | **否** | **否** | **否** | **是**（PyPI 已发布） | **换一个 wheel 文件** |

**选型结论**：A/B 架构用 wheel + systemd 模板；到 C/D 架构（按需拉起、K8s）时容器才成为
首选，届时仍需自撰 Dockerfile——项目不提供容器产物。

> **容器方案的真实价值**：不在于打包，而在于**隔离**。本文所有实例默认以同一个 `dsh`
> 系统用户运行，「用户间不可见」只在**应用层**成立（各自独立 `DSH_HOME`），**OS 层不成立**
> ——任一实例进程可读其他所有实例的 `DSH_HOME`。若企业的威胁模型包含「员工 A 的 agent
> 攻击员工 B 的数据」，必须改为**按用户分 UID**（每实例一个系统用户）或上容器，见 §8。

## 10. 版本演进时的复核方法

DSH 新版本发布后，逐条复核 §2 前提事实清单（F1~F20）：到对应包的 README/源码确认事实
是否仍成立；某条失效时，引用它的章节（本表"影响"列）即需重写。版本号变更本身不使本指南
失效——只有前提事实变化才失效。

> **复核记录**
> - 2026-09-10：对 `c291e7961a`（0.1.5-rc.2）全面复核——逐条核验部署相关机制，**主进程
>   认证/围栏/配置层/session 租约均未变**，故架构结论 A~E 不变。修订项：**新增 F2b**
>   （反代必须声明 `--trusted-host`，漏配则 `/api` 全 403——本轮最重要的发现）；F2 更正
>   launch token 为**进程级可重复兑换**（非一次性）并补打印 URL 实为 `127.0.0.1`；
>   F4 更新为 **v3 格式、`.jsonl.zstd`、多代并存**；F8 区分图片/通用文件落点；F9 更正为
>   「chip 远端可用，缺的是下载/预览通道」；F11 补第六级根与 `watch` 语义；F19 补
>   **刻意例外**（遥测/workflow/code-runtime 不走代理）；F20 更正为 **v3 + 占用永久化**。
>   新增 §5.8（runtime wheel 自包含部署制品）、§9.2（制品获取方式对比）、§8 新增四行
>   限制；附录 B 安装方式改为 wheel、systemd 补 `--trusted-host`、修正 token 抓取命令、
>   补反代四条硬性要求。**版本锚定本身已更新**（见 §2）。
> - 2026-09-10（补充）：新增 **§4.5 隔离强度决策**（应用层 vs OS 层、威胁模型两问、
>   提示注入路径、同 UID / 分 UID / 容器三档变体），并在 §5.2 正文补入方案 B 的能力边界；
>   新增 **附录 C 技术栈速览**（TypeScript / Node / Python 关系与技术全景）、
>   **附录 D runtime wheel 格式科普**。同时方案 B 的执行手册已更名为
>   《DSH方案B-每人一实例+反代-内网泛子域部署手册.md》，使文件名体现所展开的方案。
> - 2026-09-08：对 `b0a7d2ce3b`（0.1.3-alpha.2）全面复核——F4（仅 JSONL + 写租约）、
>   F8（任意文件上传）失效已重写；F2 修订（进程级 token+cookie 认证，无反代适配）；
>   F13 补充默认工具集变化；新增 F19（出站代理）、F20（v2 迁移容量）；新增 §5.7 桌面
>   形态登记；新增 §9.1 硬件配置速查（工程估算口径，待实测校准）；附录 B 扩充为
>   B 架构完整部署手册（架构分层、八步部署、token 运维、常见坑、验收清单）。
>   架构结论 A~E 未变。
> - 2026-08-26：初版登记（`b150a551b8`，0.1.1-rc.2）。

## 附录 A. 术语表

| 术语 | 含义 |
| --- | --- |
| 实例 | 一个 dsh 进程 + 一个 `DSH_HOME` + 一个回环端口；代码共享 |
| `DSH_HOME` | 实例数据根（会话/存储/附件/设置/Profile）；env 可覆写（F10） |
| cwd | 进程当前工作目录；会话 cwd 创建时定死（F5），沙箱与相对路径的锚点 |
| 工作区 | GUI 里对目录的登记记录（分组导航用），仅 web bundle；不是权限边界（F7） |
| Profile | 插件 bundle 的有序堆叠 + 用户 patch 层，决定实例装配形态 |
| 技能 | `SKILL.md` 文件形式的可复用指令，由五级根发现（F11） |
| 凭据记录 | LLM 凭据条目：`api-key`（key 本体或 env 名）或 `grant`（登录令牌），按 `CredentialKey` 寻址，存于 `$DSH_HOME`（F16） |
| 授权流程 | 交互式 provider 登录（`ctx.authorization`）：提示发给发起页，流程内完成凭据写入（F16） |
| ask-user | 模型经 `tool-ask-user` 暂停并向人提问、等待回答再继续的能力（F18） |
| launch token | 进程启动生成的浏览器认证令牌：随启动 URL 下发，`GET /?token=…` 换 cookie。**不落盘、重启即换新，但在进程存活期内可重复兑换**（非一次性），视为等同密码（F2） |
| trustedHosts | `/api` 信任围栏接受的额外 authority 列表；来源为 `--trusted-host` 与 all-interface 绑定的 LAN 字面量。Host 既非 loopback 又不在其中即 403（F2b） |
| runtime wheel | `deepseek-harness-runtime-bin`（PyPI）：含 Node 运行时与全部依赖的单文件原生可执行程序，内网离线部署制品（§5.8） |
| SessionHandle | 会话持久化的单写者句柄：承载该会话全部日志读写并持有跨进程内核级写租约（F4） |

## 附录 B. B 架构部署手册（每人一实例 + 反代）

> **纯内网、零基础起步**的逐步执行版（含自建 CA、离线制品、内网 DNS 泛解析）见
> 《DSH方案B-每人一实例+反代-内网泛子域部署手册.md》；本附录为通用部署要点。

### B.1 架构与职责

```
                     员工浏览器
                         │ https://zhangsan.dsh.corp.com     ← 对外仅 443
                         ▼
        ┌────────────────────────────────┐
        │  反向代理（TLS + SSO + 子域分流） │  ← 自建①
        └───────────────┬────────────────┘
        ┌───────────────┼────────────────┐
        ▼               ▼                ▼
   dsh-web@张三     dsh-web@李四      dsh-web@王五     ← systemd 模板实例
   127.0.0.1:7101   127.0.0.1:7102   127.0.0.1:7103      绑回环，不出网
   DSH_HOME=/srv/dsh/<用户>                              数据各自隔离
                                              运行时一份共享 /usr/local/bin/dsh（§5.8 wheel）
        所有实例 ────→ LLM 网关（DEEPSEEK_BASE_URL）      ← 自建②
```

| 层 | 组件 | 职责 |
| --- | --- | --- |
| 接入层 | 反代（Caddy/nginx）+ 企业 SSO | TLS 终结、员工身份认证、子域→实例路由 |
| 实例层 | 每人一个 `dsh web` 进程 | 单用户完整 GUI；绑回环，不出网 |
| 数据层 | 每人一个 `DSH_HOME` + 会话 cwd | 会话/凭据/设置按人隔离；产出在服务器（F3） |
| 出口层 | LLM 网关 | key 集中管控、审计、限流（F12）；`HTTP_PROXY` 出口管控补充（F19） |

### B.2 部署步骤

1. **基础设施**：服务器（50 人：8C/32GB/200GB SSD，§9.1；200 人拆 2 台按子域分片）；
   泛域名 `*.dsh.corp.com` + 企业证书；`ulimit -n ≥ 65535`（WebSocket 长连接）；NTP
   校时（token/cookie 依赖时钟，F2）。
2. **安装共享代码**（§5.8 的自包含二进制，服务器无需 Node/npm/pnpm）：
   ```bash
   pip install deepseek-harness-runtime-bin     # 得到 /usr/local/bin/dsh
   dsh --help                                   # 验证（需非空 DSH_HOME，见下）
   mkdir -p /etc/dsh/instances
   for u in zhangsan lisi; do
     mkdir -p /srv/dsh/$u /srv/dsh-work/$u      # 每人一个 DSH_HOME + 一个会话 cwd
     chown -R dsh:dsh /srv/dsh/$u /srv/dsh-work/$u
   done
   ```
3. **systemd 模板单元**（`/etc/systemd/system/dsh-web@.service`，一份模板管所有人）：
   ```ini
   [Service]
   User=dsh
   EnvironmentFile=/etc/dsh/instances/%i.env
   Environment=DSH_HOME=/srv/dsh/%i
   WorkingDirectory=/srv/dsh-work/%i
   # --port 给本实例端口；--trusted-host 给本实例 authority（F2b，漏传则 /api 全 403）
   # 注意 --trusted-host 是可变参数，必须放在最后，否则会把后续 token 一并吃掉
   ExecStart=/usr/local/bin/dsh web --port ${DSH_PORT} --trusted-host ${DSH_AUTHORITY}
   Restart=on-failure
   # 绑定保持默认 127.0.0.1（CLI 本身拒绝 0.0.0.0，F2，双保险），反代按子域分流

   [Install]
   WantedBy=multi-user.target
   ```
   配套 `/etc/dsh/instances/zhangsan.env`：

   ```ini
   DSH_PORT=7101
   DSH_AUTHORITY=zhangsan.dsh.corp.com
   ```

   `systemctl enable --now dsh-web@zhangsan dsh-web@lisi …`。实例绝不能绑
   `0.0.0.0`（shipped CLI 本身拒绝该值，F2，双保险）。

   > **端口不要靠 patch 文件改**：写 `$DSH_HOME/cordis.patch.yml` 覆盖 `webserver` 行虽然
   > 可行，但 patch 会**整块替换** `config`（不做深合并，5 个键必须全部重述），并因此丢掉
   > `port: !!js ctx.webStartup.port ?? 3080` 这个表达式——`--port` 从此失效。用命令行
   > flag 更简单，也保留了 flag 的优先级。
4. **反代**（Caddy 示意；子域名路由优于路径路由——cookie 隔离天然干净）：
   ```caddy
   *.dsh.corp.com {
       forward_auth <SSO 网关>      # 企业认证，通过才转发（F2 的补位）
       reverse_proxy 127.0.0.1:{按子域名查表端口}
   }
   ```
   **反代的硬性要求**（少了任何一条都会出故障）：
   1. **必须原样透传 `Host`**（`zhangsan.dsh.corp.com`）——DSH 的 cookie 名与签名载荷
      都从 `Host` 派生，改写了 Host 就会掉登录；同时该 authority 必须已通过
      `--trusted-host` 声明（F2b），否则 `/api` 403。
   2. **WebSocket 必须转发 `Upgrade`/`Connection` 头并走 HTTP/1.1**。服务端每 2 秒 ping
      一次、连丢 2 个心跳（约 4~6 秒）即 `terminate`，所以**真正的约束不是空闲超时**
      （长 `proxy_read_timeout` 无意义），而是**控制帧必须能往返**——不透传控制帧会导致
      客户端反复重连而不是干净地超时。
   3. `/plugins/events` 是 **SSE**（不是 WebSocket），需**关闭响应缓冲**（nginx 侧
      `proxy_buffering off` / Caddy 默认即可）。
   4. `X-Forwarded-*` 头**发了也没用**——DSH 不解析它们（F2）。发了无害，但**不要**据此
      推断任何行为。
5. **LLM 网关**：各实例 profile 统一 `DEEPSEEK_BASE_URL=https://llm-gw.corp.com`，
   key 只存在于网关（F12）。
6. **launch token 首次下发**：见 B.3。
7. **备份**：`/srv/dsh/<用户>`（DSH_HOME）+ `/srv/dsh-work/<用户>`（产出），两者都要（F3/F10）。
8. **监控**：内存（第一瓶颈，§9）、实例进程存活、磁盘增长（附件任意文件上传后要盯，F8）。

### B.3 launch token 运维（0.1.2+ 关键流程，F2）

```
实例启动 ──生成随机 token──打印在 stdout（journal 可见）
        实际打印形如：dsh web: http://127.0.0.1:7101/?token=<43位 base64url>
员工首次访问 https://<用户>.dsh.corp.com/?token=xxxxx     ← authority 需人工改写
        └─ 换 30 天签名 cookie（HttpOnly/SameSite=Strict，绑 host+port）
之后 30 天直接访问干净 URL
```

> **token 是进程级、可重复兑换的**（并非"一次性"）：同一 token 在进程存活期内可无限次
> 换取 cookie，只有重启才作废。因此 journal 里出现的 token **等同密码**，务必收紧
> journal 读权限、不要把整段 journal 外发。

抓取命令（进程打印的是 `http://127.0.0.1:<port>/`，**不含公网域名**）：

```bash
journalctl -u dsh-web@zhangsan --no-pager \
  | grep -o 'http://127\.0\.0\.1:[0-9]*/?token=[A-Za-z0-9_-]*' | tail -1
# 抓到后手工把 authority 换成公网域名再发：https://zhangsan.dsh.corp.com/?token=...
```

| 场景 | 行为 | 处置 |
| --- | --- | --- |
| 实例重启 | token 换新，**未过期 cookie 仍有效** | 已登录用户无感，**不必**重发 token |
| 换浏览器/清 cookie/超 30 天 | 需重新走 token | 用上面的 grep 抓当前 token URL，改写 authority 后发给员工 |
| 员工离职/设备丢失 | 吊销该实例全部会话 | 删 `$DSH_HOME/.credentials.yaml` 的 **`records:`** 段中 `client-connection/browser-session` 条目 + **重启实例**（不重启不生效——secret 每次启动只读一次）；配合停用 SSO 账号 |
| 与 SSO 的关系 | 两层叠加，DSH 不解析转发头 | forward_auth 过了 SSO 还要过 DSH cookie 层，缺一不可；且该 authority 必须在 `--trusted-host` 中（F2b） |
| 跨站深链 | cookie 为 `SameSite=Strict` | 从 SSO 门户/IM 点链接跳进来**不带 cookie** → 401；引导员工用书签或直接输域名 |

### B.4 常见坑

1. **忘传 `--trusted-host`（F2b）**——头号坑。页面能打开、一发消息就失败，日志里 `/api`
   全是 403。症状极具迷惑性，因为 `/` 的 401 验收项是**通过**的；
2. **把 `--trusted-host` 写在中间**——它是可变参数（`<authority...>`），会吞掉后面的 token；
   必须放在 `ExecStart` 最后；
3. 以为反代做好就完事——DSH cookie 层独立存在，员工卡 401 多因没走 token 首登；
4. 跨子域共享登录不行——cookie 绑 `Host`（含非默认端口），这同时也是隔离优点；
5. `DSH_HOME` 放 NFSv3 共享——写租约失效（F4）；B 形态单机本地盘无此问题，分片扩容时注意；
6. 忘配 `WorkingDirectory`——产出散落在服务家目录；
7. 用 `$DSH_HOME/cordis.patch.yml` 改端口——patch **整块替换** `config`，必须重述全部 5 个键，
   且会**丢掉 `--port` 的优先级**；改端口请用命令行 flag；
8. 以为实例之间天然隔离——默认全部实例同一系统用户，「互不可见」只在应用层成立（§9.2）；
9. 人员增减靠手搓——脚本化：建号=建目录+起实例+路由登记；销号=停实例+归档两目录+注销路由。

### B.5 验收清单

- [ ] `https://<用户>.dsh.corp.com` 经 SSO + token 首登后能到达会话界面；
- [ ] **在界面里真的发一条消息并收到模型回复**（这一步才验证 `/api` 通过信任围栏，
      即 `--trusted-host` 配置正确；只看到界面**不算通过**，F2b）；
- [ ] 浏览器开发者工具 Network 里无 403 响应；
- [ ] 实例端口仅监听 127.0.0.1（`ss -tlnp`）；
- [ ] 张三的会话/附件/凭据在李四实例完全不可见（F1 隔离验证；注意这是**应用层**隔离，
      OS 层同用户不隔离，见 §9.2）；
- [ ] 停掉某实例再重启，用户历史会话完整恢复（F4 落盘验证）；
- [ ] LLM 请求在网关侧有审计记录，实例环境无明文 key；
- [ ] 重启实例后已登录用户不掉线（cookie 跨重启验证）；
- [ ] `journalctl -u dsh-web@*` 的读权限已收紧（内含等同密码的 launch token）。

## 附录 C. DSH 技术栈速览（部署前建立认知）

回答"DSH 到底是什么技术做成的"，帮助非 Node 背景的工程师理解 §5.8 的制品选型。

### C.1 TypeScript、Node、Python 的关系

三者**不在同一个层面上**，不是三个同类竞品：

| | 是什么 | 类比 |
| --- | --- | --- |
| **TypeScript** | 一门**语言**（JavaScript 超集，加静态类型） | 相当于 Java 语言本身 |
| **Node.js** | 一个**运行时**（V8 引擎 + 系统 API），执行 JavaScript | 相当于 JVM |
| **Python** | **另一门语言 + 另一套运行时**（CPython） | 相当于另一门语言，与 Java 平行 |

**Node 不认识 TypeScript**——`.ts` 必须先编译成 `.js`：

```
TypeScript 源码 ──编译──▶ JavaScript ──执行──▶ Node.js 进程
  (.ts/.tsx)     tsc/tsdown    (.js)      (V8 + 文件/网络/子进程)

              Python ←—— 完全不在这条链上
```

### C.2 那 Python 在 DSH 里干什么？

**Python 既不是 DSH 的实现语言，也不是它的依赖**，只在三个边缘位置出现：

| 角色 | 包 | 说明 |
| --- | --- | --- |
| **① 分发载体** | `deepseek-harness-runtime-bin` | **用 Python 的包装格式运一个 Node 应用**（见附录 D） |
| ② 客户端 SDK | `deepseek-harness-sdk` | 让 Python 程序**调用** DSH（起 `dsh --profile sdk` 走 JSON-RPC），不是把 DSH 嵌进 Python |
| ③ 实验性能力 | `packages/experimental/code-runtime-python` | 让 agent 执行 Python 代码，**不随官方发布** |

角色①最能说明 Python 的地位——看它的启动代码
（`python/sdk-runtime/src/deepseek_harness_runtime/__init__.py`）：

```python
def main() -> None:
    ...
    argv = (*resolve_bundled_launch_args(), *sys.argv[1:])
    if sys.platform == "win32":
        raise SystemExit(subprocess.run(argv, env=os.environ).returncode)
    os.execvpe(argv[0], argv, os.environ)   # ← POSIX：用内嵌 Node 替换当前进程
```

Linux 上 `os.execvpe` **把 Python 进程整个替换成内嵌的 Node 可执行程序**——Python 起个头
就消失了，真正跑的是 Node。

> **一句话**：**TypeScript 是"用什么写"，Node.js 是"跑在哪里"，Python 是"怎么送过去 + 怎么当客户端"。**

### C.3 技术全景

| 层面 | 技术 | 说明 |
| --- | --- | --- |
| **语言** | **TypeScript 6** | 主实现，约 3346 个 `.ts` + 365 个 `.tsx` |
| | **C** | 原生插件（`native/system`：`flock.c`、`main.c`）——跨进程会话写租约靠它 |
| | **Python 3.10+** | SDK + wheel 打包（边缘角色，见 C.2） |
| **运行时** | **Node.js ≥ 22.19** | 引擎下限 `^22.19.0 \|\| >=24.0.0` |
| | `node:sqlite` | **Node 内置** SQLite，用于存储与会话检索索引 |
| | `node:zlib` | **Node 内置** zstd，用于会话日志压缩 |
| **框架** | **Cordis 4.0.2** | 底层插件框架（vendored 重命名为 `@deepseek-ai/cordis`）。**一切皆插件**——模型适配器、工具注册表、会话日志、agent loop 本身都是插件，均可在配置里替换 |
| **前端** | **React 18** + **Vite** | Web UI，按插件粒度加载 |
| **构建** | `tsc` + **tsdown** + **Vite** | 编译 / 打包 / 前端构建 |
| **测试** | **Vitest** + **Playwright** | 单元与端到端 |
| **包管理** | **pnpm 11.7** workspaces | 253 个 workspace 包 |
| **通信** | HTTP / WebSocket / **SSE** / JSON-RPC / ACP / MCP | SSE 用于前端热替换（**不是 WebSocket**）；OTel 遥测刻意不走代理（F19） |
| **隔离** | **Landlock** / bubblewrap / Seatbelt | Linux 内核级沙箱 / 私有 PID 命名空间 / macOS 沙箱 |
| **存储** | JSONL + zstd / SQLite / 内容寻址附件 | 会话日志 / 索引与 KV / SHA-256 分片 + 硬链接去重 |
| **工具** | ripgrep | 随 wheel 分发的 `-rg` sidecar |
| **桌面** | Electron | `dsh-app://` 协议，不开监听端口（§5.7） |
| **分发** | npm（251 包）/ **PyPI wheel** / Electron 安装包 | 见 §5.8 与附录 D |

### C.4 这些事实如何影响部署决策

| 事实 | 部署含义 |
| --- | --- |
| 主实现是 TS，必须编译 | "上传源码到服务器" = 要在服务器装**整条 TS 构建链** |
| 运行时是 Node ≥22.19 | "离线 npm 包" = 必须自带 Node 运行时（**22.14 不满足下限**） |
| 官方已用 wheel 把这两步预先做完 | **推荐 wheel**：目标机既不要 TS 编译器，也不要 Node |
| Python 只是载体，跑起来即被替换 | "装 Python" 不是引入运行时依赖，只是一个解包动作 |

## 附录 D. runtime wheel 是什么（制品格式科普）

§5.8 推荐用 `deepseek-harness-runtime-bin` 部署。这里解释它到底是什么。

### D.1 wheel 是 Python 生态的"已构建分发包"

Python 有两种分发格式：

| 格式 | 内容 | 类比 |
| --- | --- | --- |
| **sdist**（`.tar.gz`） | **源码**分发，安装时现编译 | 源码包 |
| **wheel**（`.whl`） | **已构建**分发，安装时直接解包落位 | **`.jar`** |

第一个类比就出来了：**wheel 之于 Python ≈ jar 之于 Java**——都是语言生态约定的标准打包
格式，都是已构建产物，都由包管理器从中央仓库（Maven Central / **PyPI**）解析依赖。
wheel 取代了更早的 `egg` 格式，现有 PEP 427 / PEP 600 标准化。

### D.2 wheel 文件名本身就是一份兼容性声明

```
deepseek_harness_runtime_bin - 0.1.5rc1 - py3 - none - manylinux_2_28_x86_64 .whl
└────── 包名 ──────┘  └─版本─┘  └─┬─┘  └─┬─┘  └──────── 平台标签 ────────┘
                              Python   ABI
                               标签    标签
```

| 字段 | 含义 |
| --- | --- |
| `py3` | 兼容任意 Python 3（不绑定小版本） |
| `none` | 不含 Python ABI 特定扩展 |
| `manylinux_2_28_x86_64` | **Linux x86_64，要求 glibc ≥ 2.28** |
| `aarch64` | ARM64 版（另一种 wheel） |

**`manylinux` 是 Linux wheel 的兼容性标准**（PEP 600），数字即 glibc 下限：

| 标签 | glibc 下限 | 对应发行版 |
| --- | --- | --- |
| `manylinux2014` | 2.17 | CentOS 7 |
| **`manylinux_2_28`** | **2.28** | RHEL 8 / EulerOS 系 ← **DSH 在这档** |
| `manylinux_2_34` | 2.34 | RHEL 9 / Ubuntu 22.04 |

`pip` 按当前机器的 Python 版本、架构、glibc 自动挑匹配 wheel——**挑不到就装不上**。
这就是部署手册要求先跑 `ldd --version` 的原因。wheel 本质是 zip，可直接查看内容：

```bash
unzip -l deepseek_harness_runtime_bin-0.1.5rc1-py3-none-manylinux_2_28_x86_64.whl
```

### D.3 但 DSH 这个 wheel 是**特例**——这才是关键

普通 wheel 装的是 **Python 库代码**（`.py` 文件）。**DSH 这个 wheel 装的是一个 Node.js 应用**，
Python 在此只是**分发载体**，不是运行时。对照 Java 世界的形态：

| Java 世界的形态 | 目标机需要 | DSH 对应 |
| --- | --- | --- |
| 普通 `.jar`（纯 class） | 外部 JRE | npm 包（薄入口 + `node_modules`） |
| `.war` | 外部 Tomcat/中间件 | — |
| 可执行 fat jar（Spring Boot） | **仍需外部 JRE** | — |
| **`jpackage` 自包含应用镜像（自带 JRE）** | **什么都不需要** | ✅ **DSH 的 runtime wheel** |

官方 README 原话：

> It packages the normal `dsh` CLI and its **closed Node dependency tree** into a **native
> executable, so SDK use requires no system Node.js**.

即：**应用代码 + 全部依赖 + 内嵌 Node 运行时，全部塞进一个可执行文件**。目标机不需要
Node、npm、pnpm，也不需要任何构建工具链。

### D.4 为什么 Node 生态没有"jar"，而必须有 wheel

这解释了为什么这个方案让人觉得别扭——Java 直觉在这里**部分失效**：

```
Java 常规形态：  源码 → 编译 → 【打成 jar/war】 ← 生态标配，一步到位
Node 官方形态：  源码 → 构建 → 【npm 包 = 薄入口 + 依赖清单】 ← 运行时才去解析 node_modules
```

Node 生态的惯例是**依赖树由包管理器在安装时解析**，而不是预先打成整体。官方发布的
`@deepseek-ai/dsh` 就是如此——实测整个 CLI 只有 **4 个 JS 文件、约 44KB**，且保留着
`import ... from "@deepseek-ai/dsh-app-boot"` 这类裸模块导入，必须配合一棵几百个包的
`node_modules` 才能跑。

**所以内网部署的痛点不是"DSH 没打成包"，而是"按 Node 惯例它根本没有'打成一个包'这个形态"。**
`deepseek-harness-runtime-bin` 就是官方给出的、已经打好包的那一个整体。

### D.5 制品画像与部署前校验点

| 项 | 值 |
| --- | --- |
| 包名 | `deepseek-harness-runtime-bin`（PyPI） |
| 体积 | Linux x86_64 wheel ≈ **77MB**（PyPI 单文件上限 100MB） |
| Python 要求 | `requires_python >= 3.10`；**无 Python 依赖**（`requires_dist` 为空） |
| 已发布平台 | Linux x64/arm64、macOS x64/arm64、Windows x64 |
| 可执行文件 | `<site-packages>/deepseek_harness_runtime/runtime/deepseek-harness-sdk-runtime-linux-x64`，**必须与同目录 `-rg` sidecar 并存** |
| `DSH_HOME` | 控制台命令**强制要求非空 `DSH_HOME`，绝不回退 `~/.dsh`**（缺失即退出码 2） |
| 限制 | `dsh plugin --profile <n> …` 仍**需要 pnpm 在 PATH 上**——内网动态装插件走不通，插件须随 profile 预置 |

**部署前四个校验点**：① `ldd --version` ≥ 2.28；② Python ≥ 3.10（否则走 `unzip` 解包路线）；
③ wheel 标签与架构匹配（x86_64 / aarch64）；④ 若用解包方式安装，`-rg` sidecar 必须一起保留。

---

*本指南由架构分析整理而成，所有事实性陈述可在登记 commit 的对应出处复核。*
