# Kylinpatch

麒麟（Kylin）操作系统补丁下载、打包与升级工具集。

## 脚本清单

| 脚本 | 用途 |
|------|------|
| `downloadKylinPatch.sh` | 下载系统更新包并打包成 `KylinUpgrade*.tar.gz` |
| `getLocalRepo.sh`       | 从安装源下载所有包，去重后生成 YUM 本地仓库 |
| `upgradKylin.sh`        | 用 `KylinUpgrade*.tar.gz` 升级系统 |
| `downloadPatchByDate.sh` | 按日期筛选并补充下载源站上的 RPM |
| `mergeAndUpgrade.sh`     | 把补充下载的 RPM 合并进旧工作目录并重新升级 |

---

## 快速上手

### 场景一：常规升级（推荐首次使用）

```bash
# 1. 下载补丁并打包（root）
sudo ./downloadKylinPatch.sh
# 产物: /opt/KylinUpgrade<arch>-<version>-<date>.tar.gz
#       /opt/KylinUpgrade<arch>-<version>-<date>.tar.gz.md5
#       /opt/KylinUpgrade<arch>-<version>-<date>.tar.gz.info

# 2. 在目标机器上升级（root）
sudo ./upgradKylin.sh KylinUpgrade<arch>-<version>-<date>.tar.gz
```

### 场景二：网络不好，需要按日期补充缺失的包

```bash
# 1. 补充下载某日期之后的所有 rpm
sudo ./downloadPatchByDate.sh \
    https://update.cs2c.com.cn/NS/V10/V10SP3/os/adv/lic/updates/x86_64/Packages/ \
    20260801 \
    /opt/Kylinpatch/supplement

# 2. 合并到上次升级保留的工作目录，再升级
sudo ./mergeAndUpgrade.sh --packages-dir /opt/Kylinpatch/supplement
```

### 场景三：仅复用上次升级的目录重新跑一次升级

```bash
sudo ./mergeAndUpgrade.sh
```

### 场景四：补包前目录已被删

```bash
sudo ./mergeAndUpgrade.sh \
    --packages-dir /opt/Kylinpatch/supplement \
    --from-targz /opt/KylinUpgradeX86-2303-260907.tar.gz
```

---

## 详细说明

### `downloadKylinPatch.sh`

下载系统可用的所有更新 RPM，打包成 tar.gz。

- 自动从 `/etc/.kyinfo` 提取架构、版本号，生成文件名
- 通过 `yum upgrade --downloadonly` 下载到 `/opt/Kylinpatch/packages/`
- **下载完整性校验**：
  - 预演模式 `--assumeno` 解析预期包数量与下载大小
  - 实际下载完成后再做对比，包数或大小不符时立即报错退出
  - `yum` 返回非 0（如 `Curl error 28` 超时导致部分包失败）时**直接中断**，不再打包残缺包
- **网络容错**：调整 `timeout=300 retries=10 minrate=100` 减小超时误判
- 输出文件：
  - `KylinUpgrade<arch>-<version>-<date>.tar.gz` 补丁包
  - `KylinUpgrade<arch>-<version>-<date>.tar.gz.md5` MD5 校验文件
  - `KylinUpgrade<arch>-<version>-<date>.tar.gz.info` 系统信息与事务摘要

### `downloadPatchByDate.sh`

从 YUM 源站按日期筛选并下载 RPM。

```bash
./downloadPatchByDate.sh <源URL> <起始日期(yyyymmdd)> [输出目录]
```

- 抓取源站目录索引，解析 `DD-Mon-YYYY HH:MM` 时间戳
- 仅下载 `日期 >= 起始日期` 的 RPM（包含起始日）
- `curl --retry 3 --retry-delay 5 --retry-all-errors`，对网络抖动友好
- 原样使用索引里的 `href`（含 `%2B` 等编码），无需手工转义
- 在输出目录生成 `download_manifest_<起始日期>.txt` 清单
- 下载失败数 > 0 时 exit 1

### `mergeAndUpgrade.sh`

把补充下载的 RPM 合并进工作目录并升级。

```bash
sudo ./mergeAndUpgrade.sh [选项]

选项:
  --packages-dir <目录>     把该目录下的 *.rpm 合并进 /opt/Kylinpatch/packages
  --from-targz   <tar.gz>   工作目录不存在时从 tar.gz 解压
  --keep-workdir 0|1        升级后是否保留工作目录 (默认 1 保留)
  -y, --yes                 跳过最终确认
  -h, --help                查看帮助
```

- 默认复用 `/opt/Kylinpatch`（上次升级保留的目录）
- 用 `cp -n` 合并 RPM（同名跳过，不覆盖）
- 自动 `createrepo` 重建 `repodata/`
- 检查 RPM 架构兼容性，与 `upgradKylin.sh` 一致
- 备份原 yum 源到 `/etc/yum.repos.d/backup_<时间戳>/`
- 写 `/etc/yum.repos.d/local.repo` 指 `file:///opt/Kylinpatch`
- 执行 `yum -y update`，完成后询问是否重启

### `upgradKylin.sh`

完整升级流程（包含 MD5 校验、解压、createrepo、yum update）。详见脚本内注释。

### `getLocalRepo.sh`

从源站下载**所有** RPM 并生成 YUM 本地仓库（按包名去重保留最新版）。适合离线场景。

---

## 文件布局

```
Kylinpatch/
├── downloadKylinPatch.sh    # 主下载打包脚本
├── downloadPatchByDate.sh   # 按日期补充下载
├── mergeAndUpgrade.sh       # 合并并升级
├── upgradKylin.sh           # 升级
├── getLocalRepo.sh          # 全量下载并生成 repo
└── README.md
```

升级运行时产物（默认在 `/opt/` 下）：

```
/opt/
├── Kylinpatch/              # 工作目录（可保留用于下次增量升级）
│   ├── packages/            # 所有 RPM
│   └── repodata/            # createrepo 元数据
└── KylinUpgrade<arch>-<version>-<date>.tar.gz  # 打包产物
```

---

## 常见问题

**Q：网络不稳导致部分包下载失败，现在怎么办？**
A：`downloadKylinPatch.sh` 现在会在失败时直接退出并报错，不会再生成残缺补丁包。重新运行脚本即可，已下载的包会从 yum 缓存读取。

**Q：上次升级后能不能直接再补一些包升级？**
A：可以。保留 `/opt/Kylinpatch` 目录，然后用 `downloadPatchByDate.sh` 补充下载，最后跑 `mergeAndUpgrade.sh --packages-dir <补充包目录>`。

**Q：升级失败了怎么回滚 yum 源？**
A：合并升级备份在 `/etc/yum.repos.d/backup_<时间戳>/`，恢复命令：
```bash
sudo mv /etc/yum.repos.d/backup_<时间戳>/*.repo /etc/yum.repos.d/
```

**Q：能不能在不同架构间复用？**
A：不能。`mergeAndUpgrade.sh` 会校验 RPM 架构与 `/etc/.kyinfo` 中声明的架构是否匹配。
