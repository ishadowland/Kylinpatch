#!/bin/bash
#===============================================================================
# php2shell_scan.sh  (v3.2.0)
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
#   8.2 分支 -> 8.2.35（该分支将于 2026-12-31 EOL）
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
#             禁用 OPcache 不在官方缓解措施内；不要用 RLIMIT_AS / RLIMIT_DATA
#             替代 memory_limit。
#
# 兼容：麒麟 V10 (Kylin V10) / CentOS 7,8 / RHEL / SUSE 11,12 / Debian 系
# 约束：Bash 3.x 语法（不使用关联数组、mapfile、${var^^}/${var,,}）
#       【重要】bash 3.2 无法解析命令替换内的 case 语句，本脚本已规避
#       所有外部命令均做存在性检测；无 docker/ss/systemctl 时自动降级
#       所有遍历均使用 for 循环，避免管道子 shell 导致风险计数丢失
#
# 用法：bash php2shell_scan.sh [选项]   （详见 --help）
#
# v3.2.0 变更（对应 issue #13：非 PATH 部署整机漏检）：
#   背景：禅道 zbox 等一体化部署把 Apache / PHP / MySQL / Redis 全部放在
#         /opt/<产品> 下，既不进 PATH、也不注册 systemd 服务（由自带的
#         zbox 脚本管理）。旧版只按"发行版标准路径 + PATH"探测，于是整机被
#         误判为"无 PHP 运行时 / 安全"，连 80 端口的 httpd 都没被识别。
#   #13 a) 新增进程反查（/proc/<pid>/exe），按正在运行的进程定位 httpd /
#          nginx / php 的真实二进制，覆盖任何非常规部署；
#       b) PHP 候选路径补充 /opt/*/run/php、/opt/*/bin、/opt/lampp、
#          宝塔 /www/server/php 等一体化布局；
#       c) php.ini 改用 `php --ini` 的 "Loaded Configuration File" 定位，
#          并加载其 conf.d 目录，不再依赖固定路径列表；
#       d) Web 根目录改为解析 Apache 的 DocumentRoot 与 Alias 目标
#          （如 Alias /zentao -> /opt/zbox/app/zentao/www/）；
#       e) 应用指纹新增禅道（ZenTao）；
#       f) 7.4 / 8.0 / 8.1 若不属于任何系统软件包（厂商自带 / 源码编译，
#          无发行版回补渠道），由中危上调为高危；
#       g) 新增常驻 PHP 应用进程识别（RoadRunner、队列 worker 等），
#          补足 CVE-2026-109619 陈旧全局状态的暴露面。
#
# v3.1.0 变更（对应 issue #3 - #12，均已在麒麟 V10 + Docker 18.09 + podman 0.10.1 上验证）：
#   #3  session.upload_progress.enabled 缺失/被注释时不再静默，按"默认 1/On"判定为未落实；
#       同时新增 ini_bool 归一化 On/Off/1/0，修复 display_errors / expose_php / opcache 判定
#   #4  FPM 9000 暴露不再被第 5 节（端口）与第 6 节（pool 配置）重复计数，风险条目统一由
#       pool listen 判定给出；未找到对应 pool 配置时才在第 6 节兜底告警
#   #5  收集 Web 根目录时剔除嵌套子目录（如 /var/www/html），同一批文件不再被重复扫描
#   #6  应用指纹识别要求文件非空 / 目录非空，空文件不再被判定为 WordPress 等应用
#   #7  镜像 tag 版本解析优先取 php 关键字后的版本号，避免把应用版本（如 6.4）当 PHP 版本
#   #8  容器实例不再按名称过滤，并新增"运行中容器内 php -v"只读探测，非 php 命名的
#       WordPress 等容器不再漏检
#   #9  演示/测试文件名黑名单增加二次判定（路径 + 内容），应用自带文件不再误报 HIGH
#   #10 结论增加"待确认"档，仅命中中危项时不再输出"安全/不存在攻击面"
#   #11 --deep 改为显式 create + start -a + rm -f，podman 0.10 下不再残留孤儿容器
#   #12 phpize / php-config / phpdbg / phar 等辅助工具不再被当作 PHP 运行时
#   另：CVE-2024-4577 判定补充 8.0 分支（修复版本 8.0.30）
#===============================================================================

#------------------------------- 默认配置 ---------------------------------------
REPORT_FILE=""            # 报告输出文件，空则自动生成
EXTRA_ROOTS=""            # 额外扫描的 Web 根目录（空格分隔）
DO_DOCKER=1               # 是否扫描容器
DEEP=0                    # 深度模式：允许 docker run 探测容器内 PHP 版本
SCAN_WEB=1                # 是否扫描 Web 目录
NO_COLOR=0
MAX_DEPTH=6               # Web 目录扫描深度
IS_ROOT=0                 # 是否以 root 运行（影响扫描完整度）

# 严重级别统计（bash3 兼容，不使用关联数组）
CNT_CRIT=0
CNT_HIGH=0
CNT_MED=0
CNT_LOW=0
CNT_INFO=0

# 风险条目明细（按级别累积，每行 "标签|描述"，用于结论中逐条列出）
FIND_CRIT=""
FIND_HIGH=""
FIND_MED=""
FIND_LOW=""

# 修复建议主题（空格分隔，仅在命中对应风险时才生成建议）
REMED_TOPICS=""

# 全局风险标记：用于把"暴露面"与"真实可利用性"关联，避免无谓的 HIGH 噪声
VULN_FOUND=0              # 发现低于修复版本的 PHP
NOFIX_FOUND=0             # 发现官方无修复分支的 PHP
FPM_EXPOSED=0             # 发现对外监听的 FPM
FPM_PORT_9000=0           # 发现 9000 端口处于监听（可能为 php-fpm，配置侧判定见第 6 节）
MODPHP_FOUND=0            # 发现 mod_php 部署

# 进程反查缓存：用于识别不进 PATH、不注册 systemd 的一体化部署（禅道 zbox 等）
PROC_CACHE_DONE=0
PROC_HTTPD_LIST=""        # 运行中的 httpd / apache2 可执行文件绝对路径
PROC_NGINX_LIST=""        # 运行中的 nginx 可执行文件绝对路径
PROC_PHP_LIST=""          # 运行中的 php / php-fpm / php-cgi 可执行文件绝对路径
PROC_PHP_WORKERS=""       # "pid|命令行" 形式的长驻 PHP 应用进程（RoadRunner / 队列 worker 等）
PHP_BINS_FOUND=""         # 第 3 节实际发现的 PHP 可执行文件，供第 6 节定位 php.ini

#------------------------------- 颜色与输出 -------------------------------------
# 使用 ANSI-C 引用，生成真实 ESC 字符（$'\033' 为 bash 2.0+ 语法，兼容 bash 3.x）
# 注意：单引号里的 '\033' 只是字面反斜杠，printf '%s' 不解释它，颜色会失效
if [ -t 1 ] && [ "$NO_COLOR" -eq 0 ]; then
    C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'
    C_BLU=$'\033[1;34m'; C_GRY=$'\033[0;37m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_YEL=''; C_GRN=''; C_BLU=''; C_GRY=''; C_BLD=''; C_OFF=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log_target() {
    if [ -n "$REPORT_FILE" ]; then
        printf '%s\n' "$*" >> "$REPORT_FILE" 2>/dev/null
    fi
}

# 记录修复建议主题（去重，bash3 兼容用字符串匹配）
add_topic() {
    case " $REMED_TOPICS " in
        *" $1 "*) return 0 ;;
    esac
    REMED_TOPICS="$REMED_TOPICS $1"
}

# log LEVEL TAG MESSAGE
log() {
    local level="$1"; shift
    local tag="$1"; shift
    local msg="$*"
    local color=""
    case "$level" in
        CRIT) color="$C_RED"; CNT_CRIT=$((CNT_CRIT+1)); FIND_CRIT="${FIND_CRIT}${tag}|${msg}"$'\n' ;;
        HIGH) color="$C_RED"; CNT_HIGH=$((CNT_HIGH+1)); FIND_HIGH="${FIND_HIGH}${tag}|${msg}"$'\n' ;;
        MED ) color="$C_YEL"; CNT_MED=$((CNT_MED+1));  FIND_MED="${FIND_MED}${tag}|${msg}"$'\n' ;;
        LOW ) color="$C_BLU"; CNT_LOW=$((CNT_LOW+1));  FIND_LOW="${FIND_LOW}${tag}|${msg}"$'\n' ;;
        INFO) color="$C_GRY"; CNT_INFO=$((CNT_INFO+1));;
        OK  ) color="$C_GRN";;
        STEP) color="$C_BLD$C_BLU";;
        *   ) color="";;
    esac
    # stdout 带颜色，报告文件保持纯文本（便于 grep / 二次解析）；时间戳只取一次
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
  --deep            深度模式：使用 docker run 探测全部镜像（含自建镜像）内的
                    PHP 真实版本。会创建并立即删除临时容器（--network none，
                    不联网、不挂载卷），仅用于取版本号；这是本脚本唯一会产生
                    副作用的动作，默认关闭
  --skip-docker     跳过容器扫描
  --skip-web        跳过 Web 目录与 PHP 应用扫描
  --max-depth N     Web 目录递归深度，默认 6
  --no-color        关闭彩色输出
  -h, --help        显示本帮助

退出码:
  0 = 未发现 CRIT/HIGH 风险
  1 = 发现 CRIT/HIGH 风险
  2 = 执行错误

只读保证：脚本不安装软件、不启停服务、不修改任何配置或业务数据，
          唯一写入是报告日志文件。

提示：非 root 运行会导致部分目录不可读、docker 守护进程无法访问、
      监听端口缺少进程信息，脚本会明确提示并建议以 root 复扫。

参考:
  https://www.php.net/archive/2026.php#2026-10-21-5
  https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w
  https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp
EOF
}

ORIG_ARGS="$*"            # 原始参数，供"以 root 复扫"提示复用

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
            add_topic "upgrade"
            high "$kind" "$where 版本 $v 低于该分支修复版本，受 CVE-2026-109618/109619 影响"
            ;;
        nofix)
            NOFIX_FOUND=1
            VULN_FOUND=1
            add_topic "eol"
            crit "$kind" "$where 版本 $v 所属分支（$V_MAJ.$V_MIN）上游已停止维护且无修复版本，长期暴露"
            ;;
        backport)
            VULN_FOUND=1
            add_topic "backport"
            # 7.4 / 8.0 / 8.1 上游已不再发布安全版本，唯一修复渠道是发行版回补。
            # 若该二进制不属于任何发行版软件包（厂商自带一体化包 / 源码编译），
            # 就不存在回补渠道，风险等同"无修复"，必须由中危上调为高危。
            local bpath=""
            case "$where" in
                "运行时 "*) bpath="${where#运行时 }" ;;
            esac
            if [ -n "$bpath" ] && [ -x "$bpath" ] && ! bin_is_packaged "$bpath"; then
                add_topic "vendor_php"
                add_topic "upgrade"
                high "$kind" "$where 版本 $v 所属分支（$V_MAJ.$V_MIN）上游无修复发行版，且该二进制不属于任何系统软件包（厂商自带/源码编译），没有回补渠道，等同无修复"
            else
                med "$kind" "$where 版本 $v 所属分支（$V_MAJ.$V_MIN）上游无修复发行版，需确认发行版是否回补"
            fi
            ;;
        safe)
            ok "$kind" "$where 版本 $v 不低于该分支修复版本"
            ;;
        minor_only)
            add_topic "verify"
            info "$kind" "$where 标签仅含主.次版本（$V_MAJ.$V_MIN），无法判定 patch，需 --deep 探测或进容器确认"
            ;;
        *)
            add_topic "verify"
            info "$kind" "$where 版本 $v（分支未知，需人工确认是否受影响）"
            ;;
    esac
    return 0
}

#------------------------------- 采集工具 ---------------------------------------
# phpize / php-config / phpdbg / phar 等是辅助工具，不能报告 PHP 版本，
# 必须排除，否则会被误当作 PHP 运行时（例如 phpize -v 输出 "Can't find PHP headers"）
# 另外扫描脚本自身（php2shell_scan.sh）若被安装到 /usr/local/bin 等目录，
# 也会被 /usr/local/bin/php* 通配命中，同样需要排除
is_php_helper_tool() {
    local p="$1"
    case "${p##*/}" in
        phpize|php-config|phpdbg|phar|phpcp|phpize*|php-config*) return 0 ;;
        php2shell*|php2shell_scan*) return 0 ;;
    esac
    return 1
}

# 查找 PATH 中及常见目录下的 php 可执行文件
find_php_bins() {
    local b
    for b in php php-cli php-fpm php-cgi php-fpm8.5 php-fpm8.4 php-fpm8.3 php-fpm8.2 \
             php-fpm8.1 php-fpm8.0 php-cgi8.3 php8.5 php8.4 php8.3 php8.2 php8.1 php8.0; do
        if have "$b"; then
            command -v "$b"
        fi
    done
    # 常见安装位置（源码编译、自建、面板安装、一体化部署等）
    # /opt/*/run/php、/opt/*/bin：禅道 zbox、XAMPP 类一体化包（无 bin 子目录）
    for p in /usr/local/php*/bin/php /usr/local/php-*/bin/php /usr/local/php*/bin/php-fpm \
             /usr/local/php-*/bin/php-fpm /usr/local/php*/bin/php-cgi /usr/local/php*/sbin/php-fpm \
             /opt/php*/bin/php /opt/php-*/bin/php /opt/php*/sbin/php-fpm \
             /opt/*/run/php/php /opt/*/run/php/php-fpm /opt/*/run/php/php-cgi /opt/*/bin/php \
             /opt/lampp/bin/php* /www/server/php/*/bin/php* \
             /usr/local/bin/php* /usr/local/sbin/php-fpm* /usr/local/sbin/php-cgi* \
             /usr/bin/php* /usr/sbin/php-fpm* /usr/sbin/php-cgi* /usr/lib/cgi-bin/php* \
             /opt/1panel/versions/*/php*/bin/php /www/server/php/*/bin/php; do
        is_php_helper_tool "$p" && continue
        [ -x "$p" ] && printf '%s\n' "$p"
    done 2>/dev/null
    # 进程反查：覆盖不进 PATH、未注册 systemd 的一体化部署（禅道 zbox / XAMPP / 面板）
    proc_cache_build
    for p in $PROC_PHP_LIST; do
        is_php_helper_tool "$p" && continue
        [ -x "$p" ] && printf '%s\n' "$p"
    done
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

# 建立"进程 -> 可执行文件"反查缓存
# 背景：一体化部署（禅道 zbox、XAMPP、面板）把 httpd / php 放在 /opt 或 /www 下，
#       既不在 PATH，也不注册 systemd 服务，唯一可靠的线索是正在运行的进程。
#       缓存只构建一次，后续各节复用（子 shell 会继承已完成的标记与结果）。
proc_cache_build() {
    [ "$PROC_CACHE_DONE" -eq 1 ] && return 0
    PROC_CACHE_DONE=1
    local d pid exe base cmd
    for d in /proc/[0-9]*; do
        [ -d "$d" ] || continue
        exe=$(readlink -f "$d/exe" 2>/dev/null)
        [ -n "$exe" ] || exe=$(readlink "$d/exe" 2>/dev/null)
        [ -n "$exe" ] || continue
        # 二进制被覆盖/删除后 exe 会带 " (deleted)" 后缀，去掉后仍可用于定位目录
        case "$exe" in
            *" (deleted)") exe="${exe% (deleted)}" ;;
        esac
        base="${exe##*/}"
        case "$base" in
            httpd|apache2)
                PROC_HTTPD_LIST="$PROC_HTTPD_LIST$exe"$'\n'
                ;;
            nginx)
                PROC_NGINX_LIST="$PROC_NGINX_LIST$exe"$'\n'
                ;;
            php|php[0-9]*|php-fpm*|php-cgi*)
                PROC_PHP_LIST="$PROC_PHP_LIST$exe"$'\n'
                # 仅记录"跑脚本"的常驻进程（php-fpm master 无脚本参数，另行判定）
                pid="${d#/proc/}"
                cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null | cut -c1-200)
                case "$cmd" in
                    *".php"*) PROC_PHP_WORKERS="$PROC_PHP_WORKERS$pid|$cmd"$'\n' ;;
                esac
                ;;
        esac
    done
    PROC_HTTPD_LIST=$(printf '%s' "$PROC_HTTPD_LIST" | grep -v '^$' | sort -u)
    PROC_NGINX_LIST=$(printf '%s' "$PROC_NGINX_LIST" | grep -v '^$' | sort -u)
    PROC_PHP_LIST=$(printf '%s' "$PROC_PHP_LIST" | grep -v '^$' | sort -u)
    return 0
}

# 列出可读的 Apache 主配置文件（含一体化部署的非常规路径）
apache_conf_files() {
    ls /etc/httpd/conf/httpd.conf /etc/apache2/apache2.conf \
       /usr/local/apache2/conf/httpd.conf /www/server/apache/conf/httpd.conf \
       /opt/lampp/etc/httpd.conf /opt/*/etc/apache/httpd.conf \
       /opt/*/etc/apache2/apache2.conf /opt/*/run/apache/conf/httpd.conf \
       /opt/*/conf/httpd.conf 2>/dev/null | sort -u
}

# 由 httpd 二进制推断其主配置文件（/opt/<产品>/run/apache/httpd -> /opt/<产品>/etc/apache/httpd.conf）
apache_primary_conf() {
    local bin="$1" d c
    case "$bin" in
        */run/apache/*)
            d="${bin%%/run/apache/*}"
            if [ -f "$d/etc/apache/httpd.conf" ]; then
                printf '%s' "$d/etc/apache/httpd.conf"
                return 0
            fi
            ;;
    esac
    for c in $(apache_conf_files); do
        printf '%s' "$c"
        return 0
    done
    return 0
}

# 解析 Apache 配置中的 DocumentRoot 与 Alias 目标
# （应用可能挂在 Alias 上，如 Alias /zentao -> /opt/zbox/app/zentao/www/）
apache_web_roots() {
    local conf
    for conf in $(apache_conf_files); do
        [ -r "$conf" ] || continue
        grep -hiE '^[[:space:]]*DocumentRoot[[:space:]]' "$conf" 2>/dev/null \
            | awk '{print $2}' | tr -d '"'
        grep -hiE '^[[:space:]]*Alias[[:space:]]' "$conf" 2>/dev/null \
            | awk '{print $NF}' | tr -d '"'
    done
    return 0
}

# php --ini 输出的 "Loaded Configuration File"（最可靠，覆盖任意自定义路径）
php_ini_file() {
    "$1" --ini 2>/dev/null | sed -n 's/^Loaded Configuration File:[[:space:]]*//p' | head -n1
}

# php --ini 输出的附加 ini 扫描目录（通常是 conf.d）
php_ini_scan_dir() {
    local d
    d=$("$1" --ini 2>/dev/null | sed -n 's/^Scan for additional .ini files in:[[:space:]]*//p' | head -n1)
    case "$d" in
        "(none)"|"") return 0 ;;
    esac
    printf '%s' "$d"
}

# 可执行文件是否由发行版包管理器提供（0=属于软件包；1=厂商自带 / 源码编译）
# 用途：7.4/8.0/8.1 上游已无修复版本，只有发行版回补一条路；
#       不属于任何软件包就说明没有回补渠道，风险应上调。
bin_is_packaged() {
    local p="$1"
    [ -n "$p" ] || return 1
    case "$PM" in
        rpm) rpm -qf "$p" >/dev/null 2>&1 ;;
        deb) dpkg -S "$p" >/dev/null 2>&1 ;;
        *)   return 1 ;;
    esac
}

# 输出 php 二进制版本行
# 注意：CLI 下 display_errors=On 时，加载扩展的告警（如 "Module 'xlswriter'
#       already loaded"）会写到 stdout，排在版本行之前，甚至前面还有空行。
#       直接 head -n1 会取到空行/告警行，导致版本判定为"读取失败"从而漏报整机
#       （见 issue #13 实测：PHP 7.4.33 + 重复扩展告警）。
php_bin_version() {
    local bin="$1"
    "$bin" -v 2>/dev/null | grep -m1 -E 'PHP[[:space:]]+[0-9]+\.[0-9]+'
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

# ini_bool VALUE -> 把 On/Off/True/False/1/0/yes/no 归一化为 1/0，无法识别返回空
# php.ini 中布尔项既可能写成 On/Off，也可能写成 1/0，需要统一处理
ini_bool() {
    local v="$1"
    case "$(printf '%s' "$v" | tr 'A-Z' 'a-z')" in
        on|true|yes|1) printf '1' ;;
        off|false|no|0) printf '0' ;;
    esac
    return 0
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
# 重要：复合 tag（如 wordpress:6.4-php8.2-apache、wordpress:4.9.8-php5.6-apache）
#       同时包含"应用版本"和"PHP 版本"，必须优先取 php 关键字后面的版本号，
#       否则会把应用版本当成 PHP 版本，造成误报（6.4 -> 判为无修复分支）
#       或漏报（4.9.8 -> 分支未知 -> 仅 INFO），详见 issue #7
extract_image_version() {
    local img="$1" v=""
    # 优先：php 后面的版本号（php8.2 / php-8.2 / php_8.2 / php8.2.17）
    v=$(printf '%s' "$img" | grep -oiE 'php[._-]?v?[0-9]+(\.[0-9]+){0,2}' \
        | grep -oE '[0-9]+(\.[0-9]+){0,2}' | head -n1)
    if [ -z "$v" ]; then
        v=$(printf '%s' "$img" | awk -F: '{print $NF}' | grep -oE '[0-9]+(\.[0-9]+){1,2}' | head -n1)
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

# 文件是否位于已识别应用（如禅道）的目录树内
# 禅道新版把入口控制器放在 www/x.php、www/index.php，与测试文件名黑名单重名；
# 若不做应用目录识别，每个禅道站点都会各报一条中危误报（见 issue #13）
in_known_app_tree() {
    local d i
    d=$(dirname "$1")
    i=0
    while [ -n "$d" ] && [ "$d" != "/" ] && [ "$i" -lt 4 ]; do
        if { [ -f "$d/config/my.php" ] || [ -f "$d/config/config.php" ]; } \
            && { [ -d "$d/module" ] || [ -d "$d/framework" ]; }; then
            return 0
        fi
        d=$(dirname "$d")
        i=$((i + 1))
    done
    return 1
}

# 对"命中文件名黑名单"的 PHP 文件做二次判定，输出：
#   suspicious —— 含 phpinfo()/命令执行等可疑调用，属真正的信息泄露/攻击面
#   bundled    —— 应用自带文件（核心/依赖/插件主文件），不应报风险
#   candidate  —— 仅文件名可疑，需人工确认
# 背景：WordPress 的 hello.php（Hello Dolly 插件）、wp-includes/.../shell.php（Diff 引擎）
#       等合法文件与黑名单重名，旧实现一律报 HIGH 造成误报（见 issue #9）
classify_demo_file() {
    local f="$1"
    # 1) 应用核心 / 依赖目录下的文件一律视为应用自带
    case "$f" in
        */wp-includes/*|*/vendor/*|*/node_modules/*|*/core/*|*/lib/*|*/libs/*|*/framework/*)
            printf 'bundled'; return 0 ;;
    esac
    # 2) 排除注释行后检查是否含信息泄露 / 命令执行调用
    if grep -vE '^[[:space:]]*(\*|//|#|/\*)' "$f" 2>/dev/null \
        | grep -qiE '(phpinfo|eval|assert|system|shell_exec|passthru|proc_open|popen|exec)[[:space:]]*\('; then
        printf 'suspicious'; return 0
    fi
    # 3) 已识别应用目录树内的文件视为应用自带
    #    注意放在可疑调用判定之后：被植入的命令执行文件仍优先报 suspicious
    if in_known_app_tree "$f"; then
        printf 'bundled'; return 0
    fi
    # 4) 带插件/包声明头文件特征，判定为应用自带
    if grep -qiE 'Plugin Name:|@package|@author|@version|namespace[[:space:]]+[A-Za-z_\\]' "$f" 2>/dev/null; then
        printf 'bundled'; return 0
    fi
    printf 'candidate'
    return 0
}

#===============================================================================
# 1. 主机与操作系统基线
#===============================================================================
scan_os() {
    section "1. 主机与操作系统基线"
    if [ "$(id -u)" -eq 0 ]; then
        IS_ROOT=1
        log INFO "OS" "执行身份: root（扫描完整度最高）"
    else
        log INFO "OS" "执行身份: $(id -un) (uid=$(id -u))，非 root 运行将导致部分目录不可读、docker 守护进程无法访问、监听端口进程信息缺失"
        add_topic "rescan"
        med "PERM" "当前非 root 运行，扫描结果存在漏检风险，建议以 root 复扫: sudo $0 $ORIG_ARGS"
    fi
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
            add_topic "aslr"
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
detect_pm() {
    section "2. 包管理器与 PHP 软件包"
    if have rpm; then PM="rpm"; log INFO "PKG" "包管理器: rpm"; fi
    if have dpkg; then PM="deb"; log INFO "PKG" "包管理器: dpkg"; fi
    if [ -z "$PM" ]; then
        info "PKG" "未检测到 rpm/dpkg，本机无标准包管理器，跳过包级检查（源码编译安装请以运行时版本判定为准）"
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
    # issue #13：一体化部署（禅道 zbox 等）的 PHP 既不在 PATH 也不注册 systemd，
    # 必须先做进程反查，find_php_bins 内部已调用 proc_cache_build
    proc_cache_build
    # 同一个 PHP 二进制常以软链暴露多个路径（禅道 zbox：/opt/zbox/bin/php ->
    # /opt/zbox/run/php/php），按真实路径去重，否则同一版本会被重复报为多条风险
    bins=$( (find_php_bins; find_php_bins_systemd) \
            | while IFS= read -r b; do
                  [ -n "$b" ] || continue
                  r=$(readlink -f "$b" 2>/dev/null)
                  printf '%s\n' "${r:-$b}"
              done | sort -u)
    PHP_BINS_FOUND="$bins"
    if [ -z "$bins" ]; then
        if [ "$IS_ROOT" -eq 1 ]; then
            info "PHP" "未发现 PHP 可执行文件（已 root 权限全盘搜索，本机无 PHP 运行时，不存在 PHP2Shell 暴露面）"
        else
            add_topic "rescan"
            med "PHP" "未发现 PHP 可执行文件，但当前为非 root 运行，其他用户目录/未挂载路径可能已漏检，建议以 root 复扫"
        fi
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
            log INFO "PHP" "  $b -> 版本读取失败（该文件可能不是 PHP 运行时，或安装损坏 / 权限不足）"
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
        med "PHP" "系统内存在多个 PHP 版本共存：$(printf '%s' "$uniq_vers" | tr '\n' ' ')，不同服务可能使用不同版本，易遗漏"
    fi
    log INFO "PHP" "版本集合: $(printf '%s' "$uniq_vers" | tr '\n' ' ')"

    # 常驻 PHP 应用进程（RoadRunner、队列 worker 等）
    # 这类进程长期持有全局状态，是 CVE-2026-109619（陈旧全局状态 UAF）的直接暴露面，
    # 且修复后必须重启进程才生效（不能只换二进制）
    local w nw
    nw=$(printf '%s\n' "$PROC_PHP_WORKERS" | grep -c '[^[:space:]]')
    if [ -n "$PROC_PHP_WORKERS" ] && [ "$nw" -gt 0 ]; then
        log INFO "PHP" "常驻 PHP 应用进程（$nw 个）:"
        IFS=$'\n'
        for w in $PROC_PHP_WORKERS; do
            log INFO "PHP" "  pid=${w%%|*}  ${w#*|}"
        done
        IFS="$oldifs"
        add_topic "worker_restart"
        if [ "$VULN_FOUND" -eq 1 ]; then
            med "PHP" "存在 $nw 个常驻 PHP 应用进程（RoadRunner / 队列 worker 等），长期持有全局状态，CVE-2026-109619（陈旧全局状态 UAF）暴露面更大；升级 PHP 后必须重启这些进程才会生效"
        else
            info "PHP" "存在 $nw 个常驻 PHP 应用进程（RoadRunner / 队列 worker 等），升级 PHP 后需一并重启"
        fi
    fi
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
                    5.6) if [ "$V_PAT" -lt 40 ]; then hits=1; add_topic "upgrade"; med "CVE-2019-11043" "$b 版本 $v 存在 CVE-2019-11043（PHP-FPM RCE）风险，需确认是否以 nginx 反代 fpm"; fi ;;
                    7.0) if [ "$V_PAT" -lt 33 ]; then hits=1; add_topic "upgrade"; med "CVE-2019-11043" "$b 版本 $v 存在 CVE-2019-11043（PHP-FPM RCE）风险，需确认是否以 nginx 反代 fpm"; fi ;;
                    7.1) if [ "$V_PAT" -lt 33 ]; then hits=1; add_topic "upgrade"; med "CVE-2019-11043" "$b 版本 $v 存在 CVE-2019-11043（PHP-FPM RCE）风险，需确认是否以 nginx 反代 fpm"; fi ;;
                esac
                ;;
        esac

        # CVE-2024-4577：PHP-CGI 参数注入（以 CGI 模式运行时可绕过配置直接注入参数）
        case "$b" in
            *php-cgi*)
                case "$V_MAJ.$V_MIN" in
                    8.3) if ver_lt "$v" "8.3.8"; then hits=1; add_topic "upgrade"; add_topic "cgi_mode"; high "CVE-2024-4577" "$b 版本 $v 的 CGI 模式存在 CVE-2024-4577 参数注入风险"; fi ;;
                    8.2) if ver_lt "$v" "8.2.20"; then hits=1; add_topic "upgrade"; add_topic "cgi_mode"; high "CVE-2024-4577" "$b 版本 $v 的 CGI 模式存在 CVE-2024-4577 参数注入风险"; fi ;;
                    8.1) if ver_lt "$v" "8.1.29"; then hits=1; add_topic "upgrade"; add_topic "cgi_mode"; high "CVE-2024-4577" "$b 版本 $v 的 CGI 模式存在 CVE-2024-4577 参数注入风险"; fi ;;
                    8.0) if ver_lt "$v" "8.0.30"; then hits=1; add_topic "upgrade"; add_topic "cgi_mode"; high "CVE-2024-4577" "$b 版本 $v 的 CGI 模式存在 CVE-2024-4577 参数注入风险"; fi ;;
                    7.*|5.*|6.*) hits=1; add_topic "upgrade"; add_topic "cgi_mode"; high "CVE-2024-4577" "$b 版本 $v 所属分支已停止维护，CGI 模式存在 CVE-2024-4577 参数注入风险且无官方修复" ;;
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
    proc_cache_build
    local found_web=0
    local oldifs="$IFS"
    IFS=$'\n'

    # Apache
    # issue #13：三级探测 —— PATH -> 静态绝对路径 -> 运行进程反查
    # 禅道 zbox 等一体化部署的 httpd 在 /opt/<产品>/run/apache/ 下，不进 PATH
    local httpd="" c
    for c in httpd apache2 apache; do
        if have "$c"; then httpd="$c"; break; fi
    done
    if [ -z "$httpd" ]; then
        for c in /usr/sbin/httpd /usr/sbin/apache2 /usr/local/apache2/bin/httpd \
                 /www/server/apache/bin/httpd /opt/lampp/bin/httpd \
                 /opt/*/run/apache/httpd /opt/*/bin/httpd; do
            [ -x "$c" ] && { httpd="$c"; break; }
        done
    fi
    if [ -z "$httpd" ] && [ -n "$PROC_HTTPD_LIST" ]; then
        httpd=$(printf '%s\n' "$PROC_HTTPD_LIST" | head -n1)
        log INFO "WEB" "Apache 由运行进程反查定位（不在 PATH）：$httpd"
    fi
    if [ -n "$httpd" ]; then
        found_web=1
        log INFO "WEB" "Apache: $httpd -> $("$httpd" -v 2>/dev/null | head -n1)"
        local mods conf
        conf=$(apache_primary_conf "$httpd")
        [ -n "$conf" ] && log INFO "WEB" "Apache 主配置: $conf"
        mods=$("$httpd" -M 2>/dev/null | grep -iE 'php')
        if [ -z "$mods" ] && [ -n "$conf" ]; then
            mods=$("$httpd" -f "$conf" -M 2>/dev/null | grep -iE 'php')
        fi
        if [ -z "$mods" ] && [ -n "$conf" ]; then
            # -M 需要可用的 httpd 运行时环境（部分一体化包不满足），退回直接读配置
            mods=$(grep -hiE '^[[:space:]]*LoadModule[[:space:]]+php' "$conf" 2>/dev/null)
            [ -n "$mods" ] && mods="$(printf '%s' "$mods")（来源：配置文件 LoadModule 行）"
        fi
        if [ -n "$mods" ]; then
            MODPHP_FOUND=1
            add_topic "mod_php"
            log INFO "WEB" "模块: $(printf '%s' "$mods" | tr '\n' ' ')"
            # 官方指出 mod_php 风险最高（未认证请求可在业务代码执行前触发漏洞），
            # 但只有在确实存在未修复版本时才升级为 HIGH
            if [ "$VULN_FOUND" -eq 1 ]; then
                high "WEB" "Apache 直接加载了 PHP 模块（mod_php）：$(printf '%s' "$mods" | tr '\n' ' ')，请求直接进入 PHP 进程，受 PHP2Shell 影响面更大"
            else
                med "WEB" "Apache 直接加载了 PHP 模块（mod_php）：$(printf '%s' "$mods" | tr '\n' ' ')，官方指出该部署形态风险最高，当前 PHP 版本未确认受影响，建议保持关注"
            fi
        else
            log INFO "WEB" "Apache 未直接加载 mod_php（可能经 php-fpm 反代）"
        fi
        # 常见 mod_php 配置文件存在性（仅在模块列表未检出时作为补充判断）
        if [ -z "$mods" ] && ls /etc/httpd/conf.modules.d/*php* /etc/apache2/mods-enabled/*php* \
              /opt/*/etc/apache/conf.d/*php* /opt/*/etc/apache2/mods-enabled/*php* \
              /www/server/apache/conf/extra/*php* >/dev/null 2>&1; then
            add_topic "mod_php"
            med "WEB" "存在 mod_php 启用配置：$(ls /etc/httpd/conf.modules.d/*php* /etc/apache2/mods-enabled/*php* /opt/*/etc/apache/conf.d/*php* /opt/*/etc/apache2/mods-enabled/*php* /www/server/apache/conf/extra/*php* 2>/dev/null | tr '\n' ' ')"
        fi
    else
        log INFO "WEB" "未发现 Apache"
    fi

    # nginx（同样支持进程反查，覆盖面板/一体化部署）
    local nginx_bin=""
    if have nginx; then
        nginx_bin="nginx"
    elif [ -n "$PROC_NGINX_LIST" ]; then
        nginx_bin=$(printf '%s\n' "$PROC_NGINX_LIST" | head -n1)
        log INFO "WEB" "nginx 由运行进程反查定位（不在 PATH）：$nginx_bin"
    fi
    if [ -n "$nginx_bin" ]; then
        found_web=1
        log INFO "WEB" "nginx: $("$nginx_bin" -v 2>&1 | head -n1)"
        local nroot
        nroot=$(grep -rhoE '^[[:space:]]*root[[:space:]]+[^;]+;' /etc/nginx /usr/local/nginx/conf /www/server/nginx/conf /opt/*/etc/nginx 2>/dev/null | awk '{print $2}' | tr -d ';' | sort -u)
        [ -n "$nroot" ] && log INFO "WEB" "nginx root 指令: $(printf '%s' "$nroot" | tr '\n' ' ')"
        if grep -rq 'fastcgi_pass' /etc/nginx /usr/local/nginx/conf /www/server/nginx/conf /opt/*/etc/nginx 2>/dev/null; then
            local fpm_addr
            fpm_addr=$(grep -rhoE 'fastcgi_pass[[:space:]]+[^;]+;' /etc/nginx /usr/local/nginx/conf /www/server/nginx/conf /opt/*/etc/nginx 2>/dev/null | tr -d ';' | sort -u | tr '\n' ' ')
            log INFO "WEB" "nginx 通过 fastcgi_pass 转发至 PHP-FPM: $fpm_addr"
        fi
    else
        log INFO "WEB" "未发现 nginx"
    fi

    # php-fpm 进程
    if have ps; then
        local fpm_proc cnt p
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
            # 端口视角与 pool 配置视角是同一风险（见 issue #4）：
            # 此处只做提示，实际风险条目统一由第 6 节的 pool listen 判定给出，避免重复计数
            FPM_PORT_9000=1
            add_topic "fpm_listen"
            info "WEB" "9000 端口处于监听状态，若为 php-fpm 且暴露于外网，可直接发起 FastCGI 协议攻击（实际风险条目见第 6 节 php-fpm pool listen 判定）"
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

    # issue #13：一体化部署（禅道 zbox 等）的 php.ini 不在任何标准路径，
    # 优先用第 3 节实际发现的 PHP 可执行文件自报的 `php --ini` 结果定位
    local dyn_inis="" dyn_dirs="" pb ifile idir
    local oldifs3="$IFS"
    IFS=$'\n'
    for pb in $PHP_BINS_FOUND; do
        [ -x "$pb" ] || continue
        ifile=$(php_ini_file "$pb")
        case "$ifile" in
            ""|"(none)") ;;
            *) dyn_inis="$dyn_inis$ifile"$'\n' ;;
        esac
        idir=$(php_ini_scan_dir "$pb")
        [ -n "$idir" ] && [ -d "$idir" ] && dyn_dirs="$dyn_dirs$idir"$'\n'
    done
    IFS="$oldifs3"
    if [ -n "$dyn_inis" ]; then
        log INFO "CFG" "PHP 自报配置文件（php --ini）: $(printf '%s' "$dyn_inis" | sort -u | tr '\n' ' ')"
    fi

    inis=$(
        {
            ls /etc/php.ini /etc/php/*/php.ini /etc/php/*/cli/php.ini /etc/php/*/fpm/php.ini \
               /etc/php/*/apache2/php.ini /usr/local/lib/php.ini /usr/local/etc/php/php.ini \
               /opt/php*/etc/php.ini /usr/local/php*/lib/php.ini \
               /opt/*/etc/php/php.ini /opt/*/run/php/etc/php.ini /opt/lampp/etc/php.ini \
               /www/server/php/*/etc/php.ini 2>/dev/null
            printf '%s' "$dyn_inis"
        } | grep -v '^$' | sort -u)
    # Debian/Ubuntu 的 conf.d/*.ini 会在 php.ini 之后加载，可覆盖关键配置
    overrides=$(
        {
            ls /etc/php/*/conf.d/*.ini /etc/php/*/*/conf.d/*.ini \
               /usr/local/etc/php/conf.d/*.ini /usr/local/php*/conf.d/*.ini \
               /opt/*/etc/php/conf.d/*.ini /opt/*/run/php/etc/conf.d/*.ini \
               /opt/lampp/etc/conf.d/*.ini /www/server/php/*/etc/conf.d/*.ini 2>/dev/null
            for idir in $dyn_dirs; do ls "$idir"/*.ini 2>/dev/null; done
        } | grep -v '^$' | sort -u)

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
        # conf.d 里的扩展 ini（如 00-ioncube.ini / 01-opcache.ini）只负责加载扩展，
        # 不会设置 memory_limit / post_max_size / session.upload_progress；
        # 这些指令由主 php.ini 统一决定。对扩展 ini 只校验它显式写入的值，
        # 否则每个扩展文件都会各报一次"未设置"，产生成倍误报。
        local is_main=1
        case "$f" in
            */conf.d/*|*/conf.d) is_main=0 ;;
        esac

        # display_errors / expose_php —— 通用加固项，非 PHP2Shell 缓解措施
        local de ep deb epb
        de=$(ini_get 'display_errors' "$f")
        ep=$(ini_get 'expose_php' "$f")
        deb=$(ini_bool "$de")
        epb=$(ini_bool "$ep")
        if [ "$deb" = "1" ]; then
            add_topic "ini_harden"
            low "CFG" "$f: display_errors=${de}，错误信息直接回显（通用信息泄露风险；注意官方明确说明隐藏诊断信息并不能缓解 PHP2Shell）"
        fi
        if [ "$epb" = "1" ]; then
            add_topic "ini_harden"
            low "CFG" "$f: expose_php=${ep}，暴露 PHP 版本指纹（通用加固项）"
        fi
        if [ "$deb" = "0" ] && [ "$epb" = "0" ]; then
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
            add_topic "memlimit"
            med "CFG" "$f: memory_limit=$ml，存在可由请求方稳定触发的 longjmp 中止路径；官方要求设为 -1（应用不可覆盖）以移除该路径"
        elif [ "$is_main" -eq 1 ]; then
            add_topic "memlimit"
            med "CFG" "$f: 未显式设置 memory_limit（将采用默认 128M），官方要求设为 -1 以移除可控的 OOM 中止路径"
        else
            log INFO "CFG" "$f: 未设置 memory_limit（扩展 ini，由主 php.ini 决定）"
        fi

        # OPcache —— 官方缓解措施中未包含"关闭 OPcache"，仅作为暴露面提示
        local oc omt ocb
        oc=$(ini_get 'opcache.enable' "$f")
        omt=$(ini_get 'opcache.validate_timestamps' "$f")
        ocb=$(ini_bool "$oc")
        if [ "$ocb" = "1" ]; then
            add_topic "opcache"
            info "CFG" "$f: opcache.enable=1，OPcache 跨请求共享内存处于启用状态（提示项：官方缓解措施未包含关闭 OPcache，禁用前请评估业务性能影响）"
        fi
        log INFO "CFG" "$f: opcache.enable=${oc:-未设置}, opcache.validate_timestamps=${omt:-未设置}"

        # session.upload_progress —— CVE-2026-109619 官方缓解措施
        # 注意：指令缺失或被注释（;session.upload_progress.enabled=On）时，PHP 采用默认值 1/On，
        # 即缓解措施实际未落实。旧实现对这种情况不做任何提示，属于漏报（见 issue #3）。
        local sup supb
        sup=$(ini_get 'session.upload_progress.enabled' "$f")
        supb=$(ini_bool "$sup")
        if [ "$supb" = "1" ]; then
            add_topic "upload_progress"
            med "CFG" "$f: session.upload_progress.enabled=${sup}，官方缓解措施未落实（CVE-2026-109619：应设为 0 并重启所有 worker）"
        elif [ "$supb" = "0" ]; then
            ok "CFG" "$f: session.upload_progress.enabled=${sup}，符合 CVE-2026-109619 官方缓解措施"
        elif [ "$is_main" -eq 1 ]; then
            add_topic "upload_progress"
            med "CFG" "$f: 未显式设置 session.upload_progress.enabled（PHP 默认值为 1/On），官方缓解措施未落实（CVE-2026-109619：应设为 0 并重启所有 worker）"
        else
            log INFO "CFG" "$f: 未设置 session.upload_progress.enabled（扩展 ini，由主 php.ini 决定）"
        fi

        # post_max_size —— CVE-2026-109618 官方缓解措施（收紧请求体）
        local pms ums pmb umb
        pms=$(ini_get 'post_max_size' "$f")
        ums=$(ini_get 'upload_max_filesize' "$f")
        log INFO "CFG" "$f: post_max_size=${pms:-默认}, upload_max_filesize=${ums:-默认}"
        if [ -n "$pms" ]; then
            pmb=$(size_to_bytes "$pms")
            if [ -n "$pmb" ] && [ "$pmb" -gt 33554432 ] 2>/dev/null; then
                add_topic "post_max"
                med "CFG" "$f: post_max_size=$pms 偏大，官方建议收紧至 8M（无上传业务）/ 32M（需上传业务）"
            fi
        fi
        if [ -n "$pms" ] && [ -n "$ums" ]; then
            pmb=$(size_to_bytes "$pms")
            umb=$(size_to_bytes "$ums")
            if [ -n "$pmb" ] && [ -n "$umb" ] && [ "$umb" -ge "$pmb" ] 2>/dev/null; then
                add_topic "post_max"
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
            # 注意：必须按 pool 逐个判定，不能复用全局 FPM_EXPOSED，
            # 否则前一个 pool 暴露后，后续所有 pool 都会被误报为暴露
            local pool_exposed=0
            if fpm_listen_exposed "$listen"; then
                pool_exposed=1
                FPM_EXPOSED=1
                add_topic "fpm_listen"
            fi
            if [ "$pool_exposed" -eq 1 ]; then
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
                add_topic "memlimit"
                med "CFG" "$pf: pool 中设置了 php_value[memory_limit]=$pml，会覆盖 php.ini 的设置；官方要求 memory_limit=-1 且应用不可覆盖"
            elif [ -n "$pml" ]; then
                ok "CFG" "$pf: pool 中 memory_limit=-1，符合官方缓解措施"
            fi

            if [ "$pmr" = "0" ]; then
                add_topic "fpm_requests"
                med "CFG" "$pf: pm.max_requests=0（不限制），长驻 worker 存活期长，陈旧全局状态风险更大（通用加固项，建议配合官方'重启所有 worker'要求）"
            fi
        done
        IFS="$oldifs"
    fi

    # 兜底：9000 端口在监听，但未在任何 pool 配置中找到对应的 listen 声明
    # （例如 pool 配置位于非标准路径、或由第三方面板生成）
    if [ "$FPM_PORT_9000" -eq 1 ] && [ "$FPM_EXPOSED" -eq 0 ]; then
        if [ "$VULN_FOUND" -eq 1 ]; then
            high "WEB" "9000 端口处于监听状态且未找到对应的 php-fpm pool listen 配置，若为 php-fpm 且暴露于外网，可直接发起 FastCGI 协议攻击"
        else
            med "WEB" "9000 端口处于监听状态且未找到对应的 php-fpm pool listen 配置，请确认是否为对外暴露的 php-fpm（通用加固项）"
        fi
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
    local root total hits bak cms h b rdir demo_files
    for root in $roots; do
        [ -d "$root" ] || continue
        rdir="${root%/}"         # 去掉末尾斜杠，避免输出 "路径//文件名"
        [ -n "$rdir" ] || rdir="/"
        total=$(find "$rdir" -maxdepth "$MAX_DEPTH" -type f -name '*.php' 2>/dev/null | wc -l | tr -d ' ')
        log INFO "APP" "$rdir: PHP 文件 $total 个"

        # 演示 / 测试 / 信息泄露页
        # 注意：case 语句不能写在 $( ) 内（bash 3.2 语法限制），改用 is_demo_php_name 函数
        # 文件名命中黑名单只是"候选"，需再按路径与内容判定，避免把应用自带文件
        # （如 WordPress 的 hello.php / wp-includes/.../shell.php）误判为高危（见 issue #9）
        local cand sus_bundled demo_cand
        cand=$(find "$rdir" -maxdepth "$MAX_DEPTH" -type f -name '*.php' 2>/dev/null \
                | while IFS= read -r f; do
                    if is_demo_php_name "$(basename "$f")"; then
                        printf '%s\n' "$f"
                    fi
                done)
        demo_files=""
        demo_cand=""
        sus_bundled=""
        if [ -n "$cand" ]; then
            local cf cver
            oldifs="$IFS"; IFS=$'\n'
            for cf in $cand; do
                [ -z "$cf" ] && continue
                cver=$(classify_demo_file "$cf")
                case "$cver" in
                    suspicious) demo_files="$demo_files$cf"$'\n' ;;
                    bundled)    sus_bundled="$sus_bundled$cf"$'\n' ;;
                    *)          demo_cand="$demo_cand$cf"$'\n' ;;
                esac
            done
            IFS="$oldifs"
        fi
        if [ -n "$demo_files" ]; then
            add_topic "demo_files"
            high "APP" "$rdir 存在演示/测试 PHP 文件且含 phpinfo()/命令执行等可疑调用（可用于探测与放大漏洞）：$(printf '%s' "$demo_files" | tr '\n' ' ')"
        fi
        if [ -n "$demo_cand" ]; then
            add_topic "demo_files"
            med "APP" "$rdir 存在命中演示/测试文件名黑名单的文件（未发现明显可疑调用，请人工确认是否为遗留文件）：$(printf '%s' "$demo_cand" | tr '\n' ' ')"
        fi
        if [ -n "$sus_bundled" ]; then
            info "APP" "$rdir 有 $(printf '%s' "$sus_bundled" | grep -c '[^[:space:]]') 个文件命中演示/测试文件名黑名单，但属应用自带文件（核心/依赖/插件主文件），已忽略：$(printf '%s' "$sus_bundled" | tr '\n' ' ')"
        fi

        # 备份 / 源码泄露文件
        bak=$(find "$rdir" -maxdepth "$MAX_DEPTH" -type f \( -name '*.php.bak' -o -name '*.php~' \
                -o -name '*.php.old' -o -name '*.php.save' -o -name '*.phps' -o -name '*.inc.php' \
                -o -name '*.php.orig' -o -name '*.php.dist' \) 2>/dev/null | head -n30)
        if [ -n "$bak" ]; then
            add_topic "backup_files"
            med "APP" "$rdir 存在备份 / 源码泄露文件：$(printf '%s' "$bak" | tr '\n' ' ')"
        fi

        # 应用指纹
        cms=$(detect_cms "$rdir")
        if [ -n "$cms" ]; then
            log INFO "APP" "$rdir 应用指纹: $(printf '%s' "$cms" | tr '\n' ' ')"
        fi
    done
    IFS="$oldifs"
}

# 收集 Web 根目录
collect_web_roots() {
    local r d out
    out=$(
        {
            # Apache DocumentRoot + Alias 目标（issue #13：禅道 zbox 用 Alias /zentao 指向应用目录）
            apache_web_roots
            # nginx root
            grep -rhoiE '^[[:space:]]*root[[:space:]]+[^;]+;' /etc/nginx /usr/local/nginx/conf /www/server/nginx/conf /opt/*/etc/nginx 2>/dev/null \
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
            # 一体化部署常见布局（禅道 zbox / XAMPP / 面板）
            echo /opt/*/app/*/www
            echo /opt/*/app/*/htdocs
            echo /opt/*/htdocs
            echo /opt/lampp/htdocs
            # 用户附加
            for r in $EXTRA_ROOTS; do echo "$r"; done
        } | sed 's|/*$|/|' | sort -u
    )
    for d in $out; do
        [ -d "$d" ] && echo "$d"
    done | remove_nested_roots
    return 0
}

# 剔除被其它根目录包含的子目录，避免同一批文件被重复扫描、同一风险被重复计数
# （例如 /var/www 与 /var/www/html 同时存在，见 issue #5）
remove_nested_roots() {
    local cand kept d other dn on
    cand=$(cat)
    IFS=$'\n'
    for d in $cand; do
        [ -z "$d" ] && continue
        dn=${d%/}                      # 去掉末尾斜杠用于比较
        [ -z "$dn" ] && dn="/"
        kept=1
        for other in $cand; do
            [ -z "$other" ] && continue
            on=${other%/}
            [ -z "$on" ] && on="/"
            [ "$dn" = "$on" ] && continue
            # d 位于 other 之下（other 是 d 的祖先）-> 丢弃 d，保留上层根目录
            case "$dn" in
                "$on"/*) kept=0; break ;;
            esac
        done
        [ "$kept" -eq 1 ] && printf '%s\n' "$d"
    done
    return 0
}

# 应用指纹识别
# 注意：仅凭"文件/目录存在"判定会把 0 字节空文件、空目录误判为应用指纹（见 issue #6），
# 因此所有判定都要求文件非空 / 目录非空
detect_cms() {
    local root="$1" out=""
    if [ -f "$root/wp-config.php" ] && [ -s "$root/wp-config.php" ]; then
        out="$out WordPress"
    elif [ -d "$root/wp-content" ] && [ -n "$(ls -A "$root/wp-content" 2>/dev/null | head -n1)" ]; then
        out="$out WordPress(content)"
    fi
    [ -f "$root/configuration.php" ] && [ -s "$root/configuration.php" ] && out="$out Joomla"
    [ -f "$root/index.php" ] && [ -d "$root/core" ] && [ -n "$(ls -A "$root/core" 2>/dev/null | head -n1)" ] && out="$out Drupal"
    [ -f "$root/artisan" ] && [ -s "$root/artisan" ] && out="$out Laravel"
    [ -d "$root/thinkphp" ] && [ -n "$(ls -A "$root/thinkphp" 2>/dev/null | head -n1)" ] && out="$out ThinkPHP"
    [ -f "$root/think" ] && [ -s "$root/think" ] && out="$out ThinkPHP"
    [ -f "$root/composer.json" ] && [ -s "$root/composer.json" ] && out="$out Composer项目"
    [ -f "$root/composer.lock" ] && [ -s "$root/composer.lock" ] && out="$out Composer.lock"
    [ -d "$root/phpmyadmin" ] && [ -n "$(ls -A "$root/phpmyadmin" 2>/dev/null | head -n1)" ] && out="$out phpMyAdmin"
    [ -d "$root/mediawiki" ] && [ -n "$(ls -A "$root/mediawiki" 2>/dev/null | head -n1)" ] && out="$out MediaWiki"
    [ -d "$root/yii" ] && [ -n "$(ls -A "$root/yii" 2>/dev/null | head -n1)" ] && out="$out Yii"
    [ -f "$root/config.php" ] && [ -s "$root/config.php" ] && [ -d "$root/sites" ] && out="$out Drupal(config)"
    [ -d "$root/Discuz" ] && [ -n "$(ls -A "$root/Discuz" 2>/dev/null | head -n1)" ] && out="$out Discuz"
    [ -f "$root/index.php" ] && [ -d "$root/admin" ] && [ -n "$(ls -A "$root/admin" 2>/dev/null | head -n1)" ] && out="$out 后台管理类应用"

    # 禅道 ZenTao（issue #13）：www/ 的上级目录为应用根，
    # 含 config/my.php 且（module/ 或 framework/）。版本号在应用根的 VERSION
    # 或一体化部署根目录（如 /opt/zbox/VERSION）下。
    local up zver
    up="${root%/}/.."
    if { [ -f "$up/config/my.php" ] || [ -f "$up/config/config.php" ]; } \
        && { [ -d "$up/module" ] || [ -d "$up/framework" ]; }; then
        zver=""
        if [ -f "$up/VERSION" ]; then
            zver=$(head -n1 "$up/VERSION" 2>/dev/null)
        elif [ -f "$up/../../VERSION" ]; then
            zver=$(head -n1 "$up/../../VERSION" 2>/dev/null)
        fi
        if [ -n "$zver" ]; then
            out="$out ZenTao禅道($zver)"
        else
            out="$out ZenTao禅道"
        fi
    fi

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
        if [ "$IS_ROOT" -eq 0 ]; then
            add_topic "rescan"
            med "DOCKER" "$docker_bin 已安装但当前用户无法连接守护进程（非 root 权限不足），容器内 PHP 版本未能扫描，建议以 root 复扫"
        else
            med "DOCKER" "$docker_bin 无法连接守护进程（服务未运行或环境异常），跳过镜像扫描"
        fi
        return
    fi

    local oldifs="$IFS"
    IFS=$'\n'
    local imgs total i v verdict cs c
    # 名称含 php 的镜像：可直接从 tag 推断 PHP 版本
    imgs=$($docker_bin images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i 'php' | sort -u)
    if [ -z "$imgs" ]; then
        info "DOCKER" "未发现名称含 php 的本地镜像（名称不含 php 的镜像无法从 tag 推断版本，需 --deep 或容器内探测）"
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
                    vulnerable) VULN_FOUND=1; add_topic "docker_rebuild"; high "DOCKER" "镜像 $i 版本 $v 低于该分支修复版本，运行即受 PHP2Shell 影响" ;;
                    nofix)      NOFIX_FOUND=1; VULN_FOUND=1; add_topic "docker_rebuild"; crit "DOCKER" "镜像 $i 版本 $v 分支无官方修复版本" ;;
                    backport)   VULN_FOUND=1; add_topic "docker_rebuild"; med  "DOCKER" "镜像 $i 版本 $v 分支无官方修复发行版，需确认基础镜像是否已回补" ;;
                    minor_only) add_topic "verify"; info "DOCKER" "镜像 $i 标签仅含主.次版本（$V_MAJ.$V_MIN），patch 未知，需 --deep 探测实际 PHP 版本" ;;
                    safe)      ok   "DOCKER" "镜像 $i 版本 $v 不低于该分支修复版本" ;;
                    unknown)   add_topic "verify"; info "DOCKER" "镜像 $i 版本 $v 分支未知，需人工确认" ;;
                esac
            else
                log INFO "DOCKER" "  $i (标签中无版本号，需用 --deep 探测实际 PHP 版本)"
            fi
        done
    fi

    # 容器实例：不再按名称过滤（名称不含 php 的容器同样可能运行 PHP，见 issue #8）
    cs=$($docker_bin ps -a --format '{{.Names}}	{{.Image}}	{{.Status}}' 2>/dev/null)
    if [ -n "$cs" ]; then
        info "DOCKER" "发现全部容器实例（名称不含 php 的容器也可能在运行 PHP）："
        for c in $cs; do log INFO "DOCKER" "  $c"; done
    else
        info "DOCKER" "未发现容器实例"
    fi

    # 运行中容器内 PHP 版本探测（只读：仅执行 php -v，不修改容器）
    local running probe_name probe_img probe_ver
    running=$($docker_bin ps --format '{{.Names}}' 2>/dev/null)
    if [ -n "$running" ]; then
        oldifs="$IFS"; IFS=$'\n'
        for probe_name in $running; do
            [ -z "$probe_name" ] && continue
            probe_name="$probe_name"
            if have timeout; then
                probe_ver=$(timeout 5 $docker_bin exec "$probe_name" php -v 2>/dev/null | grep -i '^PHP' | head -n1)
            else
                probe_ver=$($docker_bin exec "$probe_name" php -v 2>/dev/null | grep -i '^PHP' | head -n1)
            fi
            [ -z "$probe_ver" ] && continue
            log INFO "DOCKER" "  容器 $probe_name 内 PHP: $probe_ver"
            report_php_version "$(printf '%s' "$probe_ver" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)" \
                               "容器 $probe_name 内 PHP" "DOCKER"
        done
        IFS="$oldifs"
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
            local iv pv cid
            # 显式 create + start + rm：podman 0.10 在 entrypoint 不存在时不会回收 --rm 容器，
            # 会残留孤儿容器（见 issue #11）；此处改为显式持有容器 ID 并强制删除
            cid=$($docker_bin create --network none --entrypoint php "$i" -v 2>/dev/null)
            if [ -z "$cid" ]; then
                continue
            fi
            iv=$($docker_bin start -a "$cid" 2>/dev/null | grep -i '^PHP' | head -n1)
            $docker_bin rm -f "$cid" >/dev/null 2>&1
            [ -z "$iv" ] && continue
            pv=$(printf '%s' "$iv" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
            [ -z "$pv" ] && continue
            log INFO "DOCKER" "  镜像 $i 内 PHP: $iv"
            report_php_version "$pv" "镜像 $i 内 PHP" "DOCKER"
        done
        IFS="$oldifs"
        log INFO "DOCKER" "深度模式共探测 $probe_cnt 个镜像"
    elif [ -n "$imgs" ]; then
        info "DOCKER" "提示：加 --deep 参数可探测全部镜像（含自建镜像）内的 PHP 真实版本"
    fi
}

#===============================================================================
# 9. 风险清单输出（把明细逐条列出，便于一眼看清）
#===============================================================================
# list_findings <标题> <级别> <明细字符串>
list_findings() {
    local title="$1" level="$2" data="$3"
    local line n=0
    printf '\n  %s%s%s\n' "$C_BLD" "$title" "$C_OFF"
    _log_target ""
    _log_target "  $title"
    if [ -z "$data" ]; then
        printf '    (无)\n'
        _log_target "    (无)"
        return 0
    fi
    local oldifs="$IFS"
    IFS=$'\n'
    for line in $data; do
        [ -z "$line" ] && continue
        n=$((n+1))
        local tag desc color
        tag=$(printf '%s' "$line" | cut -d'|' -f1)
        desc=$(printf '%s' "$line" | cut -d'|' -f2-)
        case "$level" in
            CRIT) color="$C_RED";;
            HIGH) color="$C_RED";;
            MED ) color="$C_YEL";;
            LOW ) color="$C_BLU";;
            *   ) color="";;
        esac
        printf '    %s%2d) [%s]%s %s\n' "$color" "$n" "$tag" "$C_OFF" "$desc"
        _log_target "    $n) [$tag] $desc"
    done
    IFS="$oldifs"
    return 0
}

#===============================================================================
# 10. 修复建议（仅针对本机实际命中的风险动态生成）
#===============================================================================
has_topic() {
    case " $REMED_TOPICS " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

print_remediation() {
    section "修复建议"

    if [ -z "$REMED_TOPICS" ]; then
        printf '  本次扫描未命中任何需要处置的风险项，无需执行修复操作。\n'
        _log_target "  本次扫描未命中任何需要处置的风险项，无需执行修复操作。"
        return 0
    fi

    local n=0
    # ---- 必做项 ----
    if has_topic "upgrade"; then
        n=$((n+1))
        printf '    %s. [必做] 升级 PHP 到已修复版本，并重启 php-fpm 与 apache/nginx 使新进程生效：\n' "$n"
        printf '         8.2 分支 -> >= 8.2.35    8.3 分支 -> >= 8.3.36\n'
        printf '         8.4 分支 -> >= 8.4.27    8.5 分支 -> >= 8.5.12\n'
        _log_target "  $n. [必做] 升级 PHP 到已修复版本（8.2.35 / 8.3.36 / 8.4.27 / 8.5.12）并重启服务"
    fi
    if has_topic "eol"; then
        n=$((n+1))
        printf '    %s. [必做] 存在官方无修复版本的 PHP 分支（5.4-7.3），需制定下线或替换计划\n' "$n"
        _log_target "  $n. [必做] 无官方修复版本的 PHP 分支，需制定下线或替换计划"
    fi
    if has_topic "backport"; then
        n=$((n+1))
        printf '    %s. [必做] 存在无官方修复发行版的分支（7.4/8.0/8.1），需向发行版确认是否已回补 CVE-2026-109618/109619\n' "$n"
        _log_target "  $n. [必做] 确认发行版是否已回补 CVE-2026-109618/109619"
    fi
    if has_topic "vendor_php"; then
        n=$((n+1))
        printf '    %s. [必做] 存在厂商自带 / 源码编译的 PHP（不属于任何发行版软件包），7.4/8.0/8.1 分支\n' "$n"
        printf '         没有发行版回补渠道：需向该产品厂商索取已修复 CVE-2026-109618/109619 的版本，\n'
        printf '         或自行编译升级到 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 及以上。\n'
        _log_target "  $n. [必做] 厂商自带/源码编译 PHP 无回补渠道，需厂商修复或自行升级"
    fi
    if has_topic "worker_restart"; then
        n=$((n+1))
        printf '    %s. [必做] 修复后重启所有常驻 PHP 应用进程（RoadRunner / 队列 worker 等）：\n' "$n"
        printf '         仅替换二进制或重启 Web 服务不会清掉这些进程内已存在的陈旧全局状态。\n'
        _log_target "  $n. [必做] 重启常驻 PHP 应用进程（RoadRunner / 队列 worker）"
    fi
    if has_topic "docker_rebuild"; then
        n=$((n+1))
        printf '    %s. [必做] 将所有 PHP Docker 镜像重建为已修复基础镜像，并重新部署相关容器\n' "$n"
        _log_target "  $n. [必做] 重建 PHP Docker 镜像并重新部署容器"
    fi
    if has_topic "demo_files"; then
        n=$((n+1))
        printf '    %s. [必做] 删除 Web 根目录下的演示/测试/信息泄露文件（phpinfo.php、test.php、demo.php 等）\n' "$n"
        _log_target "  $n. [必做] 删除演示/测试/信息泄露 PHP 文件"
    fi
    if has_topic "backup_files"; then
        n=$((n+1))
        printf '    %s. [必做] 清理 Web 根目录下的备份与源码泄露文件（*.php.bak、*.phps 等）\n' "$n"
        _log_target "  $n. [必做] 清理备份与源码泄露文件"
    fi
    if has_topic "fpm_listen"; then
        n=$((n+1))
        printf '    %s. [必做] 将 php-fpm listen 改为 127.0.0.1 或 Unix socket，禁止 9000 端口对外暴露\n' "$n"
        _log_target "  $n. [必做] 收紧 php-fpm 监听地址，禁止 9000 端口外网暴露"
    fi
    if has_topic "cgi_mode"; then
        n=$((n+1))
        printf '    %s. [必做] 停止以 CGI 模式运行 PHP，改为 php-fpm 方式提供服务\n' "$n"
        _log_target "  $n. [必做] 停止以 CGI 模式运行 PHP"
    fi
    if has_topic "rescan"; then
        n=$((n+1))
        printf '    %s. [必做] 以 root 身份重新执行本次扫描，当前结果存在漏检\n' "$n"
        _log_target "  $n. [必做] 以 root 身份重新执行扫描"
    fi

    # ---- 官方缓解措施 ----
    if has_topic "memlimit"; then
        n=$((n+1))
        printf '    %s. [官方缓解] memory_limit 设为 -1，并用 php_admin_value[memory_limit] 使应用无法覆盖：\n' "$n"
        printf '         确认没有 pool / 目录 / 应用设置把它改回有限值。注意：有限的 memory_limit 反而\n'
        printf '         提供了攻击者可稳定触发的 longjmp 中止路径，不要反向调小；也不要用\n'
        printf '         RLIMIT_AS / RLIMIT_DATA 替代，那会诱发真实的分配失败路径。\n'
        _log_target "  $n. [官方缓解] memory_limit=-1 且应用不可覆盖（php_admin_value）"
    fi
    if has_topic "post_max"; then
        n=$((n+1))
        printf '    %s. [官方缓解] 收紧 post_max_size：无文件上传业务设 8M，需上传设 32M，\n' "$n"
        printf '         并保持 upload_max_filesize 低于 post_max_size；同时在 Web / 代理层限制\n'
        printf '         解码后请求体积、输入字段数、multipart 分段数、头部数量与嵌套深度。\n'
        _log_target "  $n. [官方缓解] 收紧 post_max_size 与 Web/代理层请求体限制"
    fi
    if has_topic "upload_progress"; then
        n=$((n+1))
        printf '    %s. [官方缓解] session.upload_progress.enabled=0，并重启所有 worker；\n' "$n"
        printf '         同时修复攻击者可达的致命错误与执行超时（回调、上传/导入处理、清理流程）。\n'
        _log_target "  $n. [官方缓解] session.upload_progress.enabled=0 并重启所有 worker"
    fi

    # ---- 建议 / 通用加固 ----
    if has_topic "mod_php"; then
        n=$((n+1))
        printf '    %s. [建议] 将 Apache mod_php 切换为 php-fpm 反代，缩小 PHP 进程攻击面\n' "$n"
        _log_target "  $n. [建议] Apache mod_php 切换为 php-fpm 反代"
    fi
    if has_topic "ini_harden"; then
        n=$((n+1))
        printf '    %s. [加固] 关闭 display_errors 与 expose_php\n' "$n"
        _log_target "  $n. [加固] 关闭 display_errors 与 expose_php"
    fi
    if has_topic "fpm_requests"; then
        n=$((n+1))
        printf '    %s. [加固] php-fpm 设置 pm.max_requests，缩短进程存活期，减少跨请求状态残留\n' "$n"
        _log_target "  $n. [加固] 设置 pm.max_requests 减少跨请求状态残留"
    fi
    if has_topic "opcache"; then
        n=$((n+1))
        printf '    %s. [提示] OPcache 处于启用状态；官方缓解措施并未包含关闭 OPcache，\n' "$n"
        printf '         如因业务需要关闭，请先评估性能影响。\n'
        _log_target "  $n. [提示] OPcache 启用状态说明（非官方缓解措施）"
    fi
    if has_topic "aslr"; then
        n=$((n+1))
        printf '    %s. [加固] 开启 ASLR：echo 1 > /proc/sys/kernel/randomize_va_space\n' "$n"
        _log_target "  $n. [加固] 开启 ASLR"
    fi
    if has_topic "verify"; then
        n=$((n+1))
        printf '    %s. [复核] 存在无法自动判定分支的 PHP 版本，需人工确认是否受影响\n' "$n"
        _log_target "  $n. [复核] 人工确认无法自动判定分支的 PHP 版本"
    fi

    printf '\n'
    _log_target ""
    return 0
}

#===============================================================================
# 主流程
#===============================================================================
main() {
    printf '%s\n' "$C_BLD==== PHP2Shell 漏洞风险扫描 (PHP2Shell Scan) v3.2.0 ====$C_OFF"
    log INFO "SCAN" "开始时间 $(date '+%Y-%m-%d %H:%M:%S')"
    log INFO "SCAN" "主机 $(hostname 2>/dev/null)  执行身份 $(id -un 2>/dev/null)  扫描器版本 3.2.0"
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

    section "扫描结论"

    # ---- 总体判定 ----
    # 存在中危项时不能直接判"安全"：结论必须与修复建议保持一致（见 issue #10）
    local verdict vcolor
    if [ "$CNT_CRIT" -gt 0 ] || [ "$CNT_HIGH" -gt 0 ]; then
        verdict="存在风险"; vcolor="$C_RED"
    elif [ "$CNT_MED" -gt 0 ]; then
        verdict="待确认"; vcolor="$C_YEL"
    else
        verdict="安全"; vcolor="$C_GRN"
    fi
    printf '\n  %s总体判定：%s%s%s\n' "$C_BLD" "$vcolor" "$verdict" "$C_OFF"
    _log_target ""
    _log_target "  总体判定：$verdict"

    if [ "$CNT_CRIT" -gt 0 ] || [ "$CNT_HIGH" -gt 0 ]; then
        printf '  %s判定依据：存在 %s 项严重、%s 项高危风险，需立即处置（详见下方清单）。%s\n' \
            "$C_BLD" "$CNT_CRIT" "$CNT_HIGH" "$C_OFF"
        _log_target "  判定依据：存在 $CNT_CRIT 项严重、$CNT_HIGH 项高危风险，需立即处置"
    elif [ "$CNT_MED" -gt 0 ]; then
        printf '  %s判定依据：未发现严重(Critical)与高危(High)级风险，但存在 %s 项中危风险待人工复核（详见下方清单），本机仍可能构成 PHP2Shell 攻击面。%s\n' \
            "$C_BLD" "$CNT_MED" "$C_OFF"
        _log_target "  判定依据：未发现严重(Critical)与高危(High)级风险，但存在 $CNT_MED 项中危风险待人工复核，本机仍可能构成 PHP2Shell 攻击面"
    else
        printf '  %s判定依据：未发现严重(Critical)、高危(High)与中危(Medium)级风险，本机不构成 PHP2Shell 攻击面。%s\n' "$C_BLD" "$C_OFF"
        _log_target "  判定依据：未发现严重(Critical)、高危(High)与中危(Medium)级风险，本机不构成 PHP2Shell 攻击面"
    fi

    printf '\n  %s风险统计%s  严重(Critical): %s  高危(High): %s  中危(Medium): %s  低危(Low): %s  提示(Info): %s\n' \
        "$C_BLD" "$C_OFF" "$CNT_CRIT" "$CNT_HIGH" "$CNT_MED" "$CNT_LOW" "$CNT_INFO"
    _log_target "  风险统计  严重(Critical): $CNT_CRIT  高危(High): $CNT_HIGH  中危(Medium): $CNT_MED  低危(Low): $CNT_LOW  提示(Info): $CNT_INFO"

    # ---- 风险清单 ----
    list_findings "【一】严重风险 (Critical) — 必须立即处置" CRIT "$FIND_CRIT"
    list_findings "【二】高危风险 (High) — 需尽快处置"       HIGH "$FIND_HIGH"
    list_findings "【三】中危风险 (Medium) — 需人工复核确认" MED "$FIND_MED"
    list_findings "【四】低危风险 (Low) — 建议顺手加固"     LOW  "$FIND_LOW"

    printf '\n  %s说明：中危项多为"条件性风险"，需人工确认触发条件是否成立；低危项为加固建议。%s\n' "$C_GRY" "$C_OFF"
    _log_target "  说明：中危项多为条件性风险，需人工确认触发条件是否成立；低危项为加固建议。"

    if [ "$IS_ROOT" -eq 0 ]; then
        printf '  %s注意：本次以非 root 身份执行，上方"安全"判定仅代表已扫描范围内的结果，其他目录可能存在漏检。%s\n' "$C_YEL" "$C_OFF"
        _log_target "  注意：本次以非 root 身份执行，上方安全判定仅代表已扫描范围内的结果，其他目录可能存在漏检。"
    fi

    print_remediation

    printf '  %s报告文件：%s%s\n' "$C_BLD" "$REPORT_FILE" "$C_OFF"
    _log_target "  报告文件：$REPORT_FILE"

    log INFO "SCAN" "结束时间 $(date '+%Y-%m-%d %H:%M:%S')"

    if [ "$CNT_CRIT" -gt 0 ] || [ "$CNT_HIGH" -gt 0 ]; then
        printf '\n%s[结论] 存在风险：本机存在 %s 项严重、%s 项高危风险，请按上方清单与修复建议处置。%s\n' \
            "$C_RED$C_BLD" "$CNT_CRIT" "$CNT_HIGH" "$C_OFF"
        exit 1
    elif [ "$CNT_MED" -gt 0 ]; then
        printf '\n%s[结论] 待确认：未发现严重/高危风险，但存在 %s 项中危风险需人工复核确认，请参考上方清单与修复建议。%s\n' \
            "$C_YEL$C_BLD" "$CNT_MED" "$C_OFF"
        exit 0
    else
        printf '\n%s[结论] 安全：未发现严重/高危/中危风险，本机不存在 PHP2Shell 攻击面。%s\n' "$C_GRN$C_BLD" "$C_OFF"
        exit 0
    fi
}

main "$@"
