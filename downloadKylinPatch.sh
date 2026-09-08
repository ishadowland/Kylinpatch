#!/bin/bash
# 020507051235
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 定义变量
TARGET_DIR="/opt/Kylinpatch"

# 分割线定义
DIVIDER_LONG="================================================================================="
DIVIDER_MID="----------------------------------------"

# 脚本说明
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
echo -e "${BLUE}                    麒麟系统补丁下载与打包脚本                    ${NC}"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
echo -e "${BLUE}功能:${NC}"
echo -e "${BLUE}1. 自动下载系统更新包${NC}"
echo -e "${BLUE}2. 生成补丁包和校验文件${NC}"
echo -e "${BLUE}3. 记录更新事务信息${NC}"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"

# 检查/etc/.kyinfo文件是否存在
echo -e "${YELLOW}[步骤1/9] 检查系统信息文件...${NC}"
if [ ! -f "/etc/.kyinfo" ]; then
    echo -e "${RED}错误：/etc/.kyinfo 文件不存在，无法获取系统信息${NC}" >&2
    exit 1
fi
#TODO: 在此处增加检查初始的yums.repo配置，记录原始下载路径以备比对

# 从/etc/.kyinfo中提取所需信息
echo -e "${YELLOW}[步骤2/9] 提取系统信息...${NC}"
arch=$(grep '^arch=' /etc/.kyinfo | cut -d'=' -f2 | tr -d '[:space:]')
dist_id=$(grep '^dist_id=' /etc/.kyinfo | cut -d'=' -f2 | tr -d '[:space:]')
milestone=$(grep '^milestone=' /etc/.kyinfo | cut -d'=' -f2 | tr -d '[:space:]')

# 处理架构信息
case "$arch" in
    "x86_64") arch_short="X86" ;;
    "aarch64"|"arm64") arch_short="ARM" ;;
    *)
        echo -e "${YELLOW}警告：未知架构 '$arch'，将使用原值${NC}" >&2
        arch_short="$arch"
        ;;
esac

# 提取版本号（适配多种格式）
if [[ $dist_id =~ -([0-9]{4})-Release- ]]; then
    minor_version=${BASH_REMATCH[1]}
elif [[ $dist_id =~ General-Release-([0-9]{4}) ]]; then
    minor_version=${BASH_REMATCH[1]}
elif [[ $milestone =~ SP([0-9]+) ]]; then
    minor_version="SP${BASH_REMATCH[1]}"
else
    minor_version=$(date +"%y%m")
    echo -e "${YELLOW}警告：无法从dist_id中提取小版本号，使用当前年月: $minor_version${NC}" >&2
fi

# 获取当前日期
current_date=$(date +"%y%m%d")

# 生成文件名
filename="KylinUpgrade${arch_short}-${minor_version}-${current_date}.tar.gz"
infofile="${filename}.info"
md5file="${filename}.md5"

echo -e "${GREEN}系统信息提取完成:${NC}"
printf "${BLUE}%-15s: ${NC}%s\n" "架构" "$arch (简称: $arch_short)"
printf "${BLUE}%-15s: ${NC}%s\n" "小版本号" "$minor_version"
printf "${BLUE}%-15s: ${NC}%s\n" "打包日期" "$current_date"
printf "${BLUE}%-15s: ${NC}%s\n" "补丁包文件" "$filename"
printf "${BLUE}%-15s: ${NC}%s\n" "信息文件" "$infofile"
printf "${BLUE}%-15s: ${NC}%s\n" "MD5校验文件" "$md5file"

# 检查并卸载 mariadb
if rpm -qa | grep -q "^mariadb"; then
    echo -e "${YELLOW}检测到 mariadb，开始卸载...${NC}"
    
    # 循环卸载每个包
    failed=0
    for pkg in $(rpm -qa | grep "^mariadb"); do
        rpm -e --nodeps "$pkg"
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误：包 $pkg 卸载失败${NC}" >&2
            failed=1
        fi
    done

    # 最终状态检查
    if rpm -qa | grep -q "^mariadb"; then
        echo -e "${RED}错误：mariadb 未彻底卸载${NC}" >&2
        exit 1
    elif [ $failed -eq 0 ]; then
        echo -e "${GREEN}mariadb 卸载成功${NC}"
    else
        echo -e "${RED}错误：mariadb 卸载过程中发生错误${NC}" >&2
        exit 1
    fi
fi
# 清理旧目录

echo -e "${YELLOW}[步骤3/9] 清理旧目录...${NC}"
rm -rf ${TARGET_DIR}/
[ $? -eq 0 ] && echo -e "${GREEN}旧目录清理完成${NC}" || echo -e "${YELLOW}警告：清理旧目录时出现问题${NC}" >&2

# 创建新目录
echo -e "${YELLOW}[步骤4/9] 创建新目录...${NC}"
mkdir -p ${TARGET_DIR}/packages
[ $? -eq 0 ] && echo -e "${GREEN}目录创建成功: /opt/Kylinpatch/packages${NC}" || { echo -e "${RED}错误：无法创建目录${NC}" >&2; exit 1; }

# 清理yum缓存
echo -e "${YELLOW}[步骤5/9] 清理yum缓存...${NC}"
yum clean all
[ $? -eq 0 ] && echo -e "${GREEN}yum缓存清理完成${NC}" || echo -e "${YELLOW}警告：yum缓存清理时出现问题${NC}" >&2

# 重建yum缓存
echo -e "${YELLOW}[步骤6/9] 重建yum缓存...${NC}"
yum makecache
[ $? -eq 0 ] && echo -e "${GREEN}yum缓存重建完成${NC}" || { echo -e "${RED}错误：yum缓存重建失败${NC}" >&2; exit 1; }

# 配置yum下载参数，提升对不稳定网络的容错能力
echo -e "${BLUE}  配置yum重试与超时参数...${NC}"
if command -v yum-config-manager &>/dev/null; then
    # 增加重试次数与超时时间，缓解网络抖动导致的下载失败
    yum-config-manager --setopt=timeout=300 --save >/dev/null 2>&1 || true
    yum-config-manager --setopt=retries=10 --save >/dev/null 2>&1 || true
    yum-config-manager --setopt=minrate=100 --save >/dev/null 2>&1 || true
    yum-config-manager --setopt=throttle=0 --save >/dev/null 2>&1 || true
    echo -e "${GREEN}yum参数配置完成 (timeout=300, retries=10)${NC}"
else
    echo -e "${YELLOW}警告：yum-config-manager不可用，跳过参数优化${NC}" >&2
fi

# 下载升级包并捕获Transaction Summary
echo -e "${YELLOW}[步骤7/9] 下载升级包并记录Transaction Summary...${NC}"

# 先获取预期的Transaction Summary（不实际下载），用于后续校验
echo -e "${BLUE}  正在获取事务摘要以预估下载量...${NC}"
TRANSACTION_PREVIEW=$(yum upgrade -y --downloadonly --downloaddir=/opt/Kylinpatch/packages --assumeno 2>&1 || true)

# 解析预期总下载大小（支持中英文 "Total download size:" / "总下载大小："）
PREVIEW_SIZE_LINE=$(echo "$TRANSACTION_PREVIEW" | grep -E "(Total download size:|总下载大小：)")
if [ -n "$PREVIEW_SIZE_LINE" ]; then
    # 取第一个数字作为数值，字母作为单位
    EXPECTED_DOWNLOAD_SIZE_BYTES=$(echo "$PREVIEW_SIZE_LINE" | grep -oE '[0-9]+\.?[0-9]*' | head -1 | awk -F. '{print $1}')
    EXPECTED_DOWNLOAD_SIZE_UNIT=$(echo "$PREVIEW_SIZE_LINE" | grep -oE '[A-Za-z]' | head -1)
    case "$EXPECTED_DOWNLOAD_SIZE_UNIT" in
        G|g) EXPECTED_DOWNLOAD_SIZE_BYTES=$((EXPECTED_DOWNLOAD_SIZE_BYTES * 1024 * 1024 * 1024)) ;;
        M|m) EXPECTED_DOWNLOAD_SIZE_BYTES=$((EXPECTED_DOWNLOAD_SIZE_BYTES * 1024 * 1024)) ;;
        K|k) EXPECTED_DOWNLOAD_SIZE_BYTES=$((EXPECTED_DOWNLOAD_SIZE_BYTES * 1024)) ;;
        *)   EXPECTED_DOWNLOAD_SIZE_BYTES=$((EXPECTED_DOWNLOAD_SIZE_BYTES * 1024 * 1024)) ;;
    esac
else
    EXPECTED_DOWNLOAD_SIZE_BYTES=0
fi

# 解析预期包数量：优先用 "Downloading Packages: (N/M)"，否则从 Transaction Summary 累加
EXPECTED_PKG_COUNT=$(echo "$TRANSACTION_PREVIEW" | grep -oE "Downloading Packages: \([0-9]+/[0-9]+\)" | grep -oE '[0-9]+' | tail -1)
if [ -z "$EXPECTED_PKG_COUNT" ]; then
    # 兜底：从 Transaction Summary 中累加 Install / Upgrade 数量
    EXPECTED_PKG_COUNT=$(echo "$TRANSACTION_PREVIEW" | grep -E "(Install|Upgrade|安装|升级)" | awk '{s+=$1} END {print s+0}')
fi

if [ -z "$EXPECTED_DOWNLOAD_SIZE_BYTES" ] || [ "$EXPECTED_DOWNLOAD_SIZE_BYTES" -eq 0 ]; then
    echo -e "${YELLOW}  警告：无法解析预期下载大小，将以包数量与 yum 返回码作为校验依据${NC}" >&2
    EXPECTED_DOWNLOAD_SIZE_BYTES=0
fi
if [ -z "$EXPECTED_PKG_COUNT" ] || [ "$EXPECTED_PKG_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}  警告：无法解析预期包数量，将以 yum 返回码作为校验依据${NC}" >&2
    EXPECTED_PKG_COUNT=0
fi

echo -e "${BLUE}  预期下载: ${EXPECTED_PKG_COUNT} 个包, 约 $(echo "$EXPECTED_DOWNLOAD_SIZE_BYTES" | awk '{printf "%.2f", $1/1024/1024}') MB${NC}"

{
    echo "=== 系统信息 ==="
    printf "%-15s: %s\n" "架构" "$arch"
    printf "%-15s: %s\n" "小版本号" "$minor_version"
    printf "%-15s: %s\n" "打包日期" "$current_date"
    printf "%-15s: %s\n" "生成时间" "$(date)"
    printf "%-15s: %s\n" "原始dist_id" "$dist_id"
    echo ""
    echo "=== yum upgrade Transaction Summary ==="
    yum upgrade -y --downloadonly --downloaddir=/opt/Kylinpatch/packages | tee /dev/tty | awk '/^Transaction Summary:/,/^Is this ok/ || /^Downloading packages:/'
} > "/opt/${infofile}"

YUM_RC=${PIPESTATUS[0]}
if [ $YUM_RC -eq 0 ]; then
    echo -e "${GREEN}升级包下载完成${NC}"
else
    echo -e "${RED}警告：下载升级包时出现问题(yum返回码: $YUM_RC)${NC}" >&2
fi

# 若 yum 返回码非 0，直接中断打包流程，避免产生残缺补丁包
if [ $YUM_RC -ne 0 ]; then
    ACTUAL_PKG_COUNT_QUICK=$(ls /opt/Kylinpatch/packages/*.rpm 2>/dev/null | wc -l)
    ACTUAL_DOWNLOAD_SIZE_MB_QUICK=$(du -sm /opt/Kylinpatch/packages 2>/dev/null | awk '{print $1}')

    {
        echo ""
        echo "=== 下载完整性校验 ==="
        echo "校验时间: $(date)"
        echo "yum 返回码: $YUM_RC (非 0，表示存在下载失败)"
        printf "预期包数量: %s\n" "$EXPECTED_PKG_COUNT"
        printf "实际包数量: %s\n" "$ACTUAL_PKG_COUNT_QUICK"
        printf "预期下载大小: %s MB\n" "$(echo "$EXPECTED_DOWNLOAD_SIZE_BYTES" | awk '{printf "%.2f", $1/1024/1024}')"
        printf "实际下载大小: %s MB\n" "$ACTUAL_DOWNLOAD_SIZE_MB_QUICK"
        echo "状态: 失败 (yum 报告存在包下载错误)"
    } >> "/opt/${infofile}"

    echo -e "${RED}=================================================================================${NC}" >&2
    echo -e "${RED}错误：yum 报告存在包下载失败，请检查网络后重试！${NC}" >&2
    echo -e "${RED}预期: ${EXPECTED_PKG_COUNT} 个包 / $(echo "$EXPECTED_DOWNLOAD_SIZE_BYTES" | awk '{printf "%.2f", $1/1024/1024}') MB${NC}" >&2
    echo -e "${RED}实际: ${ACTUAL_PKG_COUNT_QUICK} 个包 / ${ACTUAL_DOWNLOAD_SIZE_MB_QUICK} MB${NC}" >&2
    echo -e "${RED}=================================================================================${NC}" >&2
    echo -e "${YELLOW}提示：可尝试重新执行本脚本，或检查网络后重试${NC}" >&2
    exit 1
fi

# 完整性校验：对比实际下载与预期值
echo -e "${BLUE}  正在校验下载完整性...${NC}"
ACTUAL_PKG_COUNT=$(ls /opt/Kylinpatch/packages/*.rpm 2>/dev/null | wc -l)
ACTUAL_DOWNLOAD_SIZE_BYTES=$(du -sb /opt/Kylinpatch/packages 2>/dev/null | awk '{print $1}')
ACTUAL_DOWNLOAD_SIZE_MB=$(echo "$ACTUAL_DOWNLOAD_SIZE_BYTES" | awk '{printf "%.2f", $1/1024/1024}')

echo -e "${BLUE}  实际下载: ${ACTUAL_PKG_COUNT} 个包, ${ACTUAL_DOWNLOAD_SIZE_MB} MB${NC}"

DOWNLOAD_OK=1
DOWNLOAD_ISSUES=""

# 包数量校验
if [ "$EXPECTED_PKG_COUNT" -gt 0 ] && [ "$ACTUAL_PKG_COUNT" -ne "$EXPECTED_PKG_COUNT" ]; then
    DOWNLOAD_OK=0
    DOWNLOAD_ISSUES="${DOWNLOAD_ISSUES}包数量不符: 预期 ${EXPECTED_PKG_COUNT} 个, 实际 ${ACTUAL_PKG_COUNT} 个\n"
fi

# 大小校验（允许 5% 误差，避免误判）
if [ "$EXPECTED_DOWNLOAD_SIZE_BYTES" -gt 0 ]; then
    LOWER_LIMIT=$((EXPECTED_DOWNLOAD_SIZE_BYTES * 95 / 100))
    if [ "$ACTUAL_DOWNLOAD_SIZE_BYTES" -lt "$LOWER_LIMIT" ]; then
        DOWNLOAD_OK=0
        DOWNLOAD_ISSUES="${DOWNLOAD_ISSUES}包大小不足: 预期至少 $(echo "$EXPECTED_DOWNLOAD_SIZE_BYTES" | awk '{printf "%.2f", $1/1024/1024}') MB, 实际 ${ACTUAL_DOWNLOAD_SIZE_MB} MB\n"
    fi
fi

if [ $DOWNLOAD_OK -eq 0 ]; then
    {
        echo ""
        echo "=== 下载完整性校验 ==="
        echo "校验时间: $(date)"
        printf "预期包数量: %s\n" "$EXPECTED_PKG_COUNT"
        printf "实际包数量: %s\n" "$ACTUAL_PKG_COUNT"
        printf "预期下载大小: %s MB\n" "$(echo "$EXPECTED_DOWNLOAD_SIZE_BYTES" | awk '{printf "%.2f", $1/1024/1024}')"
        printf "实际下载大小: %s MB\n" "$ACTUAL_DOWNLOAD_SIZE_MB"
        echo "问题:"
        printf "$DOWNLOAD_ISSUES"
    } >> "/opt/${infofile}"

    echo -e "${RED}=================================================================================${NC}" >&2
    echo -e "${RED}错误：补丁下载不完整，请检查网络后重试！${NC}" >&2
    echo -e "${RED}预期: ${EXPECTED_PKG_COUNT} 个包 / $(echo "$EXPECTED_DOWNLOAD_SIZE_BYTES" | awk '{printf "%.2f", $1/1024/1024}') MB${NC}" >&2
    echo -e "${RED}实际: ${ACTUAL_PKG_COUNT} 个包 / ${ACTUAL_DOWNLOAD_SIZE_MB} MB${NC}" >&2
    echo -e "${RED}问题详情:${NC}" >&2
    printf "${RED}${DOWNLOAD_ISSUES}${NC}" >&2
    echo -e "${RED}=================================================================================${NC}" >&2
    echo -e "${YELLOW}提示：可尝试重新执行本脚本，或使用 --retries 参数调整 yum 重试次数${NC}" >&2
    exit 1
fi

echo -e "${GREEN}下载完整性校验通过${NC}"
{
    echo ""
    echo "=== 下载完整性校验 ==="
    echo "校验时间: $(date)"
    printf "预期包数量: %s\n" "$EXPECTED_PKG_COUNT"
    printf "实际包数量: %s\n" "$ACTUAL_PKG_COUNT"
    printf "实际下载大小: %s MB\n" "$ACTUAL_DOWNLOAD_SIZE_MB"
    echo "状态: 通过"
} >> "/opt/${infofile}"

# 打包下载的补丁
echo -e "${YELLOW}[步骤8/9] 打包下载的补丁...${NC}"
cd ${TARGET_DIR}/

# 创建本地YUM源
echo "建本地仓库..."
if ! command -v createrepo &>/dev/null; then
    yum install -y createrepo && echo "createrepo安装成功" || { echo "错误：createrepo安装失败"; exit 1; }
fi

createrepo ${TARGET_DIR}

cd ${TARGET_DIR} && tar -czvf "/opt/${filename}" . && cd -
if [ $? -eq 0 ]; then
    echo -e "${GREEN}补丁打包完成${NC}"
    echo "补丁包大小: $(du -sh /opt/${filename} | cut -f1)" | tee -a "/opt/${infofile}"
else
    echo -e "${RED}错误：打包过程中出现问题${NC}" >&2
    exit 1
fi

# 修复MD5文件格式问题
echo -e "${YELLOW}[步骤9/9] 生成MD5校验文件(修复格式)...${NC}"
cd /opt/
md5sum "${filename}" > "${md5file}"

if [ $? -eq 0 ]; then
    # 获取MD5校验码（不带文件名）
    md5_value=$(md5sum "${filename}" | awk '{print $1}')
    
    echo -e "${GREEN}MD5校验文件创建完成${NC}"
    echo "MD5校验码: ${md5_value}" | tee -a "/opt/${infofile}"
    
    # 验证MD5文件格式是否正确
    if grep -q "${filename}" "${md5file}"; then
        echo -e "${GREEN}MD5文件格式验证通过${NC}"
    else
        echo -e "${YELLOW}警告：MD5文件格式可能有问题${NC}" >&2
    fi
else
    echo -e "${RED}错误：生成MD5校验文件时出现问题${NC}" >&2
    exit 1
fi

# 添加验证信息到info文件
{
    echo ""
    echo "=== 验证信息 ==="
    echo "MD5校验命令: cd /opt && md5sum -c ${md5file}"
    echo "打包文件列表:"
    tar -ztvf "/opt/${filename}" | head -n 10
    echo "...(只显示前10个文件)"
} >> "/opt/${infofile}"

# 最终输出结果
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
echo -e "${GREEN}                         补丁包生成结果                         ${NC}"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
printf "${BLUE}%-18s: ${NC}%s\n" "补丁包文件" "/opt/${filename}"
printf "${BLUE}%-18s: ${NC}%s\n" "文件大小" "$(du -sh /opt/${filename} | cut -f1)"
printf "${BLUE}%-18s: ${NC}%s\n" "MD5校验文件" "/opt/${md5file}"
printf "${BLUE}%-18s: ${NC}%s\n" "MD5校验码" "${md5_value}"
printf "${BLUE}%-18s: ${NC}%s\n" "信息文件" "/opt/${infofile}"
echo -e "${BLUE}${DIVIDER_MID}${NC}"
echo -e "${YELLOW}验证文件完整性命令:${NC}"
echo -e "  cd /opt && md5sum -c ${md5file}"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
echo -e "${GREEN}脚本执行完成，所有操作已成功结束！${NC}"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"