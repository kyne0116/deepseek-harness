#!/usr/bin/env bash
#
# DSH 部署前置检查（只读脚本，不对系统做任何变更）
#
# 目标平台：BigCloud Enterprise Linux For Euler 21.10 LTS（x86_64 / aarch64）
#           RHEL / CentOS / Rocky / AlmaLinux 8 系等价
# 用法：    bash 前置检查.sh
# 退出码：  0 = 无阻断项；1 = 存在阻断项（FAIL）
#
# 依据：《DSH方案B-每人一实例+反代-内网泛子域部署手册.md》《DSH企业部署架构选型指南.md》
# 锚定：DSH 0.1.5-rc.2（c291e7961a）/ deepseek-harness-runtime-bin 0.1.5rc1
#
# 所有检查项只读取系统状态：不安装、不写入、不修改任何配置、不启停任何服务。
#

set -u

PASS=0; WARN=0; FAIL=0
ok()   { printf '  [\033[32mPASS\033[0m] %s\n' "$*"; PASS=$((PASS+1)); }
warn() { printf '  [\033[33mWARN\033[0m] %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  [\033[31mFAIL\033[0m] %s\n' "$*"; FAIL=$((FAIL+1)); }
info() { printf '  [\033[36mINFO\033[0m] %s\n' "$*"; }
sec()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# $1 >= $2 -> 0
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

printf '\033[1mDSH 部署前置检查\033[0m  （只读，不会修改系统）\n'
printf '主机：%s    时间：%s\n' "$(hostname 2>/dev/null || echo '?')" "$(date '+%F %T')"

# ─────────────────────────────────────────────────────────────────────────────
sec "1. 操作系统与 CPU 架构"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "发行版：${PRETTY_NAME:-$NAME $VERSION}"
else
  warn "缺少 /etc/os-release，无法识别发行版"
fi

ARCH="$(uname -m)"
WHEEL_TAG=""
case "$ARCH" in
  x86_64)        WHEEL_TAG="manylinux_2_28_x86_64";  ok "CPU 架构 $ARCH（对应 wheel 标签 $WHEEL_TAG）" ;;
  aarch64|arm64) WHEEL_TAG="manylinux_2_28_aarch64"; ok "CPU 架构 $ARCH（对应 wheel 标签 $WHEEL_TAG）" ;;
  *)             bad "不支持的 CPU 架构：$ARCH（官方仅发布 x86_64 与 aarch64）" ;;
esac

if [ "$(uname -s)" = "Linux" ]; then ok "内核：$(uname -r)"; else bad "非 Linux 系统，本文档不适用"; fi

# ─────────────────────────────────────────────────────────────────────────────
sec "2. glibc 版本（manylinux_2_28 硬性下限）"

# 只接受「输出里明确带 glibc 字样」的探测结果，避免把无关版本号误判成 glibc。
# 探测失败必须判 FAIL —— 这条是硬性门槛，宁可报无法确定也不能放过。
GLIBC=""; GLIBC_SRC=""
if have getconf; then
  raw="$(getconf GNU_LIBC_VERSION 2>/dev/null)"
  case "$raw" in
    *[Gg][Ll][Ii][Bb][Cc]*) GLIBC="$(printf '%s' "$raw" | awk '{print $NF}')"; GLIBC_SRC="getconf GNU_LIBC_VERSION" ;;
  esac
fi
if [ -z "$GLIBC" ] && have ldd; then
  raw="$(ldd --version 2>/dev/null | head -1)"
  case "$raw" in
    *musl*|*Musl*) GLIBC="musl"; GLIBC_SRC="ldd --version" ;;
    *[Gg][Ll][Ii][Bb][Cc]*|*GNU*)
      GLIBC="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+$')"; GLIBC_SRC="ldd --version" ;;
  esac
fi

case "$GLIBC" in
  musl)
    bad "检测到 musl libc（Alpine 等）—— 【阻断项】manylinux wheel 不兼容 musl。"
    bad "     退路：改用 glibc 发行版，或走「自建容器镜像」路线（选型指南 §9.2）" ;;
  ""|*[!0-9.]*)
    bad "无法确定 glibc 版本（探测来源：${GLIBC_SRC:-无}）—— 按【阻断项】处理。"
    bad "     请手工执行确认：getconf GNU_LIBC_VERSION  或  ldd --version" ;;
  *)
    if version_ge "$GLIBC" "2.28"; then
      ok "glibc $GLIBC ≥ 2.28 —— 满足 manylinux_2_28 wheel 要求（来源：$GLIBC_SRC）"
    else
      bad "glibc $GLIBC < 2.28 —— 【阻断项】runtime wheel 无法使用。"
      bad "     退路：改用「离线 npm 安装」或「自建容器镜像」，参见选型指南 §9.2"
    fi ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
sec "3. Python 与安装工具（走 pip 安装路线时需要）"

if have python3; then
  PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
  ok "python3 已安装：$PYV（$(command -v python3)）"
  if [ -n "$PYV" ] && version_ge "$PYV" "3.10"; then
    ok "Python $PYV ≥ 3.10 —— 满足 wheel 的 requires_python"
  else
    warn "Python $PYV < 3.10 —— pip 会以 requires_python 拒绝安装 runtime wheel"
    warn "     退路：wheel 本质是 zip，改用 unzip 解包取二进制（手册 §6 已给出命令）"
  fi
else
  warn "未安装 python3 —— 无法走 pip 安装路线"
  warn "     退路：unzip 解包 wheel 直接取二进制（手册 §6 已给出命令）"
fi

have pip3 || have pip \
  && ok "pip 可用" \
  || warn "未找到 pip（若走解包路线则不需要）"

if have unzip; then
  ok "unzip 已安装（解包 wheel 的退路可用）"
else
  warn "未找到 unzip —— 若需走解包轮子路线请先安装"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "4. systemd 与服务托管能力"

if have systemctl; then
  if [ -d /run/systemd/system ]; then
    ok "systemd 正在运行（可用于 dsh-web@ 模板单元）"
  else
    warn "存在 systemctl，但 systemd 未作为 init 运行（容器/ WSL 环境？）"
  fi
else
  bad "未找到 systemctl —— 手册的 dsh-web@ 模板单元方案不可用"
fi

if have useradd; then ok "useradd 可用（创建 dsh 专用用户）"; else bad "未找到 useradd"; fi

# ─────────────────────────────────────────────────────────────────────────────
sec "5. 文件描述符上限（每用户 WebSocket 长连接）"

SOFT="$(ulimit -Sn 2>/dev/null || echo '?')"
HARD="$(ulimit -Hn 2>/dev/null || echo '?')"
info "当前 shell：soft=$SOFT  hard=$HARD"

LIMIT_CONF=""
for f in /etc/systemd/system.conf /etc/systemd/system.conf.d/*.conf; do
  [ -r "$f" ] || continue
  v="$(grep -E '^\s*DefaultLimitNOFILE\s*=' "$f" 2>/dev/null | tail -1)"
  [ -n "$v" ] && LIMIT_CONF="$f -> $v"
done

if [ -n "$LIMIT_CONF" ]; then
  ok "已配置 DefaultLimitNOFILE：$LIMIT_CONF"
  num="$(printf '%s' "$LIMIT_CONF" | grep -oE '[0-9]+' | tail -1)"
  [ -n "$num" ] && [ "$num" -ge 65535 ] 2>/dev/null \
    && ok "  ≥ 65535，满足手册要求" \
    || warn "  低于手册建议值 65535，请复核"
else
  warn "未配置 DefaultLimitNOFILE —— 手册 §1 要求设为 65535"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "6. 资源容量（手册 §9.1 起步规格 2C/4GB/40GB SSD）"

CPU="$(nproc 2>/dev/null || echo 0)"
if [ "$CPU" -ge 2 ] 2>/dev/null; then ok "CPU 核心：$CPU"; else warn "CPU 核心：$CPU（低于起步建议 2 核）"; fi

MEM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "$MEM_MB" -ge 4096 ] 2>/dev/null; then
  ok "内存：$((MEM_MB/1024)) GB"
elif [ "$MEM_MB" -ge 2048 ] 2>/dev/null; then
  warn "内存：$((MEM_MB/1024)) GB（低于起步建议 4GB，仅够少量实例试点）"
else
  bad "内存：$((MEM_MB/1024)) GB —— 不足以承载 Web GUI 实例"
fi

PROBE="/srv"; [ -d /srv ] || PROBE="/"
AVAIL_GB="$(df -Pk "$PROBE" 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}')"
AVAIL_GB="${AVAIL_GB:-0}"
if [ "$AVAIL_GB" -ge 40 ] 2>/dev/null; then
  ok "可用磁盘（$PROBE）：${AVAIL_GB} GB"
elif [ "$AVAIL_GB" -ge 20 ] 2>/dev/null; then
  warn "可用磁盘（$PROBE）：${AVAIL_GB} GB（低于起步建议 40GB）"
else
  bad "可用磁盘（$PROBE）：${AVAIL_GB} GB —— 不足"
fi

# SSD 判断（非致命，但直接决定会话打开速度）
ROT="$(lsblk -ndo ROTA "$(df -P "$PROBE" 2>/dev/null | awk 'NR==2{print $1}' | sed 's/[0-9]*$//;s#/dev/##')" 2>/dev/null | head -1)"
if [ "$ROT" = "0" ]; then
  ok "底层设备为 SSD/非旋转介质（会话日志 append + zstd 压缩对 IO 敏感）"
elif [ "$ROT" = "1" ]; then
  warn "底层设备为机械盘（ROTA=1）—— 手册明确要求 SSD"
else
  info "无法判定磁盘介质类型，请手工确认：lsblk -d -o NAME,ROTA"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "7. 时钟同步（launch token / cookie 生命周期依赖时钟）"

if have timedatectl; then
  SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  case "$SYNC" in
    yes) ok "systemd-timesyncd/NTP 已同步" ;;
    no)  warn "时钟未同步 —— 手册 §1 要求配置 chrony/NTP" ;;
    *)   info "无法判定同步状态，请手工执行：timedatectl status" ;;
  esac
else
  info "无 timedatectl，请确认已配置 chrony/ntpd"
fi

if systemctl is-active --quiet chronyd 2>/dev/null; then
  ok "chronyd 正在运行"
elif systemctl is-active --quiet ntpd 2>/dev/null; then
  ok "ntpd 正在运行"
else
  warn "未检测到运行中的 chronyd/ntpd"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "8. 端口占用（反代 443 与实例端口段 7100+）"

port_used() { # $1 = port
  if have ss; then ss -Hln "sport = :$1" 2>/dev/null | grep -q . && return 0
  elif have netstat; then netstat -ln 2>/dev/null | grep -qE "[:.]$1[[:space:]]" && return 0
  fi
  return 1
}

if port_used 443; then
  warn "443 已被占用（可能已有 Nginx/其它 Web 服务）—— 请确认是否复用"
else
  ok "443 空闲（Nginx 反代可用）"
fi

BUSY=""
for p in $(seq 7101 7120); do port_used "$p" && BUSY="$BUSY $p"; done
if [ -n "$BUSY" ]; then
  warn "实例端口段已被占用：$BUSY —— 建号时避开"
else
  ok "实例端口段 7101-7120 空闲"
fi

have ss && ok "ss 可用（验收时需要 ss -tlnp）" || warn "未找到 ss，验收步骤需改用 netstat"

# ─────────────────────────────────────────────────────────────────────────────
sec "9. 防火墙与 SELinux"

if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
  warn "firewalld 正在运行 —— 需放行 443/tcp（实例端口只绑回环，无需放行）"
elif have iptables; then
  info "存在 iptables，请自行确认 443 入站策略"
else
  ok "未检测到活动防火墙服务"
fi

if have getenforce; then
  SE="$(getenforce 2>/dev/null)"
  case "$SE" in
    Enforcing) warn "SELinux=Enforcing —— 可能阻断 Nginx 反代到 127.0.0.1 后端"
               warn "     需执行：setsebool -P httpd_can_network_connect 1" ;;
    Permissive) info "SELinux=Permissive" ;;
    Disabled)   ok "SELinux 已关闭" ;;
  esac
else
  ok "未启用 SELinux"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "10. TLS / 反代 / DNS 前置件"

if have openssl; then
  ok "openssl 可用：$(openssl version 2>/dev/null)"
else
  bad "未找到 openssl —— 手册 §4 自建根 CA 与泛证书需要它"
fi

if have nginx; then
  info "系统已装 Nginx：$(nginx -v 2>&1)"
  warn "请确认版本与手册 §8 的配置兼容（WebSocket/SSE 需 proxy_buffering off）"
else
  info "未安装 Nginx（手册 §6 从 RPM 本地安装，属预期）"
fi

have dnsmasq && info "dnsmasq 已安装（内网泛解析可用）" \
             || info "未安装 dnsmasq（若公司已有内网 DNS，改为在现有 DNS 上加泛记录）"

have dig      && ok "dig 可用" \
  || { have nslookup && ok "nslookup 可用" || warn "无 dig/nslookup，DNS 验证步骤受限"; }

# ─────────────────────────────────────────────────────────────────────────────
sec "11. 既有 DSH 环境（避免重复部署冲突）"

if id dsh >/dev/null 2>&1; then
  warn "系统用户 dsh 已存在（$(id -u dsh)）—— 确认是既有部署还是残留"
else
  ok "系统用户 dsh 不存在（可安全创建）"
fi

if have dsh; then
  warn "PATH 上已存在 dsh：$(command -v dsh)"
  info "  版本输出：$(dsh --version 2>&1 | head -1)"
else
  ok "PATH 上无既有 dsh"
fi

if [ -n "${DSH_HOME:-}" ]; then
  warn "当前环境已设置 DSH_HOME=$DSH_HOME（注意：控制台命令强制要求非空 DSH_HOME）"
else
  ok "当前环境未预设 DSH_HOME（由 systemd 单元按实例注入）"
fi

for d in /srv/dsh /srv/dsh-work /etc/dsh; do
  if [ -d "$d" ]; then
    warn "$d 已存在（既有数据？）—— $(ls -ld "$d" 2>/dev/null | awk '{print $1, $3":"$4}')"
  else
    info "$d 不存在（将由手册 §1 创建）"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
sec "12. 出站代理（可选项：LLM 出口走企业代理时）"

found_proxy=0
for v in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy; do
  eval "val=\${$v:-}"
  [ -n "$val" ] && { info "$v=$val"; found_proxy=1; }
done
if [ "$found_proxy" = "1" ]; then
  warn "检测到代理变量。注意 DSH 的【刻意例外】：OTel 遥测、workflow worker、"
  warn "     code-runtime worker 不经代理（选型指南 F19），出口管控不能假定全覆盖"
else
  info "未设置代理变量（若 LLM 出口走直连或网关，属正常）"
fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n\033[1m== 汇总 ==\033[0m\n'
printf '  PASS=%d   WARN=%d   FAIL=%d\n' "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31m存在 %d 项阻断问题，请先解决后再按手册部署。\033[0m\n' "$FAIL"
  exit 1
fi

printf '\n\033[32m未发现阻断项。\033[0m'
if [ "$WARN" -gt 0 ]; then
  printf '（有 %d 项警告，请逐条确认）' "$WARN"
fi
printf '\n'
printf '下一步：按《DSH方案B-每人一实例+反代-内网泛子域部署手册.md》§2 在跳板机准备离线制品。\n'
if [ -n "$WHEEL_TAG" ]; then
  printf '本机对应 wheel 平台标签：%s\n' "$WHEEL_TAG"
fi
exit 0
