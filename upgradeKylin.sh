#!/bin/bash
# 020507051235

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]; then
    echo "错误：必须使用root权限运行此脚本"
    echo "请使用 'sudo ./upgradeKylin.sh <文件名>' 或切换到root用户"
    exit 1
fi

# 检查参数
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "用法: $0 <补丁文件名> [nomd5]"
    echo "示例: ./upgradeKylin.sh KylinSp3Upgrade2403-250616.tar.gz"
    echo "示例: ./upgradeKylin.sh KylinSp3Upgrade2403-250616.tar.gz nomd5"
    exit 1
fi



# 设置日志文件
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOG_FILE="${SCRIPT_DIR}/upgradeKylin_$(date +%Y%m%d_%H%M%S).log"

PATCH_FILE="$1"
PATCH_FILE_PATH="${SCRIPT_DIR}/${PATCH_FILE}"
MD5_FILE="${PATCH_FILE_PATH}.md5"
TARGET_DIR="/opt/Kylinpatch"
BACKUP_DIR="/etc/yum.repos.d/backup_$(date +%Y%m%d%H%M%S)"
SKIP_MD5=0

# 检查是否跳过MD5校验
if [ $# -eq 2 ] && [ "$2" == "nomd5" ]; then
    SKIP_MD5=1
fi

# 日志记录函数
log() {
    local log_type=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # 终端显示
    if [ "$log_type" == "ERROR" ]; then
        echo -e "\033[1;31m[${timestamp}] [${log_type}] ${message}\033[0m"
    elif [ "$log_type" == "WARNING" ]; then
        echo -e "\033[1;33m[${timestamp}] [${log_type}] ${message}\033[0m"
    elif [ "$log_type" == "INFO" ]; then
        echo -e "\033[1;32m[${timestamp}] [${log_type}] ${message}\033[0m"
    else
        echo "[${timestamp}] [${log_type}] ${message}"
    fi
    
    # 日志文件记录
    echo "[${timestamp}] [${log_type}] ${message}" >> "$LOG_FILE"
}

# 记录脚本开始
log "INFO" "开始执行麒麟操作系统补丁升级脚本"
log "INFO" "日志文件: $LOG_FILE"
log "INFO" "----------------------------------------"
log "INFO" "操作系统信息:"
uname -a | tee -a "$LOG_FILE"

# 获取.kyinfo文件内容
KYINFO_FILE="/etc/.kyinfo"
if [ -f "$KYINFO_FILE" ]; then
    log "INFO" ".kyinfo文件内容:"
    cat "$KYINFO_FILE" | tee -a "$LOG_FILE"
    
    # 提取关键信息
    OS_NAME=$(grep '^[[:space:]]*name=' "$KYINFO_FILE" | sed 's/^[[:space:]]*name=[[:space:]]*//' | tr -d '"')
    OS_MILESTONE=$(grep '^[[:space:]]*milestone=' "$KYINFO_FILE" | sed 's/^[[:space:]]*milestone=[[:space:]]*//' | tr -d '"')
    OS_ARCH=$(grep '^[[:space:]]*arch=' "$KYINFO_FILE" | sed 's/^[[:space:]]*arch=[[:space:]]*//' | tr -d '"')
    
    log "INFO" "----------------------------------------"
    log "INFO" "系统摘要信息:"
    log "INFO" "操作系统名称: $OS_NAME"
    log "INFO" "里程碑: $OS_MILESTONE"
    log "INFO" "系统架构: $OS_ARCH"
else
    log "WARNING" "未找到/etc/.kyinfo文件"
    OS_ARCH=$(uname -m)
    log "WARNING" "使用内核架构: $OS_ARCH"
fi

log "INFO" "----------------------------------------"

# 用户确认
echo "========================================================"
echo "请仔细检查以上系统信息，特别是.kyinfo文件中的:"
echo "1. 麒麟操作系统版本号 (version): $OS_VERSION"
echo "2. 系统架构 (arch): $OS_ARCH"
echo "3. 升级包文件名: $PATCH_FILE"
echo "4. 确保以上信息与升级包要求匹配"
echo "========================================================"
read -p "确认系统信息正确并继续升级? (y/n): " confirm

# 将用户确认记录到日志
log "INFO" "用户确认输入: $confirm"

case "$confirm" in
    y|Y)
        log "INFO" "用户确认继续升级"
        ;;
    n|N)
        log "INFO" "用户取消升级"
        exit 0
        ;;
    *)
        log "ERROR" "无效输入，请输入 'y' 或 'n'"
        exit 1
        ;;
esac

# 1. 检查补丁文件
log "INFO" "### 步骤 1: 验证补丁文件..."
if [ ! -f "$PATCH_FILE_PATH" ]; then
    log "ERROR" "未找到补丁文件 $PATCH_FILE_PATH"
    exit 1
fi
log "INFO" "发现补丁文件: $(ls -lh "$PATCH_FILE_PATH")"

# 新增步骤：MD5校验
log "INFO" "### 步骤 1.1: 检查文件完整性..."
if [ $SKIP_MD5 -eq 1 ]; then
    log "WARNING" "用户选择跳过MD5校验"
elif [ -f "$MD5_FILE" ]; then
    log "INFO" "找到MD5校验文件: $MD5_FILE"
    log "INFO" "开始计算文件校验值..."
    
    # 计算实际MD5值
    ACTUAL_MD5=$(md5sum "$PATCH_FILE_PATH" | awk '{print $1}')
    # 读取预期MD5值
    EXPECTED_MD5=$(cat "$MD5_FILE" | awk '{print $1}')
    
    log "INFO" "预期MD5: $EXPECTED_MD5"
    log "INFO" "实际MD5: $ACTUAL_MD5"
    
    # 比较MD5值
    if [ "$EXPECTED_MD5" == "$ACTUAL_MD5" ]; then
        log "INFO" "MD5校验成功，文件完整"
    else
        log "ERROR" "MD5校验失败，文件可能损坏或被篡改"
        log "ERROR" "请重新下载补丁文件或使用 'nomd5' 参数跳过校验"
        exit 1
    fi
else
    log "WARNING" "未找到MD5校验文件: $MD5_FILE"
    log "WARNING" "跳过文件完整性检查"
fi

# 2. 准备升级目录
log "INFO" "### 步骤 2: 准备升级目录..."
if [ -d "$TARGET_DIR" ]; then
    log "INFO" "删除现有目录: $TARGET_DIR"
    rm -rf "$TARGET_DIR" || {
        log "ERROR" "删除目录失败"
        exit 1
    }
fi

log "INFO" "创建目录: $TARGET_DIR"
mkdir -p "$TARGET_DIR" || {
    log "ERROR" "创建目录失败"
    exit 1
}

# 3. 解压补丁文件
log "INFO" "### 步骤 3: 解压补丁文件..."
tar -xvf "$PATCH_FILE_PATH" -C "$TARGET_DIR" >> "$LOG_FILE" 2>&1 || {
    log "ERROR" "解压失败"
    exit 1
}
log "INFO" "解压完成，目录内容:"
ls -l "$TARGET_DIR" >> "$LOG_FILE"

# 4. 检查RPM包架构兼容性
log "INFO" "### 步骤 3.1: 检查RPM包架构兼容性..."
# 获取系统架构
if [ -z "$OS_ARCH" ]; then
    OS_ARCH=$(grep 'dist_arch=' /etc/.kyinfo 2>/dev/null | cut -d'"' -f2)
    if [ -z "$OS_ARCH" ]; then
        OS_ARCH=$(uname -m)
        log "WARNING" "无法从/etc/.kyinfo获取系统架构，使用内核架构: $OS_ARCH"
    else
        log "INFO" "系统架构: $OS_ARCH"
    fi
fi

# 处理ARM架构的别名
if [ "$OS_ARCH" = "arm64" ]; then
    log "INFO" "检测到系统架构为arm64，将其视为aarch64的别名"
    OS_ARCH="aarch64"
fi

# 查找所有RPM包
RPM_FILES=$(find "$TARGET_DIR" -type f -name "*.rpm")
if [ -z "$RPM_FILES" ]; then
    log "ERROR" "未找到任何RPM包"
    exit 1
fi

# 检查每个RPM包的架构
ARCH_MISMATCH=0
for rpm_file in $RPM_FILES; do
    # 查询RPM包架构
    rpm_arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>> "$LOG_FILE")
    
    if [ $? -ne 0 ]; then
        log "WARNING" "无法查询 $rpm_file 的架构，跳过检查"
        continue
    fi
    
    # 跳过noarch包
    if [ "$rpm_arch" = "noarch" ]; then
        log "INFO" "包: $(basename "$rpm_file") 架构: noarch (兼容)"
        continue
    fi
    
    # 处理ARM架构的别名
    if [ "$rpm_arch" = "arm64" ]; then
        log "INFO" "包: $(basename "$rpm_file") 架构: arm64 (视为aarch64)"
        rpm_arch="aarch64"
    fi
    
    # 检查架构是否匹配
    if [ "$rpm_arch" != "$OS_ARCH" ]; then
        log "ERROR" "包 $(basename "$rpm_file") 的架构 ($rpm_arch) 与系统架构 ($OS_ARCH) 不匹配"
        ARCH_MISMATCH=1
    else
        log "INFO" "包: $(basename "$rpm_file") 架构: $rpm_arch (匹配)"
    fi
done

# 如果发现架构不匹配，退出脚本
if [ $ARCH_MISMATCH -eq 1 ]; then
    log "ERROR" "升级包包含与系统架构不兼容的RPM包"
    log "ERROR" "请下载正确的架构版本升级包"
    exit 1
fi

# 5. 创建本地YUM源


# 6. 备份现有YUM源
log "INFO" "### 步骤 5: 备份YUM配置..."
mkdir -p "$BACKUP_DIR"
mv /etc/yum.repos.d/*.repo "$BACKUP_DIR" 2>/dev/null
log "INFO" "YUM配置已备份至: $BACKUP_DIR"

# 7. 创建本地仓库配置
log "INFO" "### 步骤 6: 配置本地仓库..."
cat > /etc/yum.repos.d/local.repo <<EOF
[local]
name=Local Repository
baseurl=file://${TARGET_DIR}
enabled=1
gpgcheck=0
priority=1
EOF

log "INFO" "仓库配置内容:"
cat /etc/yum.repos.d/local.repo >> "$LOG_FILE"

# 8. 清理YUM缓存
log "INFO" "### 步骤 7: 清理YUM缓存..."
yum clean all >> "$LOG_FILE" 2>&1 || {
    log "ERROR" "yum缓存清理失败"
    exit 1
}

# 9. 重建YUM缓存
log "INFO" "### 步骤 8: 重建YUM缓存..."
yum makecache >> "$LOG_FILE" 2>&1 || {
    log "ERROR" "yum缓存重建失败"
    exit 1
}

# 9. 检查可用更新
log "INFO" "### 步骤 9: 检查可用更新..."
yum check-update >> "$LOG_FILE" 2>&1 || {
    log "WARNING" "检查更新时出现警告，继续执行"
    # 此处使用WARNING级别并继续执行，因为check-update返回非零可能只是没有更新
}
log "INFO" "检查更新完成"

# 10. 执行升级
log "INFO" "### 步骤 10: 执行系统升级..."
log "INFO" "开始升级..."
yum -y --color=always update 2>&1 | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "ERROR" "系统升级过程失败"
    exit 1
fi
log "INFO" "升级完成"

# ============================================================
# 停止 PolarDB-X (polardbx) 服务
# ============================================================
# 背景：polardbx 是数据库服务。重启前若不先正常停止，重启后会走 crash recovery，
#      可能出现数据不一致；先停服务让数据干净落盘，再 sync 刷盘，最后重启。
# 兼容：systemd（list-unit-files + list-units）+ SysV init 脚本兜底（CentOS 7 等）
# 返回：0=已找到并处理；1=未找到服务（无需处理）
POLARDBX_STOPPED=""

# 停止服务的超时时间（秒）。
# systemd 默认 TimeoutStopSec=90s，超时后会 SIGKILL 强杀进程——对数据库而言这恰恰是最坏情况：
# 进程被强杀，下次启动照样走 crash recovery，"先干净停库"就白做了。这里放宽到 300s。
POLARDBX_STOP_TIMEOUT=300

# 计算指定单元停止时应使用的超时（秒）。
# 取单元自身的 TimeoutStopUSec 与默认值的较大者，避免 --timeout 反而把单元原本更长���
# 超时上限改短。取不到有效数值时（老 systemd 的人类可读格式 / infinity / 单元不存在），
# 返回空表示不传 --timeout，保持单元原有行为不变。
_stop_timeout_arg() {
    local unit="$1"
    local usec sec
    usec=$(systemctl show "$unit" -p TimeoutStopUSec 2>/dev/null | head -n1 | cut -d= -f2)
    case "$usec" in
        ''|*[!0-9]*)
            printf ''
            ;;
        *)
            sec=$((usec / 1000000))
            [ "$sec" -lt "$POLARDBX_STOP_TIMEOUT" ] && sec=$POLARDBX_STOP_TIMEOUT
            printf '%s' "$sec"
            ;;
    esac
}

stop_polardbx_service() {
    local units=""
    local init_scripts=""
    local u
    local tmo
    local stopped=""
    local failed=""

    # systemd：先扫 unit 文件（覆盖已安装未启用的），再扫运行中的 unit
    if command -v systemctl >/dev/null 2>&1; then
        units=$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
                 | awk '{print $1}' | grep -i 'polardbx')
        if [ -z "$units" ]; then
            units=$(systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null \
                     | awk '{print $1}' | grep -i 'polardbx')
        fi
    fi

    # SysV init 脚本兜底
    if [ -z "$units" ]; then
        for f in /etc/init.d/polardbx*; do
            [ -e "$f" ] && init_scripts="$init_scripts $(basename "$f")"
        done
    fi

    if [ -z "$units" ] && [ -z "$init_scripts" ]; then
        log "INFO" "未检测到 polardbx 服务，跳过停止"
        return 1
    fi

    for u in $units; do
        tmo=$(_stop_timeout_arg "$u")
        if [ -n "$tmo" ]; then
            log "INFO" "停止服务: $u（超时 ${tmo}s）"
            if systemctl stop --timeout="$tmo" "$u" >> "$LOG_FILE" 2>&1; then
                log "INFO" "已停止服务: $u"
                stopped="$stopped $u"
            else
                log "WARNING" "停止服务失败: $u（继续执行，请确认数据已落盘后再重启）"
                failed="$failed $u"
            fi
        else
            log "INFO" "停止服务: $u（未获取到超时配置，使用单元默认值）"
            if systemctl stop "$u" >> "$LOG_FILE" 2>&1; then
                log "INFO" "已停止服务: $u"
                stopped="$stopped $u"
            else
                log "WARNING" "停止服务失败: $u（继续执行，请确认数据已落盘后再重启）"
                failed="$failed $u"
            fi
        fi
    done

    for u in $init_scripts; do
        if service "$u" stop >> "$LOG_FILE" 2>&1; then
            log "INFO" "已停止服务(SysV): $u"
            stopped="$stopped $u"
        else
            log "WARNING" "停止服务失败(SysV): $u（继续执行，请确认数据已落盘后再重启）"
            failed="$failed $u"
        fi
    done

    POLARDBX_STOPPED="$stopped"
    [ -n "$stopped" ] && log "INFO" "polardbx 服务停止完成:$stopped"
    [ -n "$failed" ] && log "WARNING" "以下 polardbx 服务未能停止:$failed"
    return 0
}

# 11. 重启确认
log "INFO" "### 步骤 10: 重启系统..."

read -p "是否立即重启系统？(y/n): " restart_confirm
case "$restart_confirm" in
    y|Y)
        # 重启前的准备，顺序不可调换：
        #   1) 先正常停止 polardbx，让数据库自己完成一次干净刷盘
        #   2) 再 sync 把剩余缓存刷到磁盘
        #   3) 最后重启
        # sync 必须排在停库之后，否则重启后数据库仍会走 crash recovery。
        log "INFO" "检查并停止 polardbx 服务（若存在）..."
        stop_polardbx_service
        log "INFO" "执行sync命令强制写入缓存(重复5次)..."
        sync && sync && sync && sync && sync
        log "INFO" "系统将在10秒后重启..."
        for i in {10..1}; do
            echo -ne "倒计时: $i 秒\r"
            sleep 1
        done
        log "INFO" "正在重启系统..."
        if ! reboot; then
            log "ERROR" "重启命令执行失败，系统未重启"
            if [ -n "$POLARDBX_STOPPED" ]; then
                log "WARNING" "polardbx 服务已停止但系统未重启，请手工拉起: systemctl start ${POLARDBX_STOPPED# }"
            fi
        fi
        ;;
    *)
        log "WARNING" "请手动重启以完成升级"
        log "INFO" "清理命令: rm -rf $TARGET_DIR"
        log "INFO" "恢复YUM源: mv $BACKUP_DIR/* /etc/yum.repos.d/"
        log "INFO" "本次未重启，polardbx 服务未停止，数据库保持运行状态"
        log "INFO" "执行sync命令强制写入缓存(重复5次)..."
        sync && sync && sync && sync && sync
        log "INFO" "脚本执行完毕，未重启系统"
        ;;
esac

# 记录脚本结束
log "INFO" "脚本执行完成"
log "INFO" "升级日志已保存至: $LOG_FILE"
