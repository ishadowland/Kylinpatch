#!/bin/bash
# 从安装源下载所有包，相同名称不同版本的只保留最新的一个，并生成repo

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 定义变量
PKG_URL="https://update.cs2c.com.cn/NS/V10/V10SP1.1/os/adv/lic/updates/x86_64/Packages/"
TARGET_DIR="packages"
TEMP_DIR=".temp_download"

# 脚本说明
echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}          安装源包下载与Repo生成工具          ${NC}"
echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}源地址:${NC} $PKG_URL"
echo -e "${BLUE}目标目录:${NC} $TARGET_DIR"

# 检查必要命令是否存在
check_dependency() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}错误: 命令 $1 未找到，请先安装${NC}" >&2
        exit 1
    fi
}

# 检查依赖
check_dependency wget
check_dependency rpm
check_dependency createrepo

# 创建目录
echo -e "${YELLOW}[1/5] 创建工作目录...${NC}"
rm -rf $TEMP_DIR
mkdir -p $TARGET_DIR $TEMP_DIR
if [ $? -ne 0 ]; then
    echo -e "${RED}错误: 无法创建目录${NC}" >&2
    exit 1
fi

# 下载所有包
echo -e "${YELLOW}[2/5] 从源地址下载所有包...${NC}"
wget -q -r -np -nd -P $TEMP_DIR $PKG_URL/*.rpm
if [ $? -ne 0 ]; then
    echo -e "${RED}错误: 下载包失败${NC}" >&2
    exit 1
fi

# 检查是否有下载的包
if [ $(find $TEMP_DIR -name "*.rpm" | wc -l) -eq 0 ]; then
    echo -e "${RED}错误: 未找到任何rpm包${NC}" >&2
    exit 1
fi

# 筛选最新版本的包
echo -e "${YELLOW}[3/5] 筛选最新版本的包...${NC}"
declare -A latest_packages

# 遍历所有下载的rpm包
for rpmfile in $TEMP_DIR/*.rpm; do
    # 获取包名和版本
    pkg_name=$(rpm -qp --queryformat "%{NAME}" "$rpmfile" 2>/dev/null)
    pkg_version=$(rpm -qp --queryformat "%{VERSION}-%{RELEASE}" "$rpmfile" 2>/dev/null)
    
    # 跳过无法解析的包
    if [ -z "$pkg_name" ] || [ -z "$pkg_version" ]; then
        echo -e "${YELLOW}警告: 无法解析包信息: $(basename $rpmfile)${NC}" >&2
        continue
    fi
    
    # 比较版本并保留最新版本
    if [ -z "${latest_packages[$pkg_name]}" ]; then
        latest_packages[$pkg_name]="$pkg_version|$rpmfile"
    else
        current_version=$(echo "${latest_packages[$pkg_name]}" | cut -d'|' -f1)
        current_file=$(echo "${latest_packages[$pkg_name]}" | cut -d'|' -f2)
        
        # 使用rpmdev-vercmp比较版本，如果不可用则使用sort -V
        if command -v rpmdev-vercmp &>/dev/null; then
            if rpmdev-vercmp "$pkg_version" "$current_version" >/dev/null; then
                latest_packages[$pkg_name]="$pkg_version|$rpmfile"
            fi
        else
            # 使用sort -V作为备选方案
            if echo -e "$current_version\n$pkg_version" | sort -V | tail -n1 | grep -q "$pkg_version"; then
                latest_packages[$pkg_name]="$pkg_version|$rpmfile"
            fi
        fi
    fi
done

# 复制最新版本的包到目标目录
echo -e "${YELLOW}[4/5] 复制最新版本的包到目标目录...${NC}"
rm -rf $TARGET_DIR/*.rpm
for entry in "${latest_packages[@]}"; do
    rpmfile=$(echo "$entry" | cut -d'|' -f2)
    cp "$rpmfile" "$TARGET_DIR/"
done

# 生成repo
echo -e "${YELLOW}[5/5] 使用createrepo生成repo...${NC}"
createrepo $TARGET_DIR
if [ $? -ne 0 ]; then
    echo -e "${RED}错误: createrepo执行失败${NC}" >&2
    exit 1
fi

# 清理临时文件
rm -rf $TEMP_DIR

# 输出结果
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}操作完成!${NC}"
echo -e "${GREEN}已下载并筛选 ${#latest_packages[@]} 个包${NC}"
echo -e "${GREEN}包目录:${NC} $(realpath $TARGET_DIR)"
echo -e "${GREEN}repo数据已生成${NC}"
echo -e "${GREEN}=============================================${NC}"