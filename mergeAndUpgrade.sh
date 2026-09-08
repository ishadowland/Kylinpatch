#!/bin/bash
# 复用 /opt/Kylinpatch 工作目录，将补充下载的 RPM 合并进去后执行升级
# 用法:
#   ./mergeAndUpgrade.sh                              # 复用 /opt/Kylinpatch 直接升级
#   ./mergeAndUpgrade.sh --packages-dir <目录>        # 把目录里的 rpm 合并到 /opt/Kylinpatch/packages
#   ./mergeAndUpgrade.sh --from-targz <tar.gz>        # 若工作目录不存在，从 tar.gz 解压后升级
#   ./mergeAndUpgrade.sh --packages-dir <目录> --from-targz <tar.gz>
#   ./mergeAndUpgrade.sh --keep-workdir 0             # 升级后删除工作目录（默认 1 保留）

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认参数
TARGET_DIR="/opt/Kylinpatch"
PACKAGES_DIR=""
TARGZ_FILE=""
KEEP_WORKDIR=1
SKIP_CONFIRM=0

# 分割线
DIVIDER_LONG="================================================================================="
DIVIDER_MID="----------------------------------------"

# 参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        --packages-dir)
            PACKAGES_DIR="$2"
            shift 2
            ;;
        --from-targz)
            TARGZ_FILE="$2"
            shift 2
            ;;
        --keep-workdir)
            KEEP_WORKDIR="$2"
            shift 2
            ;;
        --yes|-y)
            SKIP_CONFIRM=1
            shift
            ;;
        -h|--help)
            echo -e "${BLUE}${DIVIDER_LONG}${NC}"
            echo -e "${BLUE}              合并补充 RPM 并复用工作目录升级                ${NC}"
            echo -e "${BLUE}${DIVIDER_LONG}${NC}"
            echo -e "${BLUE}用法:${NC}"
            echo -e "  $0 [选项]"
            echo -e ""
            echo -e "${BLUE}选项:${NC}"
            echo -e "  --packages-dir <目录>      把该目录下的 *.rpm 合并到 ${TARGET_DIR}/packages"
            echo -e "  --from-targz   <tar.gz>    工作目录不存在时，从该 tar.gz 解压后升级"
            echo -e "  --keep-workdir 0|1         升级后是否保留工作目录 (默认 1 保留)"
            echo -e "  -y, --yes                  跳过最终确认步骤"
            echo -e "  -h, --help                 显示此帮助"
            echo -e ""
            echo -e "${BLUE}典型场景:${NC}"
            echo -e "  1) 上次升级后保留了 ${TARGET_DIR}，现在用 downloadPatchByDate.sh"
            echo -e "     补下了若干 rpm，只需合并后重新 createrepo 并升级："
            echo -e "       $0 --packages-dir /opt/Kylinpatch/supplement"
            echo -e ""
            echo -e "  2) 上次升级后目录被删了，但 tar.gz 还在："
            echo -e "       $0 --packages-dir /opt/Kylinpatch/supplement \\"
            echo -e "          --from-targz /opt/KylinUpgradeX86-2303-260907.tar.gz"
            echo -e ""
            echo -e "  3) 仅复用原目录、不增加新包，直接重新跑一次升级："
            echo -e "       $0"
            echo -e "${BLUE}${DIVIDER_LONG}${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}错误：未知参数 $1${NC}" >&2
            echo -e "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 必须 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：必须使用 root 权限运行此脚本${NC}" >&2
    echo -e "请使用 'sudo $0 ...' 或切换到 root 用户"
    exit 1
fi

# 检查依赖
for cmd in yum tar createrepo; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}错误：缺少依赖命令 $cmd，请先安装${NC}" >&2
        exit 1
    fi
done

# 校验参数
if [ -n "$PACKAGES_DIR" ] && [ ! -d "$PACKAGES_DIR" ]; then
    echo -e "${RED}错误：补充包目录不存在: $PACKAGES_DIR${NC}" >&2
    exit 1
fi
if [ -n "$TARGZ_FILE" ] && [ ! -f "$TARGZ_FILE" ]; then
    echo -e "${RED}错误：补丁 tar.gz 文件不存在: $TARGZ_FILE${NC}" >&2
    exit 1
fi

# 脚本说明
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
echo -e "${BLUE}            合并补充 RPM 并复用工作目录升级                ${NC}"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
echo -e "${BLUE}工作目录:${NC}     $TARGET_DIR"
[ -n "$PACKAGES_DIR" ] && echo -e "${BLUE}补充包源:${NC}     $PACKAGES_DIR"
[ -n "$TARGZ_FILE" ]   && echo -e "${BLUE}回退包源:${NC}     $TARGZ_FILE"
echo -e "${BLUE}升级后保留:${NC}   $([ $KEEP_WORKDIR -eq 1 ] && echo "是" || echo "否")"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"

# 步骤 1: 准备工作目录
echo -e "${YELLOW}[步骤1/6] 准备工作目录 $TARGET_DIR ...${NC}"
if [ -d "$TARGET_DIR" ]; then
    # 目录已存在，检查关键子目录
    if [ ! -d "$TARGET_DIR/packages" ]; then
        echo -e "${YELLOW}  ${TARGET_DIR} 存在但缺少 packages 子目录，将创建${NC}"
        mkdir -p "$TARGET_DIR/packages" || { echo -e "${RED}错误：无法创建 packages 子目录${NC}" >&2; exit 1; }
    fi
    if [ ! -d "$TARGET_DIR/repodata" ]; then
        echo -e "${YELLOW}  ${TARGET_DIR} 缺少 repodata，将通过后续 createrepo 重建${NC}"
    fi
    EXISTING_RPM_COUNT=$(ls "$TARGET_DIR"/packages/*.rpm 2>/dev/null | wc -l)
    echo -e "${GREEN}  工作目录已存在，含 ${EXISTING_RPM_COUNT} 个 RPM${NC}"
else
    # 目录不存在，需要从 tar.gz 解压
    if [ -z "$TARGZ_FILE" ]; then
        echo -e "${RED}错误：工作目录 $TARGET_DIR 不存在，且未指定 --from-targz${NC}" >&2
        exit 1
    fi
    echo -e "${BLUE}  从 $TARGZ_FILE 解压补丁包...${NC}"
    mkdir -p "$TARGET_DIR"
    tar -xvf "$TARGZ_FILE" -C "$TARGET_DIR" || {
        echo -e "${RED}错误：解压 $TARGZ_FILE 失败${NC}" >&2
        exit 1
    }
    EXISTING_RPM_COUNT=$(ls "$TARGET_DIR"/packages/*.rpm 2>/dev/null | wc -l)
    echo -e "${GREEN}  解压完成，含 ${EXISTING_RPM_COUNT} 个 RPM${NC}"
fi

# 步骤 2: 合并补充 rpm
if [ -n "$PACKAGES_DIR" ]; then
    echo -e "${YELLOW}[步骤2/6] 合并补充 RPM...${NC}"
    SUPPLEMENT_COUNT=$(ls "$PACKAGES_DIR"/*.rpm 2>/dev/null | wc -l)
    if [ "$SUPPLEMENT_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}  补充目录 $PACKAGES_DIR 中没有 .rpm 文件，跳过合并${NC}"
    else
        echo -e "${BLUE}  复制 ${SUPPLEMENT_COUNT} 个补充包到 ${TARGET_DIR}/packages ...${NC}"
        # -n 不覆盖已有文件（同名则跳过），-v 显示进度
        cp -n "$PACKAGES_DIR"/*.rpm "$TARGET_DIR/packages/" || {
            echo -e "${RED}错误：复制补充包失败${NC}" >&2
            exit 1
        }
        NEW_COUNT=$(ls "$TARGET_DIR"/packages/*.rpm 2>/dev/null | wc -l)
        ADDED=$((NEW_COUNT - EXISTING_RPM_COUNT))
        echo -e "${GREEN}  合并完成：原有 ${EXISTING_RPM_COUNT} + 新增 ${ADDED} = 共 ${NEW_COUNT} 个 RPM${NC}"
    fi
else
    echo -e "${YELLOW}[步骤2/6] 未指定 --packages-dir，跳过合并${NC}"
fi

# 步骤 3: 重建 repo 元数据
echo -e "${YELLOW}[步骤3/6] 重建本地 YUM 仓库元数据...${NC}"
createrepo "$TARGET_DIR" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    # 有些版本 createrepo 输出在 stdout，加 -v 容易干扰界面；改用普通方式
    createrepo "$TARGET_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：createrepo 执行失败${NC}" >&2
        exit 1
    fi
fi
if [ ! -f "$TARGET_DIR/repodata/repomd.xml" ]; then
    echo -e "${RED}错误：repodata/repomd.xml 未生成${NC}" >&2
    exit 1
fi
TOTAL_RPM=$(ls "$TARGET_DIR"/packages/*.rpm 2>/dev/null | wc -l)
echo -e "${GREEN}  repodata 已重建，共 ${TOTAL_RPM} 个 RPM${NC}"

# 步骤 3.5: 检查 RPM 架构兼容性（与 upgradKylin.sh 一致）
echo -e "${YELLOW}[步骤3.5/6] 检查 RPM 架构兼容性...${NC}"
OS_ARCH=$(grep '^[[:space:]]*arch=' /etc/.kyinfo 2>/dev/null | sed 's/^[[:space:]]*arch=[[:space:]]*//' | tr -d '"')
[ -z "$OS_ARCH" ] && OS_ARCH=$(uname -m)
[ "$OS_ARCH" = "arm64" ] && OS_ARCH="aarch64"
echo -e "${BLUE}  系统架构: $OS_ARCH${NC}"

ARCH_MISMATCH=0
for rpm_file in "$TARGET_DIR"/packages/*.rpm; do
    [ -f "$rpm_file" ] || continue
    rpm_arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>/dev/null)
    [ -z "$rpm_arch" ] && continue
    [ "$rpm_arch" = "noarch" ] && continue
    [ "$rpm_arch" = "arm64" ] && rpm_arch="aarch64"
    if [ "$rpm_arch" != "$OS_ARCH" ]; then
        echo -e "${RED}  架构不匹配: $(basename "$rpm_file") ($rpm_arch)${NC}" >&2
        ARCH_MISMATCH=1
    fi
done
if [ $ARCH_MISMATCH -eq 1 ]; then
    echo -e "${RED}错误：存在与系统架构不兼容的 RPM，请清理后重试${NC}" >&2
    exit 1
fi
echo -e "${GREEN}  架构校验通过${NC}"

# 步骤 4: 备份并切换 yum 源
echo -e "${YELLOW}[步骤4/6] 配置 YUM 本地源...${NC}"
BACKUP_DIR="/etc/yum.repos.d/backup_$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
mv /etc/yum.repos.d/*.repo "$BACKUP_DIR" 2>/dev/null
EXISTING_REPO_COUNT=$(ls "$BACKUP_DIR"/*.repo 2>/dev/null | wc -l)
echo -e "${BLUE}  已备份 ${EXISTING_REPO_COUNT} 个 repo 到 $BACKUP_DIR${NC}"

cat > /etc/yum.repos.d/local.repo <<EOF
[local]
name=Local Repository
baseurl=file://${TARGET_DIR}
enabled=1
gpgcheck=0
priority=1
EOF
echo -e "${GREEN}  已写入 /etc/yum.repos.d/local.repo${NC}"

# 步骤 5: 清理缓存、执行升级
echo -e "${YELLOW}[步骤5/6] 执行系统升级...${NC}"
yum clean all >/dev/null 2>&1
yum makecache >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}错误：yum makecache 失败${NC}" >&2
    exit 1
fi

# 最终确认
if [ $SKIP_CONFIRM -eq 0 ]; then
    echo -e "${BLUE}${DIVIDER_LONG}${NC}"
    echo -e "${BLUE}即将执行 yum -y update，请确认:${NC}"
    echo -e "  工作目录:   $TARGET_DIR (含 $(ls $TARGET_DIR/packages/*.rpm 2>/dev/null | wc -l) 个 RPM)"
    echo -e "  YUM 源:     file://$TARGET_DIR"
    echo -e "${BLUE}${DIVIDER_LONG}${NC}"
    read -p "确认继续升级? (y/n): " confirm
    case "$confirm" in
        y|Y) ;;
        *)   echo -e "${YELLOW}已取消升级${NC}"; exit 0 ;;
    esac
fi

yum -y --color=always update
YUM_RC=$?
if [ $YUM_RC -ne 0 ]; then
    echo -e "${RED}错误：yum update 失败 (返回码 $YUM_RC)${NC}" >&2
    exit 1
fi
echo -e "${GREEN}  系统升级完成${NC}"

# 步骤 6: 清理（可选）+ 重启确认
echo -e "${YELLOW}[步骤6/6] 收尾...${NC}"
sync && sync && sync

# 恢复 yum 源（避免遗留 local.repo 影响后续操作）
rm -f /etc/yum.repos.d/local.repo
echo -e "${BLUE}  YUM 源备份保留在: $BACKUP_DIR${NC}"
echo -e "${BLUE}  恢复命令: mv $BACKUP_DIR/*.repo /etc/yum.repos.d/${NC}"

# 工作目录处理
if [ $KEEP_WORKDIR -eq 0 ]; then
    echo -e "${BLUE}  按要求删除工作目录 $TARGET_DIR ...${NC}"
    rm -rf "$TARGET_DIR"
else
    echo -e "${BLUE}  保留工作目录 $TARGET_DIR，下次可直接再跑: $0 --packages-dir <新补充包>${NC}"
fi

# 重启确认
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
read -p "是否立即重启系统? (y/n): " restart_confirm
case "$restart_confirm" in
    y|Y)
        echo -e "${GREEN}系统将在 10 秒后重启...${NC}"
        for i in {10..1}; do
            echo -ne "倒计时: $i 秒\r"
            sleep 1
        done
        reboot
        ;;
    *)
        echo -e "${YELLOW}请手动重启以完成升级${NC}"
        ;;
esac
