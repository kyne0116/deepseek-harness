# CONTEXT.md — DSH 内网部署域词汇表

> 本目录（`DSH部署/`）文档共用术语。只收词汇定义，不收实现细节与操作步骤。
> 操作见 `10.218.180.41至60/` 下各手册；构建期语境见《DSH_构建打包指南》。

## 载体（carrier）

DSH runtime 的两种分发形态。**exe 载体**：单文件原生可执行
（`deepseek-harness-sdk-runtime-linux-x64`，pkg --sea 打包，服务器实际运行物）；
**node 载体**：真 Node + 磁盘 `node_modules` 闭包（开发/冒烟用）。
两者行为差异是多数"本机好的、服务器坏的"类问题的根源。

## 代理桩（module proxy stub）

运行时启动时写在 `$DSH_HOME/profiles/node_modules/` 下的 ESM 重导出小包：
以 `exports` 子路径 + `entry-N.js` 把导入重定向到 exe 快照内的真实模块
（`dsh.moduleFallback.targets`）。作用：workspace 软链无法进入 pkg 快照，
桩让 profile 目录下的插件导入仍可解析。**由"桩自愈"按版本生成与重建。**

## 桩自愈（heal）

启动时对代理桩的对账过程（`healProfilesModuleFallback`）：逐包比对
`version + dsh.moduleFallback.targets + entry 文件存在性`，全部一致则跳过，
否则删除重写。推论：**手工修改桩的 `exports` 可以幸存**（不在比对范围），
但删掉桩必被按当前 staging 状态重建 —— staging 缺什么，桩就缺什么。

## 伴随占位（companion stub）

`lib/types/{index,invariant,startup}.js` 空模块（`export {}`）。
部分包的 tsdown 配置把 invariant/startup 列为独立打包入口，但这些文件
在洁净树上没有生产者（无对应源码/无 tsc 项目产出），缺失即构建失败。
重铺方式见《构建指南》F2/F3。

## fallback targets

代理桩 `package.json` 的 `dsh.moduleFallback.targets` 映射：
子路径 → `file:///snapshot/...` 真实模块 URL。由 staging 包的
`exports` 派生（`packageProxySource`）；staging 缺某子路径的产物文件
（如 `lib/index.js`）时该子路径被**静默跳过** —— 这是"桩缺 `.` 主入口"
引导崩溃的机制（2026-09 实证，随 0.1.5rc2 修复版解决）。

## profile（运行面）

`$DSH_HOME/profiles/<name>` 定义一种启动组合（随附模板：`web`、`headless`、
`acp`、`sdk`、`sdk-minimal`）。`dsh web` 使用 `web` profile，其插件清单
含 session-controller 等服务 —— profile 的插件树加载失败 = 启动期退出
的主因类型。`profiles/node_modules` 为全体 profile 共享的代理桩安装层。

## token 轮换

实例每次启动打印新访问 token（服务日志 `token=...` 行），旧 token 立即失效。
推论：重启/升级后必须重新抓取并分发；排障时"日志里 token 行数"即成功启动次数。

## 热树构建 vs 洁净构建

**热树构建**：lib/types 等产物目录里留有历代累积产物，构建可成功；
**洁净构建**：产物清零后构建。2026-09 实证：官方构建流程在洁净树上
多处必死（根包入口无生产者、跨面顺序依赖、clean 竞态），热树产物是
事实上的隐藏前置。完整清单与规避见《构建指南》§3.6 F1~F7。

## 官方缺口（F1~F7）

对上游 deepseek-harness 构建/打包层的缺陷编号总账（定义见《构建指南》§3.6）：
F1 pkg SEA prelude readdirSync 丢参数；F2 根包入口无生产者；F3 洁净构建死锁；
F4 tsdown clean 竞态；F5 pnpm install 后链接残缺；F6 linux 原生二进制供给缺失；
F7 client 面硬依赖 UI。向上游反馈时引用此编号。
