#!/bin/bash
#===============================================================================
# php2shell_scan.sh  (v2.0.0)
#-------------------------------------------------------------------------------
# 用途：PHP2Shell 漏洞风险扫描器（只读，不修改系统、不安装任何软件）
#
# 漏洞背景（PHP 官方 2026-10-21 发布，CVSS v4.0 = 9.2，未认证 RCE）：
#   CVE-2026-109618 (GHSA-w8hw-w9fx-j79w) : OOM 处理路径内存破坏
#       PHP 用 longjmp() 中止超出 memory_limit 的请求，可能在请求内部状态尚未
#       完全初始化时打断执行，随后的请求清理流程会把无效数据当作有效数据处理。
#   CVE-2026-109619 (GHSA-6wmf-4rv5-p3rp) : 陈旧全局状态导致的 use-after-free
#       请求私有的内部状态（error/session/object/extension state）在其内存被释放
#       后仍被 worker 保留，后续请求可能复用已释放内存。
#   受影响部署形态：mod_php（风险最高，可在业务代码执行前触发）、PHP-FPM、
#   php-cgi、FrankenPHP、LiteSpeed，以及所有基于 PHP 的 CMS / 框架。
#
# 官方修复版本（按分支）：
#   8.2 分支 -> 8.2.35（8.2 将于 2026-12-31 EOL）
#   8.3 分支 -> 8.3.36
#   8.4 分支 -> 8.4.27
#   8.5 分支 -> 8.5.12
#   8.1 及更早 -> 上游不再更新，仅部分发行版 / LTS 供应商提供回补，需查 changelog
#
# 官方缓解措施（https://www.php.net/archive/2026.php#2026-10-21-5）：
#   CVE-2026-109618 : memory_limit=-1（且应用不可覆盖，如 php_admin_value）
#                      + 收紧 post_max_size（无上传 8M / 有上传 32M）
#                      + Web/代理层限制解码后体积、字段数、multipart 分段数等
#   CVE-2026-109619 : session.upload_progress.enabled=0，并重启所有 worker
#   官方明确：隐藏诊断信息（error_reporting / display_errors / @）无效；
#             禁用 OPcache 不在官方缓解措施内。
#
# 兼容：麒麟 V10 (Kylin V10) / CentOS 7,8 / RHEL / SUSE 11,12 / Debian 系
# 约束：Bash 3.x 语法（不使用关联数组、mapfile、${var^^}/${var,,}）
#       【重要】bash 3.2 无法解析命令替换内的 case 语句，本脚本已规避
#       所有外部命令均做存在性检测；无 docker/ss/systemctl 时自动降级
#       所有遍历均使用 for 循环，避免管道子 shell 导致风险计数丢失
#
# 用法：bash php2shell_scan.sh [选项]   （详见 --help）
#===============================================================================

#------------------------------- 默认配置 ---------------------------------------
REPORT_FILE=""            # 报告输出文件，空则自动生成
EXTRA_ROOTS=""            # 额外扫描的 Web 根目录（空格分隔）
DO_DOCKER=1               # 是否扫描容器
DEEP=0                    # 深度模式：允许 docker run 探测容器内 PHP 版本
SCAN_WEB=1                # 是否扫描 Web 目录
NO_COLOR=0
MAX_DEPTH=6               # Web 目录扫描深度

# 严重级别统计（bash3 兼容，不使用关联数组）
CNT_CRIT=0
CNT_HIGH=0
CNT_MED=0
CNT_LOW=0
CNT_INFO=0

# 全局风险标记：用于把"暴露面"与"真实可利用性"关联，避免无谓的 HIGH 噪声
VULN_FOUND=0              # 发现低于修复版本的 PHP
NOFIX_FOUND=0             # 发现官方无修复分支的 PHP
FPM_EXPOSED=0             # 发现对外监听的 FPM
MODPHP_FOUND=0            # 发现 mod_php 部署

#------------------------------- 颜色与输出 -------------------------------------
if [ -t 1 ] && [ "$NO_COLOR" -eq 0 ]; then
    C_RED='\033[1;31m'; C_YEL='\033[1;33m'; C_GRN='\033[1;32m'
    C_BLU='\033[1;34m'; C_GRY='\033[0;37m'; C_BLD='\033[1m'; C_OFF='\033[0m'
else
    C_RED=''; C_YEL=''; C_GRN=''; C_BLU=''; C_GRY=''; C_BLD=''; C_OFF=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log_target() {
    if [ -n "$REPORT_FILE" ]; then
        printf '%s\n' "$*" >> "$REPORT_FILE" 2>/dev/null
    fi
}

# log LEVEL TAG MESSAGE
# 注意：终端输出带颜色，写入报告文件的副本始终为纯文本，避免 ANSI 转义污染日志
log() {
    local level="$1"; shift
    local tag="$1"; shift
    local msg="$*"
    local color=""
    case "$level" in
        CRIT) color="$C_RED"; CNT_CRIT=$((CNT_CRIT+1));;
        HIGH) color="$C_RED"; CNT_HIGH=$((CNT_HIGH+1));;
        MED ) color="$C_YEL"; CNT_MED=$((CNT_MED+1));;
        LOW ) color="$C_BLU"; CNT_LOW=$((CNT_LOW+1));;
        INFO) color="$C_GRY"; CNT_INFO=$((CNT_INFO+1));;
        OK  ) color="$C_GRN";;
        STEP) color="$C_BLD$C_BLU";;
        *   ) color="";;
    esac
    local stamp
    stamp=$(_ts)
    printf '%s\n' "[$stamp] ${color}[$level]${C_OFF} $tag: $msg"
    _log_target "[$stamp] [$level] $tag: $msg"
}

section() {
    local t="=============================================================================="
    printf '\n%s\n%s%s%s\n%s\n' "$t" "$C_BLD$C_BLU" "$*" "$C_OFF" "$t"
    _log_target ""
    _log_target "== $* =="
}

ok()    { log OK   "$@"; }
info()  { log INFO "$@"; }
med()   { log MED  "$@"; }
high()  { log HIGH "$@"; }
crit()  { log CRIT "$@"; }
low()   { log LOW  "$@"; }

die() {
    printf '\n%s[ERROR]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
    _log_target "[ERROR] $*"
    exit 2
}

have() { command -v "$1" >/dev/null 2>&1; }

#------------------------------- 参数解析 ---------------------------------------
usage() {
cat <<'EOF'
用法: bash php2shell_scan.sh [选项]

  --log FILE        指定报告输出文件（默认 /var/log/php2shell_scan_<时间戳>.log，
                    不可写时回落到当前目录）
  --web-root DIR    追加扫描的 Web 根目录，可多次使用（空格分隔传入亦可）
  --deep            深度模式：使用 docker run 探测全部镜像（含自建镜像）内
                    的 PHP 真实版本。会创建并立即删除临时容器（--network none），
                    仅用于取版本号；这是本脚本唯一会产生副作用的动作
  --skip-docker     跳过容器扫描
  --skip-web        跳过 Web 目录与 PHP 应用扫描
  --max-depth N     Web 目录递归深度，默认 6
  --no-color        关闭彩色输出
  -h, --help        显示本帮助

退出码:
  0 = 未发现 CRIT/HIGH 风险
  1 = 发现 CRIT/HIGH 风险（存在未修复的 PHP 版本，或已确认的可利用暴露面）
  2 = 执行错误

只读保证：脚本不安装软件、不启停服务、不修改任何配置或业务数据。
        --deep 模式会创建并立即删除一次性临时容器（不挂载卷、不联网）。

参考:
  https://www.php.net/archive/2026.php#2026-10-21-5
  https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w
  https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --log)        REPORT_FILE="${2:-}"; shift 2 ;;
        --log=*)      REPORT_FILE="${1#*=}"; shift ;;
        --web-root)   EXTRA_ROOTS="$EXTRA_ROOTS ${2:-}"; shift 2 ;;
        --web-root=*) EXTRA_ROOTS="$EXTRA_ROOTS ${1#*=}"; shift ;;
        --deep)       DEEP=1; shift ;;
        --skip-docker) DO_DOCKER=0; shift ;;
        --skip-web)   SCAN_WEB=0; shift ;;
        --max-depth)  MAX_DEPTH="${2:-6}"; shift 2 ;;
        --max-depth=*) MAX_DEPTH="${1#*=}"; shift ;;
        --no-color)   NO_COLOR=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            printf '未知参数: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
done

case "$MAX_DEPTH" in
    ''|*[!0-9]*) MAX_DEPTH=6 ;;
esac

if [ -z "$REPORT_FILE" ]; then
    _ts_file="$(date '+%Y%m%d_%H%M%S')"
    if [ -w /var/log ] 2>/dev/null; then
        REPORT_FILE="/var/log/php2shell_scan_${_ts_file}.log"
    else
        REPORT_FILE="./php2shell_scan_${_ts_file}.log"
    fi
fi
: > "$REPORT_FILE" 2>/dev/null || die "无法写入报告文件: $REPORT_FILE"

#------------------------------- 版本比较工具 -----------------------------------
# ver_cmp A B -> 输出 -1(A<B) / 0(A==B) / 1(A>B)
ver_cmp() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        na=split(a,x,"."); nb=split(b,y,".");
        n=(na>nb)?na:nb;
        for(i=1;i<=n;i++){
            xa=(i<=na)?x[i]+0:0; yb=(i<=nb)?y[i]+0:0;
            if(xa<yb){print -1; exit}
            if(xa>yb){print 1; exit}
        }
        print 0;
    }'
}

# ver_lt A B -> A<B 时返回 0
ver_lt() { [ "$(ver_cmp "$1" "$2")" = "-1" ]; }

# php_branch_verdict MAJ MIN PAT HAS_PAT
#   -> safe | vulnerable | nofix | backport | unknown | minor_only
# HAS_PAT=0 表示只知道主.次版本、patch 未知（例如 Docker 标签 php:8.3），
# 此时不能判定为 vulnerable，否则会对已打补丁的 latest 镜像产生误报。
php_branch_verdict() {
    local maj="$1" min="$2" pat="$3" haspat="$4"
    if [ "$haspat" -eq 0 ]; then
        case "${maj}.${min}" in
            8.2|8.3|8.4|8.5) echo minor_only; return 0 ;;
        esac
    fi
    case "${maj}.${min}" in
        8.2) if [ "$pat" -ge 35 ]; then echo safe; else echo vulnerable; fi ;;
        8.3) if [ "$pat" -ge 36 ]; then echo safe; else echo vulnerable; fi ;;
        8.4) if [ "$pat" -ge 27 ]; then echo safe; else echo vulnerable; fi ;;
        8.5) if [ "$pat" -ge 12 ]; then echo safe; else echo vulnerable; fi ;;
        7.4|8.0|8.1) echo backport ;;
        5.*|6.*|7.0|7.1|7.2|7.3) echo nofix ;;
        *) echo unknown ;;
    esac
}

# parse_version "8.2.10" -> 设置 V_MAJ V_MIN V_PAT V_FULL V_HAS_PAT
parse_version() {
    local raw="$1"
    V_FULL=$(printf '%s' "$raw" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)
    if [ -z "$V_FULL" ]; then
        V_MAJ=0; V_MIN=0; V_PAT=0; V_HAS_PAT=0
        return 1
    fi
    V_MAJ=$(printf '%s' "$V_FULL" | cut -d. -f1)
    V_MIN=$(printf '%s' "$V_FULL" | cut -d. -f2)
    V_PAT=$(printf '%s' "$V_FULL" | cut -d. -f3)
    [ -n "$V_MIN" ] || V_MIN=0
    [ -n "$V_PAT" ] || V_PAT=0
    # 段数：2 段=只有主.次（patch 未知），3 段=patch 已知
    V_HAS_PAT=0
    if [ "$(printf '%s' "$V_FULL" | tr -cd '.' | wc -c | tr -d ' ')" -ge 2 ]; then
        V_HAS_PAT=1
    fi
    return 0
}

# 判定并报告一个 PHP 版本（当前 shell 内调用，计数有效）
report_php_version() {
    local ver="$1" where="$2" kind="$3"
    local v verdict
    [ -z "$ver" ] && return 0
    parse_version "$ver" || return 0
    v="$V_MAJ.$V_MIN.$V_PAT"
    verdict=$(php_branch_verdict "$V_MAJ" "$V_MIN" "$V_PAT" "$V_HAS_PAT")
    case "$verdict" in
        vulnerable)
            VULN_FOUND=1
            high "$kind" "$where 版本 $v 低于该分支修复版本，受 CVE-2026-109618/109619 影响"
            ;;
        nofix)
            NOFIX_FOUND=1
            VULN_FOUND=1
            crit "$kind" "$where 版本 $v 所属分支（$V_MAJ.$V_MIN）上游已停止维护且无修复版本，长期暴露"
            ;;
        backport)
            VULN_FOUND=1
            med "$kind" "$where 版本 $v 所属分支（$V_MAJ.$V_MIN）上游无修复发行版，需确认发行版是否回补"
            ;;
        safe)
            ok "$kind" "$where 版本 $v 不低于该分支修复版本"
            ;;
        minor_only)
            info "$kind" "$where 标签仅含主.次版本（$V_MAJ.$V_MIN），无法判定 patch，需 --deep 探测或进容器确认"
            ;;
        *)
            info "$kind" "$where 版本 $v（分支未知，需人工确认是否受影响）"
            ;;
    esac
    return 0
}

#------------------------------- 采集工具 ---------------------------------------
# 查找 PATH 中及常见目录下的 php 可执行文件
find_php_bins() {
    local b
    for b in php php-cli php-fpm php-cgi php-fpm8.5 php-fpm8.4 php-fpm8.3 php-fpm8.2 \
             php-fpm8.1 php-fpm8.0 php-cgi8.3 php8.5 php8.4 php8.3 php8.2 php8.1 php8.0; do
        if have "$b"; then
            command -v "$b"
        fi
    done
    # 常见安装位置（源码编译、自建、面板安装等）
    for p in /usr/local/php*/bin/php /usr/local/php-*/bin/php /usr/local/php*/bin/php-fpm \
             /usr/local/php-*/bin/php-fpm /usr/local/php*/bin/php-cgi /usr/local/php*/sbin/php-fpm \
             /opt/php*/bin/php /opt/php-*/bin/php /opt/php*/sbin/php-fpm \
             /usr/local/bin/php* /usr/local/sbin/php-fpm* /usr/local/sbin/php-cgi* \
             /usr/bin/php* /usr/sbin/php-fpm* /usr/sbin/php-cgi* /usr/lib/cgi-bin/php* \
             /opt/1panel/versions/*/php*/bin/php /www/server/php/*/bin/php; do
        [ -x "$p" ] && printf '%s\n' "$p"
    done 2>/dev/null
    return 0
}

# 从 systemd unit 的 ExecStart 中提取 php 可执行文件路径
# （覆盖源码编译安装、面板自建 unit 等未进入 PATH 的场景）
find_php_bins_systemd() {
    have systemctl || return 0
    local units u paths p
    units=$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
            | grep -iE 'php' | awk '{print $1}')
    [ -z "$units" ] && units=$(systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null \
            | grep -iE 'php' | awk '{print $1}')
    [ -z "$units" ] && return 0
    local oldifs="$IFS"; IFS=$'\n'
    for u in $units; do
        [ -z "$u" ] && continue
        paths=$(systemctl show -p ExecStart "$u" 2>/dev/null \
                | grep -oE '/[^ ;{}]*php[^ ;{}]*' | sort -u)
        for p in $paths; do
            [ -x "$p" ] && printf '%s\n' "$p"
        done
    done
    IFS="$oldifs"
    return 0
}

# 输出 php 二进制版本首行
php_bin_version() {
    local bin="$1"
    "$bin" -v 2>/dev/null | head -n1
}

# ini_get KEY FILE... -> 多个 ini 文件中最后一次出现的取值（后加载者覆盖前者）
# 兼容 Debian/Ubuntu 的 conf.d 覆盖机制
ini_get() {
    local key="$1"; shift
    local esc f v out=""
    esc=$(printf '%s' "$key" | sed 's/\./\\./g')
    for f in "$@"; do
        [ -r "$f" ] || continue
        v=$(grep -E "^[[:space:]]*${esc}[[:space:]]*=" "$f" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d ' ')
        [ -n "$v" ] && out="$v"
    done
    printf '%s' "$out"
}

# size_to_bytes VALUE -> 归一化为字节数（支持 K/M/G 后缀与纯数字），失败返回空
size_to_bytes() {
    local v="$1"
    local n
    v=$(printf '%s' "$v" | tr 'A-Z' 'a-z' | tr -d ' ')
    [ -z "$v" ] && return 0
    case "$v" in
        *k) n="${v%k}"; n=$((n * 1024)) ;;
        *m) n="${v%m}"; n=$((n * 1024 * 1024)) ;;
        *g) n="${v%g}"; n=$((n * 1024 * 1024 * 1024)) ;;
        *b) n="${v%b}" ;;
        *) case "$v" in
               ''|*[!0-9]*) return 0 ;;
               *) n="$v" ;;
           esac ;;
    esac
    printf '%s' "$n"
    return 0
}

# FPM listen 地址是否对外暴露
# 返回 0 = 暴露（需要绑定回环地址或改用 Unix socket）；返回 1 = 安全
# 注意：listen 写裸端口（如 listen = 9000）时 PHP-FPM 会监听所有网卡，
#       这正是最常见的误配，务必单独识别。
fpm_listen_exposed() {
    local listen="$1"
    case "$listen" in
        127.0.0.1:*|localhost:*|unix:*) return 1 ;;
        /*) return 1 ;;   # Unix socket 路径，如 /var/run/php-fpm.sock
        "") return 1 ;;
        [0-9]*) return 0 ;;
        *) return 0 ;;
    esac
}

# 从镜像名/标签中提取 PHP 版本号（可能只有主.次两段）
extract_image_version() {
    local img="$1" v=""
    v=$(printf '%s' "$img" | awk -F: '{print $NF}' | grep -oE '[0-9]+(\.[0-9]+){1,2}' | head -n1)
    if [ -z "$v" ]; then
        v=$(printf '%s' "$img" | grep -oE '[0-9]+(\.[0-9]+){1,2}' | head -n1)
    fi
    printf '%s' "$v"
}

# 是否为常见的演示 / 测试 / 信息泄露 PHP 文件名
# 单独抽成函数的原因：bash 3.2 无法解析命令替换 ($(...)) 内的 case 语句
is_demo_php_name() {
    local n="$1"
    case "$n" in
        phpinfo.php|phpinfo.html|info.php|test.php|test1.php|php.php|i.php|t.php|tt.php|hello.php|1.php|2.php|a.php|x.php|check.php|probe.php|p.php|cmd.php|shell.php|eval.php|ping.php|env.php|demo.php|default.php|tmp.php|phpversion.php|pi.php)
            return 0 ;;
    esac
    return 1
}

#===============================================================================
# 1. 主机与操作系统基线
#===============================================================================
scan_os() {
    section "1. 主机与操作系统基线"
    log INFO "OS" "$(uname -a)"
    if [ -r /etc/os-release ]; then
        log INFO "OS" "$(grep -E '^(NAME|VERSION|ID|VERSION_ID)=' /etc/os-release | tr '\n' ' ')"
    fi
    if [ -r /etc/kylin-release ]; then
        log INFO "OS" "$(cat /etc/kylin-release 2>/dev/null | tr '\n' ' ')"
    fi
    if [ -r /etc/redhat-release ]; then
        log INFO "OS" "$(cat /etc/redhat-release 2>/dev/null | tr '\n' ' ')"
    fi
    if [ -r /etc/SuSE-release ]; then
        log INFO "OS" "$(grep -E '^(SUSE Linux|openSUSE)' /etc/SuSE-release 2>/dev/null | tr '\n' ' ')"
    fi
    log INFO "OS" "内核 $(uname -r) / 架构 $(uname -m)"

    if [ -r /proc/sys/kernel/randomize_va_space ]; then
        local aslr
        aslr=$(cat /proc/sys/kernel/randomize_va_space)
        if [ "$aslr" = "0" ]; then
            med "KERNEL" "ASLR 已关闭 (/proc/sys/kernel/randomize_va_space=0)，极大降低内存破坏类漏洞利用难度"
        fi
    fi
    if [ -r /proc/sys/kernel/yama/ptrace_scope ]; then
        log INFO "KERNEL" "ptrace_scope=$(cat /proc/sys/kernel/yama/ptrace_scope)"
    fi
    if [ -f /.dockerenv ]; then
        log INFO "OS" "容器检测: 疑似运行在 docker 容器内"
    else
        log INFO "OS" "容器检测: 非 docker 容器（/.dockerenv 不存在）"
    fi
    log INFO "OS" "cgroup: $(head -n1 /proc/1/cgroup 2>/dev/null | cut -c1-140)"
}

#===============================================================================
# 2. 包管理器与 PHP 软件包状态
#===============================================================================
PM=""

# 判断软件包是否承载 PHP 运行时（只有运行时才判定版本风险）
pkg_is_runtime() {
    local n="$1"
    case "$n" in
        php|php-cli|php-fpm|php-cgi|php-common|php-devel|php-embedded|php-*|php[0-9]*|php[0-9]*-*)
            return 0 ;;
    esac
    return 1
}

detect_pm() {
    section "2. 包管理器与 PHP 软件包"
    if have rpm; then PM="rpm"; log INFO "PKG" "包管理器: rpm"; fi
    if have dpkg; then PM="deb"; log INFO "PKG" "包管理器: dpkg"; fi
    if [ -z "$PM" ]; then
        med "PKG" "未检测到 rpm/dpkg，跳过包级检查（源码编译安装请以运行时版本判定为准）"
        return
    fi

    local names ver name
    local oldifs="$IFS"
    IFS=$'\n'

    if [ "$PM" = "rpm" ]; then
        names=$(rpm -qa 2>/dev/null | grep -Ei '^php' | sort)
        for name in $names; do
            [ -z "$name" ] && continue
            ver=$(rpm -q --qf '%{VERSION}' "$name" 2>/dev/null)
            [ -z "$ver" ] && ver=$(printf '%s' "$name" | grep -oE '[0-9]+(\.[0-9]+)*' | tail -n1)
            report_php_version "$ver" "软件包 $name" "PKG"
        done
    else
        names=$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | grep -E '^php' | sort)
        for name in $names; do
            [ -z "$name" ] && continue
            # Debian 版本号可能带 epoch（如 2:8.1.2-1），必须先剥离，
            # 否则会把 epoch "2" 当成主版本号解析
            ver=$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null | sed 's/^[0-9]*://' \
                  | grep -oE '[0-9]+(\.[0-9]+)*' | head -n1)
            report_php_version "$ver" "软件包 $name" "PKG"
        done
    fi
    IFS="$oldifs"

    # 发行版 changelog 回补检测
    local cl
    cl=$(check_changelog_backport)
    if [ -n "$cl" ]; then
        ok "PKG" "changelog 中检出 PHP2Shell 回补记录: $cl"
    else
        info "PKG" "未在 changelog 中检出 CVE-2026-109618/109619 回补记录（7.4/8.0/8.1 分支需人工确认）"
    fi
}

# 检查软件包 changelog 是否包含 PHP2Shell 修复
check_changelog_backport() {
    local out="" p f
    if [ "$PM" = "rpm" ]; then
        for p in php php-cli php-common php-fpm php-devel php-cgi; do
            out=$(rpm -q --changelog "$p" 2>/dev/null | grep -iE 'CVE-2026-109618|CVE-2026-109619|php2shell' | head -n2)
            [ -n "$out" ] && { printf '%s' "$out"; return 0; }
        done
        # SUSE / Kylin 的 changelog 通常在 /usr/share/doc/packages/<pkg>/
        for f in /usr/share/doc/packages/php*/changelog /usr/share/doc/packages/php*/changelog.Debian.gz; do
            [ -r "$f" ] || continue
            out=$(zcat "$f" 2>/dev/null | grep -iE 'CVE-2026-109618|CVE-2026-109619|php2shell' | head -n2)
            [ -n "$out" ] && { printf '%s' "$out"; return 0; }
        done
    elif [ "$PM" = "deb" ]; then
        for f in /usr/share/doc/php*/changelog.Debian.gz /usr/share/doc/php*/changelog.gz \
                 /usr/share/doc/php*-cli/changelog.Debian.gz; do
            [ -r "$f" ] || continue
            out=$(zcat "$f" 2>/dev/null | grep -iE 'CVE-2026-109618|CVE-2026-109619|php2shell' | head -n2)
            [ -n "$out" ] && { printf '%s' "$out"; return 0; }
        done
    fi
    return 0
}

#===============================================================================
# 3. PHP 运行时（命令行 / FPM / CGI）版本判定
#===============================================================================
scan_php_runtime() {
    section "3. PHP 运行时版本判定"
    local bins
    bins=$( (find_php_bins; find_php_bins_systemd) | sort -u)
    if [ -z "$bins" ]; then
        med "PHP" "未发现 PHP 可执行文件"
        return
    fi

    local oldifs="$IFS"
    IFS=$'\n'
    local b vline ver
    local vers=""
    for b in $bins; do
        [ -z "$b" ] && continue
        vline=$(php_bin_version "$b")
        if [ -z "$vline" ]; then
            log INFO "PHP" "  $b -> 版本读取失败（可能为损坏安装或权限不足）"
            continue
        fi
        log INFO "PHP" "  $b -> $vline"
        ver=$(printf '%s' "$vline" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
        [ -z "$ver" ] && continue
        report_php_version "$ver" "运行时 $b" "PHP"
        vers="$vers $ver"
    done
    IFS="$oldifs"

    # 多版本共存检测
    local uniq_vers nvers
    uniq_vers=$(printf '%s\n' $vers | grep -v '^$' | sort -u)
    nvers=$(printf '%s\n' "$uniq_vers" | grep -c '[0-9]')
    if [ "$nvers" -gt 1 ]; then
        med "PHP" "系统内存在多个 PHP 版本共存:$(printf '%s' "$uniq_vers" | tr '\n' ' ')，不同服务可能使用不同版本，易遗漏"
    fi
    log INFO "PHP" "版本集合: $(printf '%s' "$uniq_vers" | tr '\n' ' ')"
}

#===============================================================================
# 4. 补充相关历史高危 PHP CVE 检测
#===============================================================================
scan_extra_cves() {
    section "4. 补充高危 PHP CVE 检测（历史 CVE，非 PHP2Shell 本体）"
    local bins
    bins=$( (find_php_bins; find_php_bins_systemd) | sort -u)
    local oldifs="$IFS"
    IFS=$'\n'
    local b ver v hits=0
    for b in $bins; do
        [ -z "$b" ] && continue
        ver=$(php_bin_version "$b" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
        [ -z "$ver" ] && continue
        parse_version "$ver" || continue
        v="$V_MAJ.$V_MIN.$V_PAT"

        # CVE-2019-11043：PHP-FPM 远程代码执行（nginx + php-fpm 配置不当）
        # 受影响：5.6.0-5.6.39、7.0.0-7.0.33、7.1.0-7.1.33
        case "$b" in
            *php-fpm*)
                case "$V_MAJ.$V_MIN" in
                    5.6) if [ "$V_PAT" -lt 40 ]; then hits=1; med "CVE-2019-11043" "$b 版本 $v 存在 CVE-2019-11043（PHP-FPM RCE）风险，需确认是否以 nginx 反代 fpm"; fi ;;
                    7.0) if [ "$V_PAT" -lt 33 ]; then hits=1; med "CVE-2019-11043" "$b 版本 $v 存在 CVE-2019-11043（PHP-FPM RCE）风险，需确认是否以 nginx 反代 fpm"; fi ;;
                    7.1) if [ "$V_PAT" -lt 33 ]; then hits=1; med "CVE-2019-11043" "$b 版本 $v 存在 CVE-2019-11043（PHP-FPM RCE）风险，需确认是否以 nginx 反代 fpm"; fi ;;
                esac
                ;;
        esac

        # CVE-2024-4577：PHP-CGI 参数注入（以 CGI 模式运行时可绕过配置直接注入参数）
        case "$b" in
            *php-cgi*)
                case "$V_MAJ.$V_MIN" in
                    8.3) if ver_lt "$v" "8.3.8"; then hits=1; high "CVE-2024-4577" "$b 版本 $v 的 CGI 模式存在 CVE-2024-4577 参数注入风险"; fi ;;
                    8.2) if ver_lt "$v" "8.2.20"; then hits=1; high "CVE-2024-4577" "$b 版本 $v 的 CGI 模式存在 CVE-2024-4577 参数注入风险"; fi ;;
                    8.1) if ver_lt "$v" "8.1.29"; then hits=1; high "CVE-2024-4577" "$b 版本 $v 的 CGI 模式存在 CVE-2024-4577 参数注入风险"; fi ;;
                    7.*|5.*|6.*) hits=1; high "CVE-2024-4577" "$b 版本 $v 所属分支已停止维护，CGI 模式存在 CVE-2024-4577 参数注入风险且无官方修复" ;;
                esac
                ;;
        esac
    done
    IFS="$oldifs"
    if [ "$hits" -eq 0 ]; then
        info "CVE" "未命中 CVE-2019-11043 / CVE-2024-4577 的版本条件"
    fi
    return 0
}

#===============================================================================
# 5. Web 服务（LAMP / Apache / nginx / FPM）
#===============================================================================
scan_web_server() {
    section "5. Web 服务与 LAMP 组件"
    local found_web=0
    local oldifs="$IFS"
    IFS=$'\n'

    # Apache
    local httpd=""
    for c in httpd apache2 apache; do
        if have "$c"; then httpd="$c"; break; fi
    done
    if [ -n "$httpd" ]; then
        found_web=1
        log INFO "WEB" "Apache: $httpd -> $("$httpd" -v 2>/dev/null | head -n1)"
        local mods
        mods=$("$httpd" -M 2>/dev/null | grep -iE 'php')
        if [ -n "$mods" ]; then
            MODPHP_FOUND=1
            log INFO "WEB" "模块: $(printf '%s' "$mods" | tr '\n' ' ')"
            if [ "$VULN_FOUND" -eq 1 ]; then
                high "WEB" "Apache 直接加载了 PHP 模块（mod_php）：官方指出 mod_php 风险最高，未认证请求可在业务代码执行前触发漏洞"
            else
                med "WEB" "Apache 直接加载了 PHP 模块（mod_php）：官方指出 mod_php 风险最高，当前 PHP 版本未确认受影响，建议保持关注"
            fi
        else
            log INFO "WEB" "Apache 未直接加载 mod_php（可能经 php-fpm 反代）"
        fi
        # 常见 mod_php 配置文件存在性
        if ls /etc/httpd/conf.modules.d/*php* /etc/apache2/mods-enabled/*php* >/dev/null 2>&1; then
            log INFO "WEB" "存在 mod_php 启用配置: $(ls /etc/httpd/conf.modules.d/*php* /etc/apache2/mods-enabled/*php* 2>/dev/null | tr '\n' ' ')"
        fi
    else
        log INFO "WEB" "未发现 Apache"
    fi

    # nginx
    if have nginx; then
        found_web=1
        log INFO "WEB" "nginx: $(nginx -v 2>&1 | head -n1)"
        local nroot
        nroot=$(grep -rhoE '^[[:space:]]*root[[:space:]]+[^;]+;' /etc/nginx /usr/local/nginx/conf 2>/dev/null | awk '{print $2}' | tr -d ';' | sort -u)
        [ -n "$nroot" ] && log INFO "WEB" "nginx root 指令: $(printf '%s' "$nroot" | tr '\n' ' ')"
        if grep -rq 'fastcgi_pass' /etc/nginx /usr/local/nginx/conf 2>/dev/null; then
            local fpm_addr
            fpm_addr=$(grep -rhoE 'fastcgi_pass[[:space:]]+[^;]+;' /etc/nginx /usr/local/nginx/conf 2>/dev/null | tr -d ';' | sort -u | tr '\n' ' ')
            log INFO "WEB" "nginx 通过 fastcgi_pass 转发至 PHP-FPM: $fpm_addr"
        fi
    else
        log INFO "WEB" "未发现 nginx"
    fi

    # php-fpm 进程
    if have ps; then
        local fpm_proc cnt
        fpm_proc=$(ps -ef 2>/dev/null | grep -E '[p]hp-fpm' | head -n20)
        if [ -n "$fpm_proc" ]; then
            found_web=1
            cnt=$(printf '%s\n' "$fpm_proc" | grep -c '[p]hp-fpm')
            log INFO "WEB" "运行中的 php-fpm 进程: $cnt"
            for p in $fpm_proc; do log INFO "WEB" "  $p"; done
        fi
    fi

    # 服务状态
    if have systemctl; then
        local units u
        units=$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | grep -iE 'php|apache|httpd|nginx|mysql|mariadb|postgres' | awk '{print $1}')
        if [ -n "$units" ]; then
            log INFO "WEB" "运行中的相关 systemd 服务:"
            for u in $units; do log INFO "WEB" "  $u"; done
        fi
    elif [ -d /etc/init.d ]; then
        local inits i
        inits=$(ls /etc/init.d 2>/dev/null | grep -iE 'php|apache|httpd|nginx|mysql|mariadb')
        if [ -n "$inits" ]; then
            log INFO "WEB" "SysV init 脚本: $(printf '%s' "$inits" | tr '\n' ' ')"
            for i in $inits; do log INFO "WEB" "  /etc/init.d/$i"; done
        fi
    fi

    # 数据库组件（LAMP 完整性）
    local db
    for db in mysql mysqld mariadb psql postgresql; do
        if have "$db"; then
            log INFO "WEB" "数据库组件: $db -> $(command -v "$db")"
            found_web=1
        fi
    done

    # 监听端口
    local ports p
    if have ss; then
        ports=$(ss -lntp 2>/dev/null | awk 'NR>1{print $4" "$6}' | grep -E '(:80|:443|:8080|:8000|:9000|:3306|:5432)\b' | head -n20)
    elif have netstat; then
        ports=$(netstat -lntp 2>/dev/null | awk 'NR>2{print $4" "$7}' | grep -E '(:80|:443|:8080|:8000|:9000|:3306|:5432)\b' | head -n20)
    fi
    if [ -n "$ports" ]; then
        log INFO "WEB" "关键监听端口:"
        for p in $ports; do log INFO "WEB" "  $p"; done
        if printf '%s' "$ports" | grep -q ':9000'; then
            FPM_EXPOSED=1
            if [ "$VULN_FOUND" -eq 1 ]; then
                high "WEB" "9000 端口处于监听状态，若为 php-fpm 且暴露于外网，可直接发起 FastCGI 协议攻击"
            else
                med "WEB" "9000 端口处于监听状态，若为 php-fpm 且暴露于外网，可直接发起 FastCGI 协议攻击（通用加固项）"
            fi
        fi
    fi

    IFS="$oldifs"
    [ "$found_web" -eq 0 ] && info "WEB" "未检测到 LAMP/LEMP 相关 Web 服务组件"
}

#===============================================================================
# 6. PHP 配置暴露面检查
#===============================================================================
scan_php_config() {
    section "6. PHP 配置暴露面检查"
    local inis ini overrides
    inis=$(ls /etc/php.ini /etc/php/*/php.ini /etc/php/*/cli/php.ini /etc/php/*/fpm/php.ini \
              /etc/php/*/apache2/php.ini /usr/local/lib/php.ini /usr/local/etc/php/php.ini \
              /opt/php*/etc/php.ini /usr/local/php*/lib/php.ini 2>/dev/null | sort -u)
    # Debian/Ubuntu 的 conf.d/*.ini 会在 php.ini 之后加载，可覆盖关键配置
    overrides=$(ls /etc/php/*/conf.d/*.ini /etc/php/*/*/conf.d/*.ini \
                   /usr/local/etc/php/conf.d/*.ini /usr/local/php*/conf.d/*.ini 2>/dev/null | sort -u)

    if [ -z "$inis" ] && [ -z "$overrides" ]; then
        info "CFG" "未找到 php.ini（可能在容器内或非常规路径）"
        return
    fi

    # 配置文件清单（php.ini 在前，conf.d 覆盖在后，后者优先）
    local files=""
    local oldifs="$IFS"
    IFS=$'\n'
    for ini in $inis $overrides; do
        [ -r "$ini" ] || continue
        files="$files$ini"$'\n'
    done
    IFS="$oldifs"

    local f
    IFS=$'\n'
    for f in $files; do
        [ -r "$f" ] || continue
        log INFO "CFG" "-- $f --"

        # display_errors / expose_php —— 通用加固项，非 PHP2Shell 缓解措施
        local de ep
        de=$(ini_get 'display_errors' "$f")
        ep=$(ini_get 'expose_php' "$f")
        if [ "$de" = "On" ]; then
            low "CFG" "$f: display_errors=On，错误信息直接回显（通用信息泄露风险；注意官方明确说明隐藏诊断信息并不能缓解 PHP2Shell）"
        fi
        if [ "$ep" = "On" ]; then
            low "CFG" "$f: expose_php=On，暴露 PHP 版本指纹（通用加固项）"
        fi
        if [ "$de" = "Off" ] && [ "$ep" = "Off" ]; then
            ok "CFG" "$f: display_errors / expose_php 均已关闭"
        fi

        # memory_limit —— CVE-2026-109618 官方缓解措施
        # PHP 通过 longjmp() 中止超限请求，这恰好是攻击者可控的 OOM 路径；
        # 官方要求设为 -1 且应用不可覆盖。有限上限反而让该路径更易被稳定触发。
        local ml
        ml=$(ini_get 'memory_limit' "$f")
        if [ "$ml" = "-1" ]; then
            ok "CFG" "$f: memory_limit=-1，符合 CVE-2026-109618 官方缓解措施（仍需确认 pool/应用未改回有限值）"
        elif [ -n "$ml" ]; then
            med "CFG" "$f: memory_limit=$ml，存在可由请求方稳定触发的 longjmp 中止路径；官方要求设为 -1（应用不可覆盖）以移除该路径"
        else
            med "CFG" "$f: 未显式设置 memory_limit（将采用默认 128M），官方要求设为 -1 以移除可控的 OOM 中止路径"
        fi

        # OPcache —— 官方缓解措施中未包含"关闭 OPcache"，仅作为暴露面提示
        local oc omt
        oc=$(ini_get 'opcache.enable' "$f")
        omt=$(ini_get 'opcache.validate_timestamps' "$f")
        if [ "$oc" = "1" ]; then
            info "CFG" "$f: opcache.enable=1，OPcache 跨请求共享内存处于启用状态（提示项：官方缓解措施未包含关闭 OPcache，禁用前请评估业务性能影响）"
        fi
        log INFO "CFG" "$f: opcache.enable=${oc:-未设置}, opcache.validate_timestamps=${omt:-未设置}"

        # session.upload_progress —— CVE-2026-109619 官方缓解措施
        local sup
        sup=$(ini_get 'session.upload_progress.enabled' "$f")
        if [ "$sup" = "1" ]; then
            med "CFG" "$f: session.upload_progress.enabled=1，官方缓解措施未落实（CVE-2026-109619：应设为 0 并重启所有 worker）"
        elif [ "$sup" = "0" ]; then
            ok "CFG" "$f: session.upload_progress.enabled=0，符合 CVE-2026-109619 官方缓解措施"
        fi

        # post_max_size —— CVE-2026-109618 官方缓解措施（收紧请求体）
        local pms ums pmb umb
        pms=$(ini_get 'post_max_size' "$f")
        ums=$(ini_get 'upload_max_filesize' "$f")
        log INFO "CFG" "$f: post_max_size=${pms:-默认}, upload_max_filesize=${ums:-默认}"
        if [ -n "$pms" ]; then
            pmb=$(size_to_bytes "$pms")
            if [ -n "$pmb" ] && [ "$pmb" -gt 33554432 ] 2>/dev/null; then
                med "CFG" "$f: post_max_size=$pms 偏大，官方建议收紧至 8M（无上传业务）/ 32M（需上传业务）"
            fi
        fi
        if [ -n "$pms" ] && [ -n "$ums" ]; then
            pmb=$(size_to_bytes "$pms")
            umb=$(size_to_bytes "$ums")
            if [ -n "$pmb" ] && [ -n "$umb" ] && [ "$umb" -ge "$pmb" ] 2>/dev/null; then
                low "CFG" "$f: upload_max_filesize($ums) 未小于 post_max_size($pms)，官方建议保持 upload_max_filesize 低于 post_max_size"
            fi
        fi

        # disable_functions / open_basedir（通用加固项）
        local df ob
        df=$(ini_get 'disable_functions' "$f")
        ob=$(ini_get 'open_basedir' "$f")
        log INFO "CFG" "$f: disable_functions=${df:-未设置}, open_basedir=${ob:-未设置}"
    done
    IFS="$oldifs"

    # php-fpm pool 配置
    local pools pf
    pools=$(ls /etc/php-fpm.d/*.conf /usr/local/etc/php-fpm.d/*.conf /usr/local/etc/php-fpm/*.conf \
                /etc/php/*/fpm/pool.d/*.conf /etc/php-fpm.d/*.conf 2>/dev/null | sort -u)
    if [ -n "$pools" ]; then
        log INFO "CFG" "php-fpm pool 配置: $(printf '%s' "$pools" | tr '\n' ' ')"
        oldifs="$IFS"; IFS=$'\n'
        for pf in $pools; do
            [ -r "$pf" ] || continue
            local listen pmr
            listen=$(ini_get 'listen' "$pf")
            pmr=$(ini_get 'pm.max_requests' "$pf")
            log INFO "CFG" "  $(basename "$pf"): listen=${listen:-默认}, pm.max_requests=${pmr:-默认}"
            # listen 未指定地址时 PHP-FPM 监听所有网卡（0.0.0.0），裸端口写法极易被忽略
            if fpm_listen_exposed "$listen"; then
                FPM_EXPOSED=1
            fi
            if [ "$FPM_EXPOSED" -eq 1 ]; then
                if [ "$VULN_FOUND" -eq 1 ]; then
                    high "CFG" "$pf: FPM 监听 ${listen:-默认}（未限定回环地址/未使用 socket），外部可直接发起 FastCGI 协议攻击"
                else
                    med "CFG" "$pf: FPM 监听 ${listen:-默认}（未限定回环地址/未使用 socket），建议改为 127.0.0.1 或 Unix socket"
                fi
            else
                ok "CFG" "$pf: FPM 监听 ${listen:-默认}（仅本机可达）"
            fi

            # pool 中以 php_admin_value / php_value 设置的 memory_limit 会覆盖 php.ini
            local pml
            pml=$(grep -E '^[[:space:]]*php_(admin_)?value\[memory_limit\][[:space:]]*=' "$pf" 2>/dev/null \
                  | tail -n1 | cut -d= -f2- | tr -d ' ')
            if [ -n "$pml" ] && [ "$pml" != "-1" ]; then
                med "CFG" "$pf: pool 中设置了 php_value[memory_limit]=$pml，会覆盖 php.ini 的设置；官方要求 memory_limit=-1 且应用不可覆盖"
            elif [ -n "$pml" ]; then
                ok "CFG" "$pf: pool 中 memory_limit=-1，符合官方缓解措施"
            fi

            if [ "$pmr" = "0" ]; then
                med "CFG" "$pf: pm.max_requests=0（不限制），长驻 worker 存活期长，陈旧全局状态风险更大（通用加固项，建议配合官方'重启所有 worker'要求）"
            fi
        done
        IFS="$oldifs"
    fi
}

#===============================================================================
# 7. PHP 应用与静态演示文件扫描
#===============================================================================
scan_php_apps() {
    section "7. PHP 应用 / 静态演示文件扫描"
    local roots
    roots=$(collect_web_roots)
    if [ -z "$roots" ]; then
        info "APP" "未定位到 Web 根目录，跳过应用层扫描（可用 --web-root 手动指定）"
        return
    fi
    log INFO "APP" "待扫描根目录: $(printf '%s' "$roots" | tr '\n' ' ')"

    local oldifs="$IFS"
    IFS=$'\n'
    local root total hits bak cms h b
    for root in $roots; do
        [ -d "$root" ] || continue
        total=$(find "$root" -maxdepth "$MAX_DEPTH" -type f -name '*.php' 2>/dev/null | wc -l | tr -d ' ')
        log INFO "APP" "$root: PHP 文件 $total 个"

        # 演示 / 测试 / 信息泄露页
        hits=$(find "$root" -maxdepth "$MAX_DEPTH" -type f -name '*.php' 2>/dev/null \
                | while IFS= read -r f; do
                    if is_demo_php_name "$(basename "$f")"; then
                        printf '%s\n' "$f"
                    fi
                done)
        if [ -n "$hits" ]; then
            high "APP" "$root 存在疑似演示/测试/信息泄露 PHP 文件（可用于探测与放大漏洞）"
            for h in $hits; do log INFO "APP" "  $h"; done
        fi

        # 备份 / 源码泄露文件
        bak=$(find "$root" -maxdepth "$MAX_DEPTH" -type f \( -name '*.php.bak' -o -name '*.php~' \
                -o -name '*.php.old' -o -name '*.php.save' -o -name '*.phps' -o -name '*.inc.php' \
                -o -name '*.php.orig' -o -name '*.php.dist' \) 2>/dev/null | head -n30)
        if [ -n "$bak" ]; then
            med "APP" "$root 存在备份 / 源码泄露文件"
            for b in $bak; do log INFO "APP" "  $b"; done
        fi

        # 应用指纹
        cms=$(detect_cms "$root")
        if [ -n "$cms" ]; then
            log INFO "APP" "$root 应用指纹: $(printf '%s' "$cms" | tr '\n' ' ')"
        fi
    done
    IFS="$oldifs"
}

# 收集 Web 根目录
collect_web_roots() {
    local r d out
    out=$(
        {
            # Apache DocumentRoot
            grep -rhoiE '^[[:space:]]*DocumentRoot[[:space:]]+"[^"]+"' /etc/httpd /etc/apache2 /usr/local/apache2 2>/dev/null \
                | sed -E 's/.*"([^"]+)".*/\1/'
            # nginx root
            grep -rhoiE '^[[:space:]]*root[[:space:]]+[^;]+;' /etc/nginx /usr/local/nginx/conf 2>/dev/null \
                | awk '{print $2}' | tr -d ';'
            # 常见默认值
            echo /var/www/html
            echo /var/www
            echo /usr/share/nginx/html
            echo /usr/local/nginx/html
            echo /srv/www
            echo /home/www
            echo /www/wwwroot
            echo /opt/app
            # 用户附加
            for r in $EXTRA_ROOTS; do echo "$r"; done
        } | sed 's|/*$|/|' | sort -u
    )
    for d in $out; do
        [ -d "$d" ] && echo "$d"
    done
    return 0
}

# 应用指纹识别
detect_cms() {
    local root="$1" out=""
    if [ -f "$root/wp-config.php" ]; then
        out="$out WordPress"
    elif [ -d "$root/wp-content" ]; then
        out="$out WordPress(content)"
    fi
    [ -f "$root/configuration.php" ] && out="$out Joomla"
    [ -f "$root/index.php" ] && [ -d "$root/core" ] && out="$out Drupal"
    [ -f "$root/artisan" ] && out="$out Laravel"
    [ -d "$root/thinkphp" ] && out="$out ThinkPHP"
    [ -f "$root/think" ] && out="$out ThinkPHP"
    [ -f "$root/composer.json" ] && out="$out Composer项目"
    [ -f "$root/composer.lock" ] && out="$out Composer.lock"
    [ -d "$root/phpmyadmin" ] && out="$out phpMyAdmin"
    [ -d "$root/mediawiki" ] && out="$out MediaWiki"
    [ -d "$root/yii" ] && out="$out Yii"
    [ -f "$root/config.php" ] && [ -d "$root/sites" ] && out="$out Drupal(config)"
    [ -d "$root/Discuz" ] && out="$out Discuz"
    [ -f "$root/index.php" ] && [ -d "$root/admin" ] && out="$out 后台管理类应用"
    printf '%s' "$out" | tr -s ' ' | sed 's/^ //'
    return 0
}

#===============================================================================
# 8. Docker / 容器中的 PHP 镜像
#===============================================================================
scan_docker() {
    section "8. Docker / 容器 PHP 镜像扫描"
    if [ "$DO_DOCKER" -eq 0 ]; then
        info "DOCKER" "已按参数跳过容器扫描"
        return
    fi
    local docker_bin=""
    if have docker; then docker_bin="docker"; elif have podman; then docker_bin="podman"; fi
    if [ -z "$docker_bin" ]; then
        info "DOCKER" "未安装 docker/podman"
        return
    fi
    log INFO "DOCKER" "容器运行时: $docker_bin"

    if ! $docker_bin info >/dev/null 2>&1; then
        med "DOCKER" "$docker_bin 无法连接守护进程（权限不足或服务未运行），跳过镜像扫描"
        return
    fi

    local oldifs="$IFS"
    IFS=$'\n'
    local imgs total i v verdict cs c
    imgs=$($docker_bin images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i 'php' | sort -u)
    if [ -z "$imgs" ]; then
        info "DOCKER" "未发现名称含 php 的本地镜像"
    else
        total=$(printf '%s\n' "$imgs" | grep -c '[a-zA-Z]')
        info "DOCKER" "发现 $total 个 PHP 相关本地镜像，逐个判定版本："
        for i in $imgs; do
            [ -z "$i" ] && continue
            # 优先取 tag 中的版本号（取最后一个冒号之后）；tag 形如 latest/fpm/alpine 时无版本，需 --deep 探测
            v=$(extract_image_version "$i")
            if [ -n "$v" ]; then
                log INFO "DOCKER" "  $i (版本 $v)"
                parse_version "$v" || continue
                verdict=$(php_branch_verdict "$V_MAJ" "$V_MIN" "$V_PAT" "$V_HAS_PAT")
                case "$verdict" in
                    vulnerable) VULN_FOUND=1; high "DOCKER" "镜像 $i 版本 $v 低于该分支修复版本，运行即受 PHP2Shell 影响" ;;
                    nofix)      NOFIX_FOUND=1; VULN_FOUND=1; crit "DOCKER" "镜像 $i 版本 $v 分支无官方修复版本" ;;
                    backport)   VULN_FOUND=1; med  "DOCKER" "镜像 $i 版本 $v 分支无官方修复发行版，需确认基础镜像是否已回补" ;;
                    minor_only) info "DOCKER" "镜像 $i 标签仅含主.次版本（$V_MAJ.$V_MIN），patch 未知，需 --deep 探测实际 PHP 版本" ;;
                    safe)      ok   "DOCKER" "镜像 $i 版本 $v 不低于该分支修复版本" ;;
                    unknown)   info "DOCKER" "镜像 $i 版本 $v 分支未知，需人工确认" ;;
                esac
            else
                log INFO "DOCKER" "  $i (标签中无版本号，需用 --deep 探测实际 PHP 版本)"
            fi
        done
    fi

    # 容器实例
    cs=$($docker_bin ps -a --format '{{.Names}}	{{.Image}}	{{.Status}}' 2>/dev/null | grep -i 'php')
    if [ -n "$cs" ]; then
        info "DOCKER" "发现使用 PHP 镜像的容器实例（版本风险见上方镜像判定）："
        for c in $cs; do log INFO "DOCKER" "  $c"; done
    else
        info "DOCKER" "未发现使用 PHP 镜像的容器实例"
    fi
    IFS="$oldifs"

    # 深度模式：读取镜像内 PHP 真实版本
    if [ "$DEEP" -eq 1 ]; then
        log INFO "DOCKER" "深度模式：探测镜像内 PHP 版本（会创建并立即删除临时容器，--network none 不联网、不挂载卷）"
        local all_imgs probe_cnt=0
        all_imgs=$($docker_bin images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u)
        oldifs="$IFS"; IFS=$'\n'
        for i in $all_imgs; do
            [ -z "$i" ] && continue
            probe_cnt=$((probe_cnt+1))
            local iv pv
            iv=$($docker_bin run --rm --network none --entrypoint php "$i" -v 2>/dev/null | head -n1)
            [ -z "$iv" ] && continue
            log INFO "DOCKER" "  镜像 $i 内 PHP: $iv"
            pv=$(printf '%s' "$iv" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
            report_php_version "$pv" "镜像 $i 内 PHP" "DOCKER"
        done
        IFS="$oldifs"
        log INFO "DOCKER" "深度模式共探测 $probe_cnt 个镜像"
    elif [ -n "$imgs" ]; then
        info "DOCKER" "提示：加 --deep 参数可探测全部镜像（含自建镜像）内的 PHP 真实版本"
    fi
}

#===============================================================================
# 9. 修复建议
#===============================================================================
print_remediation() {
    section "修复建议"
    cat <<'EOF'
  [必做] 升级 PHP 到已修复版本并重启服务（官方声明：无完整缓解措施，升级是唯一安全选择）：
           8.2 分支 -> >= 8.2.35（该分支将于 2026-12-31 EOL，请规划升级）
           8.3 分支 -> >= 8.3.36
           8.4 分支 -> >= 8.4.27
           8.5 分支 -> >= 8.5.12
         升级后重启 php-fpm 与 apache/nginx，确保新进程生效。

  [必做] 8.1 及更早分支上游不再更新：
           优先迁移到 8.3.36+ / 8.4.27+ / 8.5.12+；
           若短期无法迁移，需向发行版 / LTS 供应商确认是否已回补
           CVE-2026-109618 / CVE-2026-109619。

  [必做] 所有 PHP Docker 镜像重建为已修复基础镜像，并重新部署容器。

  [官方缓解-CVE-2026-109618] OOM 内存破坏路径：
           1. memory_limit 设为 -1，且应用不可覆盖（php.ini + FPM pool 的
              php_admin_value[memory_limit]，并确认没有任何 pool / 目录 / 应用
              设置把它改回有限值）。注意：有限的 memory_limit 反而提供了
              攻击者可稳定触发的 longjmp 中止路径，不要反向操作；
           2. 收紧 post_max_size：不需要文件上传的业务设 8M，需要上传设 32M；
              保持 upload_max_filesize 低于 post_max_size；
           3. 在 Web / 代理层限制解码后的请求体积、输入字段数、multipart 分段数、
              头部数量与嵌套深度；
           4. 不要用 RLIMIT_AS / RLIMIT_DATA 替代 memory_limit，这会诱发
              真实的分配失败路径。

  [官方缓解-CVE-2026-109619] 陈旧全局状态（use-after-free）：
           1. session.upload_progress.enabled=0（下一个常规 bugfix 版本前保持关闭）；
           2. 修改配置后重启所有 worker；
           3. 修复攻击者可达的致命错误与执行超时，包括回调、上传 / 导入处理
              以及清理流程中的失败。

  [通用加固] 非官方缓解措施，仅降低整体风险：
           1. 关闭 display_errors / expose_php（注意：官方明确说明隐藏诊断信息
              并不能缓解 PHP2Shell，此项仅为通用信息泄露防护）；
           2. FPM listen 改为 127.0.0.1 或 Unix socket，禁止 9000 端口外网暴露；
           3. 设置 pm.max_requests 缩短 worker 存活期；
           4. 删除 Web 根目录下的 phpinfo.php / test.php / demo 等演示文件与 .bak 备份；
           5. 关于 OPcache：官方缓解措施未包含关闭 OPcache，禁用前请评估性能影响。

  [监控] 排查是否已被利用：检查 Web 访问日志中异常的 Content-Length、
         突发 500/502、进程 OOM 与 core dump、异常出站连接与反弹 Shell 行为；
         PHP 官方与多国 CERT 均提示该漏洞的 PoC 已广泛传播、利用正在快速演进。

  [参考]
         https://www.php.net/archive/2026.php#2026-10-21-5
         https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w
         https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp
EOF
}

#===============================================================================
# 主流程
#===============================================================================
main() {
    printf '%s\n' "$C_BLD==== PHP2Shell 漏洞风险扫描 (PHP2Shell Scan) v2.0.0 ====$C_OFF"
    log INFO "SCAN" "开始时间 $(date '+%Y-%m-%d %H:%M:%S')"
    log INFO "SCAN" "主机 $(hostname 2>/dev/null)  执行身份 $(id -un 2>/dev/null)  扫描器版本 2.0.0"
    log INFO "SCAN" "报告文件: $REPORT_FILE"
    log INFO "SCAN" "漏洞参考: CVE-2026-109618 (OOM 内存破坏) / CVE-2026-109619 (陈旧全局状态 UAF)"

    scan_os
    detect_pm
    scan_php_runtime
    scan_extra_cves
    scan_web_server
    scan_php_config
    [ "$SCAN_WEB" -eq 1 ] && scan_php_apps
    [ "$DO_DOCKER" -eq 1 ] && scan_docker

    section "扫描结果汇总"
    printf '  严重(Critical) : %s\n' "$CNT_CRIT"
    printf '  高危(High)     : %s\n' "$CNT_HIGH"
    printf '  中危(Medium)   : %s\n' "$CNT_MED"
    printf '  低危(Low)      : %s\n' "$CNT_LOW"
    printf '  提示(Info)     : %s\n' "$CNT_INFO"
    printf '  报告文件       : %s\n' "$REPORT_FILE"

    section "总体结论"
    if [ "$NOFIX_FOUND" -eq 1 ]; then
        printf '  %s[危险]%s 存在官方无修复分支的 PHP（上游已停止维护），必须迁移或下线。\n' "$C_RED$C_BLD" "$C_OFF"
    elif [ "$VULN_FOUND" -eq 1 ]; then
        printf '  %s[危险]%s 存在低于修复版本的 PHP 或待确认回补的分支，请立即按修复建议升级。\n' "$C_RED$C_BLD" "$C_OFF"
    else
        printf '  %s[良好]%s 未发现低于官方修复版本的 PHP；仍建议复核中危项并落实官方缓解措施。\n' "$C_GRN$C_BLD" "$C_OFF"
    fi
    if [ "$FPM_EXPOSED" -eq 1 ]; then
        printf '  提示: FPM 对外监听已暴露，建议改为 127.0.0.1 或 Unix socket。\n'
    fi
    if [ "$MODPHP_FOUND" -eq 1 ]; then
        printf '  提示: 存在 mod_php 部署，官方指出其为受影响面最大的部署形态。\n'
    fi

    print_remediation

    log INFO "SCAN" "结束时间 $(date '+%Y-%m-%d %H:%M:%S')"

    if [ "$CNT_CRIT" -gt 0 ] || [ "$CNT_HIGH" -gt 0 ]; then
        printf '\n%s[结论] 存在 CRITICAL/HIGH 风险，请立即按修复建议处置。%s\n' "$C_RED$C_BLD" "$C_OFF"
        exit 1
    else
        printf '\n%s[结论] 未发现 CRITICAL/HIGH 级风险，仍建议复核 MEDIUM 项。%s\n' "$C_GRN$C_BLD" "$C_OFF"
        exit 0
    fi
}

main "$@"
