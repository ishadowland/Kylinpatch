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
| `php2shell_scan.sh`      | PHP2Shell 漏洞风险只读扫描（CVE-2026-109618 / 109619） |

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

### `php2shell_scan.sh`

PHP2Shell 漏洞风险**只读**扫描器。PHP 官方于 2026-10-21 披露 CVE-2026-109618（OOM 内存破坏）与 CVE-2026-109619（陈旧全局状态 UAF），两者 CVSS v4.0 均为 9.2，未认证即可 RCE。

```bash
./php2shell_scan.sh [选项]

选项:
  --log FILE        指定报告输出文件（默认 /var/log/php2shell_scan_<时间戳>.log）
  --web-root DIR    追加扫描的 Web 根目录，可多次使用
  --deep            深度模式：用 docker run 探测镜像内真实 PHP 版本
  --skip-docker     跳过容器扫描
  --skip-web        跳过 Web 目录扫描
  --max-depth N     Web 目录递归深度，默认 6
  --no-color        关闭彩色输出
  -h, --help        查看帮助

退出码: 0=无 CRIT/HIGH 风险  1=发现 CRIT/HIGH 风险  2=执行错误
```

- **只读**：不安装软件、不启停服务、不改配置、不动业务数据；唯一写入是报告日志文件
- **结论输出**：先给「总体判定：安全 / 存在风险」，再按 严重 / 高危 / 中危 / 低危 四级逐条列出风险明细（带标签、编号），最后给出编号式的修复建议——**只输出本次实际命中的条目**，不命中的不占篇幅
- **非 root 提示**：非 root 运行会提示漏检风险并给出可直接复制执行的 `sudo` 复扫命令（自动带上原有参数）
- 扫描维度：操作系统基线 / 包管理器与 PHP 软件包 / PHP 运行时（CLI·FPM·CGI，含 systemd `ExecStart` 里的源码编译安装）/ 历史高危 CVE（2019-11043、2024-4577）/ Web 服务与 LAMP 组件 / php.ini 与 FPM pool 暴露面 / Web 目录演示文件与源码泄露 / Docker 镜像与容器
- 版本判定对齐官方修复版本：8.2→8.2.35、8.3→8.3.36、8.4→8.4.27、8.5→8.5.12；8.1 及更早上游已停止维护，提示需确认发行版是否回补
- 缓解措施按 PHP 官方公告给出，其中 `memory_limit=-1`（应用不可覆盖）与 `session.upload_progress.enabled=0` + 重启 worker 是官方明列的两条，**不要把 `memory_limit` 调小**，有限上限反而提供了攻击者可控的 longjmp 中止路径；也不要用 `RLIMIT_AS` / `RLIMIT_DATA` 替代
- 严重度与「版本 + 暴露面」关联：`mod_php`、FPM 9000 外露等只有在确实存在未修复版本时才判高危，正常 LEMP 部署不会恒定误报
- 兼容 bash 3.x（CentOS 7 / 麒麟 V10 等），并规避了 bash 3.2 无法解析命令替换内 `case` 语句的语法限制
- 兼容麒麟 V10 / CentOS 7,8 / RHEL / SUSE 11,12 / Debian 系，无 docker / ss / systemctl 时自动降级

---

## 文件布局

```
Kylinpatch/
├── downloadKylinPatch.sh    # 主下载打包脚本
├── downloadPatchByDate.sh   # 按日期补充下载
├── mergeAndUpgrade.sh       # 合并并升级
├── upgradKylin.sh           # 升级
├── getLocalRepo.sh          # 全量下载并生成 repo
├── php2shell_scan.sh        # PHP2Shell 漏洞风险只读扫描
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
