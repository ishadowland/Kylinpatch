#!/bin/bash
# 按日期筛选并下载指定源路径下的 RPM 补丁包
# 用法:
#   ./downloadPatchByDate.sh <源URL> <起始日期(yyyymmdd)> [输出目录]
# 示例:
#   ./downloadPatchByDate.sh \
#     https://update.cs2c.com.cn/NS/V10/V10SP3/os/adv/lic/updates/x86_64/Packages/ \
#     20260801 \
#     /opt/Kylinpatch/supplement

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 分割线
DIVIDER_LONG="================================================================================="
DIVIDER_MID="----------------------------------------"

# 检查依赖
for cmd in curl sed awk grep; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}错误：缺少依赖命令 $cmd，请先安装${NC}" >&2
        exit 1
    fi
done

# 参数处理
if [ $# -lt 2 ]; then
    echo -e "${BLUE}${DIVIDER_LONG}${NC}"
    echo -e "${BLUE}                  按日期补充下载 RPM 补丁包                    ${NC}"
    echo -e "${BLUE}${DIVIDER_LONG}${NC}"
    echo -e "${BLUE}用法:${NC}"
    echo -e "  $0 <源URL> <起始日期(yyyymmdd)> [输出目录]"
    echo -e "${BLUE}示例:${NC}"
    echo -e "  $0 \\"
    echo -e "    https://update.cs2c.com.cn/NS/V10/V10SP3/os/adv/lic/updates/x86_64/Packages/ \\"
    echo -e "    20260801 \\"
    echo -e "    /opt/Kylinpatch/supplement"
    echo -e "${BLUE}${DIVIDER_LONG}${NC}"
    exit 1
fi

SOURCE_URL="$1"
START_DATE="$2"
OUTPUT_DIR="${3:-./supplement_rpm}"

# 规范化源URL（确保以 / 结尾）
case "$SOURCE_URL" in
    */) ;;
    *)   SOURCE_URL="${SOURCE_URL}/" ;;
esac

# 校验起始日期格式
if ! [[ "$START_DATE" =~ ^[0-9]{8}$ ]]; then
    echo -e "${RED}错误：起始日期格式不正确，应为 yyyymmdd，例如 20260801${NC}" >&2
    exit 1
fi

# 起始日期的有效性校验
if ! date -d "${START_DATE}" +%Y%m%d &>/dev/null; then
    echo -e "${RED}错误：起始日期 ${START_DATE} 不是有效日期${NC}" >&2
    exit 1
fi

# 临时目录
TEMP_DIR=$(mktemp -d -t kylin_supplement_XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 创建输出目录
mkdir -p "$OUTPUT_DIR"
if [ $? -ne 0 ]; then
    echo -e "${RED}错误：无法创建输出目录 $OUTPUT_DIR${NC}" >&2
    exit 1
fi

# 脚本说明
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
echo -e "${BLUE}                  按日期补充下载 RPM 补丁包                    ${NC}"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
echo -e "${BLUE}源地址:${NC}     $SOURCE_URL"
echo -e "${BLUE}起始日期:${NC}   $START_DATE (含)"
echo -e "${BLUE}输出目录:${NC}   $OUTPUT_DIR"
echo -e "${BLUE}临时目录:${NC}   $TEMP_DIR"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"

# 抓取目录索引
INDEX_FILE="$TEMP_DIR/index.html"
echo -e "${YELLOW}[1/5] 抓取目录索引...${NC}"
HTTP_CODE=$(curl -sS -L -o "$INDEX_FILE" -w "%{http_code}" --connect-timeout 30 --max-time 120 "$SOURCE_URL")
if [ "$HTTP_CODE" != "200" ] || [ ! -s "$INDEX_FILE" ]; then
    echo -e "${RED}错误：抓取目录索引失败 (HTTP $HTTP_CODE)${NC}" >&2
    exit 1
fi
TOTAL_RPM_COUNT=$(grep -c '\.rpm"' "$INDEX_FILE" 2>/dev/null || echo 0)
echo -e "${GREEN}索引抓取完成，共 ${TOTAL_RPM_COUNT} 个 RPM 文件${NC}"

# 解析索引，提取文件名与日期，过滤出 >= 起始日期的包
echo -e "${YELLOW}[2/5] 解析索引并筛选日期...${NC}"
PACKAGE_LIST="$TEMP_DIR/packages.list"
> "$PACKAGE_LIST"

sed -nE 's/.*href="([^"]+\.rpm)">[^<]+<\/a>[ ]+([0-9]{2}-[A-Z][a-z]{2}-[0-9]{4})[ ]+([0-9]{2}:[0-9]{2}).*/\2|\1|\3/p' "$INDEX_FILE" \
    | while IFS='|' read -r date fname time; do
        ymd=$(date -d "$date" +%Y%m%d 2>/dev/null)
        if [ -n "$ymd" ] && [ "$ymd" -ge "$START_DATE" ]; then
            echo "${ymd}|${fname}|${date} ${time}"
        fi
    done | sort -u > "$PACKAGE_LIST"

FILTERED_COUNT=$(wc -l < "$PACKAGE_LIST")
if [ "$FILTERED_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}没有找到日期在 ${START_DATE} 之后的包，无需下载${NC}"
    exit 0
fi
echo -e "${GREEN}筛选完成：${FILTERED_COUNT} 个包符合条件（>= ${START_DATE}）${NC}"

# 预览前 10 个
echo -e "${BLUE}预览（前 10 个）:${NC}"
head -10 "$PACKAGE_LIST" | while IFS='|' read -r ymd fname datetime; do
    printf "  ${BLUE}%-12s${NC} %s\n" "$ymd" "$fname"
done
if [ "$FILTERED_COUNT" -gt 10 ]; then
    echo -e "  ${BLUE}... 等共 ${FILTERED_COUNT} 个包${NC}"
fi

# 下载
echo -e "${YELLOW}[3/5] 开始下载...${NC}"
LOG_FILE="$TEMP_DIR/download.log"
DOWNLOAD_OK_LIST="$TEMP_DIR/downloaded.list"
DOWNLOAD_FAIL_LIST="$TEMP_DIR/failed.list"
> "$DOWNLOAD_OK_LIST"
> "$DOWNLOAD_FAIL_LIST"

CURRENT=0
while IFS='|' read -r ymd fname datetime; do
    CURRENT=$((CURRENT + 1))
    echo -ne "\r  进度: [${CURRENT}/${FILTERED_COUNT}] 正在下载: $(basename "$fname") ...   "

    # URL 直接使用索引页里的 href 形式（包含 %2B 等编码），服务器能正确识别
    DOWNLOAD_URL="${SOURCE_URL}${fname}"

    # 使用 -C - 实现断点续传；--retry 加重试
    HTTP_RESULT=$(curl -sS -L -o "${OUTPUT_DIR}/$(basename "$fname")" \
        -w "%{http_code}" \
        --connect-timeout 30 --max-time 600 \
        --retry 3 --retry-delay 5 --retry-all-errors \
        "$DOWNLOAD_URL" 2>>"$LOG_FILE")
    CURL_RC=$?

    if [ $CURL_RC -eq 0 ] && [ "$HTTP_RESULT" = "200" ] && [ -s "${OUTPUT_DIR}/$(basename "$fname")" ]; then
        echo "${ymd}|$(basename "$fname")" >> "$DOWNLOAD_OK_LIST"
    else
        echo "${ymd}|$(basename "$fname")|HTTP ${HTTP_RESULT}|curl RC ${CURL_RC}" >> "$DOWNLOAD_FAIL_LIST"
        # 删除可能产生的空文件
        rm -f "${OUTPUT_DIR}/$(basename "$fname")"
    fi
done < "$PACKAGE_LIST"

echo "" # 换行
OK_COUNT=$(wc -l < "$DOWNLOAD_OK_LIST")
FAIL_COUNT=$(wc -l < "$DOWNLOAD_FAIL_LIST")
echo -e "${GREEN}下载完成：成功 ${OK_COUNT} 个，失败 ${FAIL_COUNT} 个${NC}"

# 列出失败项
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}[4/5] 以下包下载失败:${NC}"
    cat "$DOWNLOAD_FAIL_LIST" | while IFS='|' read -r ymd fname http curlrc; do
        echo -e "  ${RED}-${NC} $fname (${http})"
    done
fi

# 生成下载清单
echo -e "${YELLOW}[5/5] 生成下载清单...${NC}"
MANIFEST="${OUTPUT_DIR}/download_manifest_${START_DATE}.txt"
{
    echo "=== 补充下载清单 ==="
    echo "源地址:      $SOURCE_URL"
    echo "起始日期:    $START_DATE (含)"
    echo "生成时间:    $(date)"
    echo "下载总数:    ${FILTERED_COUNT} (成功 ${OK_COUNT} / 失败 ${FAIL_COUNT})"
    echo "输出目录:    $OUTPUT_DIR"
    echo ""
    printf "%-12s %-25s %s\n" "日期" "时间" "文件名"
    printf "%-12s %-25s %s\n" "----" "----" "------"
    sort "$DOWNLOAD_OK_LIST" | while IFS='|' read -r ymd fname; do
        # 从原始 PACKAGE_LIST 反查 datetime
        orig=$(grep -F "|$fname|" "$PACKAGE_LIST" | head -1)
        datetime=$(echo "$orig" | cut -d'|' -f3)
        printf "%-12s %-25s %s\n" "$ymd" "$datetime" "$fname"
    done
} > "$MANIFEST"

echo -e "${GREEN}下载清单已生成: ${MANIFEST}${NC}"

# 最终输出
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
echo -e "${GREEN}                       补充下载结果                       ${NC}"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
printf "${BLUE}%-15s: ${NC}%s\n" "源地址" "$SOURCE_URL"
printf "${BLUE}%-15s: ${NC}%s\n" "起始日期" "$START_DATE"
printf "${BLUE}%-15s: ${NC}%s\n" "符合包数" "$FILTERED_COUNT"
printf "${BLUE}%-15s: ${NC}%s\n" "成功下载" "$OK_COUNT"
printf "${BLUE}%-15s: ${NC}%s\n" "失败数量" "$FAIL_COUNT"
printf "${BLUE}%-15s: ${NC}%s\n" "输出目录" "$OUTPUT_DIR"
printf "${BLUE}%-15s: ${NC}%s\n" "下载清单" "$MANIFEST"
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" 2>/dev/null | awk '{print $1}')
printf "${BLUE}%-15s: ${NC}%s\n" "总大小" "$TOTAL_SIZE"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"

# 若失败数>0 退出码非0
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}警告：存在 ${FAIL_COUNT} 个下载失败的包，请检查网络或稍后重试${NC}" >&2
    exit 1
fi

echo -e "${GREEN}所有包下载完成！${NC}"
echo -e "${BLUE}${DIVIDER_LONG}${NC}"
