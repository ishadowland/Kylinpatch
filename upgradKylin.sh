#!/bin/bash

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
    OS_NAME=$(grep '^name=' "$KYINFO_FILE" | cut -d= -f2 | tr -d '"')
    OS_VERSION=$(grep '^version=' "$KYINFO_FILE" | cut -d= -f2 | tr -d '"')
    OS_MILESTONE=$(grep '^milestone=' "$KYINFO_FILE" | cut -d= -f2 | tr -d '"')
    OS_ARCH=$(grep '^arch=' "$KYINFO_FILE" | cut -d= -f2 | tr -d '"')
    
    log "INFO" "----------------------------------------"
    log "INFO" "系统摘要信息:"
    log "INFO" "操作系统名称: $OS_NAME"
    log "INFO" "版本号: $OS_VERSION"
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
yum clean all >> "$LOG_FILE" 2>&1
yum makecache >> "$LOG_FILE" 2>&1

# 9. 检查可用更新
log "INFO" "### 步骤 8: 检查可用更新..."
yum check-update >> "$LOG_FILE" 2>&1
log "INFO" "检查更新完成"

# 10. 执行升级
log "INFO" "### 步骤 9: 执行系统升级..."
log "INFO" "开始升级..."
yum -y --color=always upgrade --nobest 2>&1 | tee -a "$LOG_FILE"
log "INFO" "升级完成"

# 11. 重启确认
log "INFO" "### 步骤 10: 重启系统..."
log "INFO" "执行sync命令强制写入缓存(重复5次)..."
sync && sync && sync && sync && sync

read -p "是否立即重启系统？(y/n): " restart_confirm
case "$restart_confirm" in
    y|Y)
        log "INFO" "系统将在10秒后重启..."
        for i in {10..1}; do
            echo -ne "倒计时: $i 秒\r"
            sleep 1
        done
        log "INFO" "正在重启系统..."
        reboot
        ;;
    *)
        log "WARNING" "请手动重启以完成升级"
        log "INFO" "清理命令: rm -rf $TARGET_DIR"
        log "INFO" "恢复YUM源: mv $BACKUP_DIR/* /etc/yum.repos.d/"
        log "INFO" "脚本执行完毕，未重启系统"
        ;;
esac

# 记录脚本结束
log "INFO" "脚本执行完成"
log "INFO" "升级日志已保存至: $LOG_FILE"
