# php2shell_scan.sh v3.1.0 修复与终验报告

- 目标仓库：<https://github.com/ishadowland/Kylinpatch>
- 被测脚本：`php2shell_scan.sh` v3.0.0 → v3.1.0
- 关联 issue：#3、#4、#5、#6、#7、#8、#9、#10、#11、#12
- 终验主机：10.10.66.38
- 终验时间：2026-10-24

---

## 1. 终验环境

| 项 | 值 |
|---|---|
| 操作系统 | Kylin Linux Advanced Server V10 (Lance)，`4.19.90-52.22.v2207.ky10.x86_64` |
| Bash | 5.0.18(1)-release（脚本同时兼容 bash 3.x 语法约束） |
| 宿主机 PHP | 8.0.30-15.p04.ky10（ks10-adv-updates），php-cli / php-cgi / php-fpm 已安装并运行 |
| 容器运行时 | Docker 18.09.0（overlay2）、podman 0.10.1 |
| 测试容器 | `wp-app` = wordpress:latest（PHP 8.3.36，8080）<br>`wp-app-vuln` = wordpress:6.4-php8.2-apache（PHP 8.2.17，8081）<br>`wp-old` = wordpress:4.9.8-php5.6-apache（PHP 5.6.38，8082）<br>`wp-db` = mariadb:10.6 |
| 镜像获取 | 宿主直连 registry-1.docker.io 超时，经 `docker.m.daocloud.io` 代理拉取 |
| 执行身份 | root（另有一组非 root 回归） |

---

## 2. 逐条修复与验证结论

| issue | 问题 | 修复方式 | 终验结果 |
|---|---|---|---|
| #3 | `session.upload_progress.enabled` 缺失/被注释时静默，官方缓解措施实际未落实却不告警 | 新增 `ini_bool()` 归一化 On/Off/1/0；`upload_progress` 三态判定（1→MED、0→OK、缺失→按默认 1/On 判 MED）；`display_errors` / `expose_php` / `opcache.enable` 一并改用归一化判定 | ✅ 麒麟 V10 默认 php.ini（`;session.upload_progress.enabled = On`）下输出 `[MED] 未显式设置 session.upload_progress.enabled（PHP 默认值为 1/On），官方缓解措施未落实` |
| #4 | FPM 9000 暴露被第 5 节（端口）与第 6 节（pool 配置）各报一次，HIGH 统计虚高 | 第 5 节端口观测降为 INFO 提示并置 `FPM_PORT_9000`；风险条目统一由第 6 节 pool `listen` 判定给出；仅当 9000 在监听但找不到对应 pool 配置时，第 6 节兜底告警 | ✅ 暴露场景下高危条目只剩 1 条 `[CFG] /etc/php-fpm.d/exposed.conf: FPM 监听 9000`；第 5 节仅 INFO 提示 |
| #5 | `/var/www` 与 `/var/www/html` 嵌套根目录导致同一批文件被扫两遍、风险重复计数 | 新增 `remove_nested_roots()`，收集根目录时剔除被其它根目录包含的子目录 | ✅ 待扫描根目录由 `/usr/share/nginx/html/ /var/www/ /var/www/html/` 变为 `/usr/share/nginx/html/ /var/www/`，演示/备份文件各只报 1 条 |
| #6 | `detect_cms()` 仅凭文件存在判定，空文件 / 空目录被误判为 WordPress 等应用 | 所有指纹判定加"文件非空 / 目录非空"校验（`[ -s ]`、`ls -A`） | ✅ 空 `wp-config.php` + 空 `wp-content/` 下不再输出任何应用指纹；真实 WordPress 源码目录仍正确识别为 `WordPress` |
| #7 | 镜像 tag 版本解析把应用版本当 PHP 版本（`wordpress:6.4-php8.2-apache` → "6.4" → 误判 CRIT；`4.9.8-php5.6` → 漏报） | `extract_image_version()` 优先提取 `php` 关键字后的版本号（`php8.2` / `php-8.2` / `php8.2.17`），无 `php` 关键字才回退整串匹配 | ✅ `6.4-php8.2-apache` → 8.2、`4.9.8-php5.6-apache` → 5.6、`php:8.3-fpm` → 8.3；"6.4 分支无官方修复版本"的 CRIT 误报消失 |
| #8 | 镜像 / 容器按"名称含 php"过滤，WordPress 等非 php 命名的 PHP 容器整体漏检 | 容器实例不再按名称过滤；新增"运行中容器内 `php -v`"只读探测（带 5s 超时，仅匹配 `^PHP` 输出）；深度模式本就探测全部镜像 | ✅ 默认模式下即识别出：wp-old → PHP 5.6.38（CRIT）、wp-app-vuln → PHP 8.2.17（HIGH）、wp-app → PHP 8.3.36（OK）；mariadb 等无 PHP 的容器不再产生噪声 |
| #9 | 演示 / 测试文件名黑名单与 WordPress、PHP 生态冲突，核心文件被误判 HIGH | 新增 `classify_demo_file()` 二次判定：核心 / 依赖目录（wp-includes、vendor、node_modules 等）直接视为应用自带；排除注释行后检查 `phpinfo/eval/system/shell_exec/...` 调用；带 `Plugin Name:` / `@package` 声明头视为应用自带 | ✅ `hello.php`（Hello Dolly）与 `wp-includes/Text/Diff/Engine/shell.php` 变为 INFO「属应用自带文件…已忽略」；真实 `phpinfo.php`（含 `phpinfo()` 调用）仍报 HIGH；普通 `test.php` 降为 MED 待人工确认 |
| #10 | 仅命中中危项时结论仍输出"安全 / 不存在攻击面"，与「[必做]」修复建议自相矛盾 | 结论增加"待确认"档（CRIT/HIGH → 存在风险；仅 MED → 待确认；无 → 安全），并同步改写判定依据与最终结论行 | ✅ 仅中危场景输出「总体判定：待确认 …… 存在 8 项中危风险待人工复核……本机仍可能构成 PHP2Shell 攻击面」，退出码 0 |
| #11 | `--deep` 在 podman 0.10.1 下残留孤儿容器（`--rm` 在 entrypoint 缺失时不回收） | 深度探测改为显式 `create` → `start -a` → `rm -f`，不依赖 `--rm`；只删除自己创建的容器 ID，不触碰业务容器 | ✅ 修复前 podman 残留 4 个 `Created` 容器，修复后 `podman ps -aq` = 0；docker 侧 `docker ps -aq --filter status=created` = 0 |
| #12 | `phpize` / `php-config` / `phpdbg` / `phar` 等辅助工具被当作 PHP 运行时 | 新增 `is_php_helper_tool()`，在路径扫描时排除上述辅助工具；失败提示语同时修正 | ✅ 第 3 节运行时清单只剩 `php` / `php-cgi` / `php-fpm`，不再出现 `/usr/bin/phpize -> Can't find PHP headers` |
| 附加 | CVE-2024-4577 判定未覆盖 8.0 分支 | 补充 8.0 分支（修复版本 8.0.30） | ✅ 已并入 v3.1.0 |

---

## 3. 终验场景与输出

### 3.1 场景 A：默认模式（含容器）

```
A_default EXIT=1
  总体判定：存在风险
  判定依据：存在 3 项严重、1 项高危风险，需立即处置（详见下方清单）。
  风险统计  严重(Critical): 3  高危(High): 1  中危(Medium): 8  低危(Low): 1  提示(Info): 58
[结论] 存在风险：本机存在 3 项严重、1 项高危风险，请按上方清单与修复建议处置。

[INFO] DOCKER:   容器 wp-old 内 PHP: PHP 5.6.38 (cli) (built: Nov 28 2018 23:25:01)
[CRIT] DOCKER: 容器 wp-old 内 PHP 版本 5.6.38 所属分支（5.6）上游已停止维护且无修复版本，长期暴露
[INFO] DOCKER:   容器 wp-app-vuln 内 PHP: PHP 8.2.17 (cli) (built: Mar 16 2024 01:08:19) (NTS)
[HIGH] DOCKER: 容器 wp-app-vuln 内 PHP 版本 8.2.17 低于该分支修复版本，受 CVE-2026-109618/109619 影响
[INFO] DOCKER:   容器 wp-app 内 PHP: PHP 8.3.36 (cli) (built: Oct 21 2026 15:57:18) (NTS)
[OK] DOCKER: 容器 wp-app 内 PHP 版本 8.3.36 不低于该分支修复版本
```

对照修复前：默认模式下 PHP 5.6 容器 **0 条风险条目**；修复后 3 项 CRIT + 1 项 HIGH 全部来自真实容器内 PHP 版本。

### 3.2 场景 B：深度模式 `--deep`

```
B_deep EXIT=1
[INFO] DOCKER:   镜像 wordpress:4.9.8-php5.6-apache 内 PHP: PHP 5.6.38 ...
[CRIT] DOCKER: 镜像 wordpress:4.9.8-php5.6-apache 内 PHP 版本 5.6.38 所属分支（5.6）上游已停止维护且无修复版本
[INFO] DOCKER:   镜像 wordpress:6.4-php8.2-apache 内 PHP: PHP 8.2.17 ...
[HIGH] DOCKER: 镜像 wordpress:6.4-php8.2-apache 内 PHP 版本 8.2.17 低于该分支修复版本
[INFO] DOCKER:   镜像 wordpress:latest 内 PHP: PHP 8.3.36 ...
[OK]   DOCKER: 镜像 wordpress:latest 内 PHP 版本 8.3.36 不低于该分支修复版本
[INFO] DOCKER: 深度模式共探测 8 个镜像
--- 残留容器检查 ---
docker 残留: 0 个
podman 残留: 0 个
```

### 3.3 场景 C：风险场景（FPM 9000 暴露 + 演示文件 + 备份文件 + 空 wp-config）

```
[INFO] WEB: 9000 端口处于监听状态……（实际风险条目见第 6 节 php-fpm pool listen 判定）
[HIGH] CFG: /etc/php-fpm.d/exposed.conf: FPM 监听 9000（未限定回环地址/未使用 socket），外部可直接发起 FastCGI 协议攻击
[OK]   CFG: /etc/php-fpm.d/www.conf: FPM 监听 /run/php-fpm/www.sock（仅本机可达）
[INFO] APP: 待扫描根目录: /usr/share/nginx/html/ /var/www/
[HIGH] APP: /var/www 存在演示/测试 PHP 文件且含 phpinfo()/命令执行等可疑调用：/var/www/html/phpinfo.php
[MED ] APP: /var/www 存在命中演示/测试文件名黑名单的文件（未发现明显可疑调用，请人工确认）：/var/www/html/test.php
[MED ] APP: /var/www 存在备份 / 源码泄露文件：/var/www/html/test.php.bak

风险统计  严重(Critical): 0  高危(High): 2  中危(Medium): 11  低危(Low): 1  提示(Info): 45
```

高危条目仅 2 条：FPM 暴露 1 条 + 真实 `phpinfo()` 文件 1 条，**无重复计数**。

### 3.4 场景 D：仅中危场景（清理高危源后）

```
D_medium EXIT=0
  总体判定：待确认
  判定依据：未发现严重(Critical)与高危(High)级风险，但存在 8 项中危风险待人工复核（详见下方清单），本机仍可能构成 PHP2Shell 攻击面。
  风险统计  严重(Critical): 0  高危(High): 0  中危(Medium): 8  低危(Low): 1  提示(Info): 41
[结论] 待确认：未发现严重/高危风险，但存在 8 项中危风险需人工复核确认，请参考上方清单与修复建议。
```

### 3.5 场景 E：WordPress 源码目录（误报回归）

```
[INFO] APP: /var/lib/docker/volumes/wordpress_wp_html/_data: PHP 文件 1416 个
[INFO] APP: /var/lib/docker/volumes/wordpress_wp_html/_data 有 2 个文件命中演示/测试文件名黑名单，但属应用自带文件（核心/依赖/插件主文件），已忽略：
        .../wp-content/plugins/hello.php  .../wp-includes/Text/Diff/Engine/shell.php
[INFO] APP: /var/lib/docker/volumes/wordpress_wp_html/_data 应用指纹: WordPress
风险统计  严重(Critical): 0  高危(High): 0  中危(Medium): 8  低危(Low): 1  提示(Info): 44
```

### 3.6 场景 F / G：健壮性与参数

| 用例 | 退出码 | 说明 |
|---|---|---|
| `--help` | 0 | 帮助正常输出 |
| 非法参数 `--bogus` | 2 | 参数校验 |
| `--log` 指向不可写路径 | 2 | 报告文件写入失败即退出并报错 |
| 非 root 执行 | 0 | 输出 `[MED] PERM 当前非 root 运行……建议以 root 复扫`、`[MED] DOCKER 无法连接守护进程`，判定"待确认" |
| `--skip-docker` / `--skip-web` / `--max-depth` / `--web-root` | — | 全部生效 |
| 报告文件 | — | 默认 `/var/log/php2shell_scan_<时间戳>.log`，纯文本无 ANSI 转义，可直接 grep |

---

## 4. 修复前后对比

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 旧版 WordPress（PHP 5.6.38）容器，默认模式 | 0 条风险条目 | CRIT × 1（EOL 分支无修复版本） |
| WordPress 6.4（PHP 8.2.17）镜像 tag 判定 | CRIT「版本 6.4 分支无官方修复版本」（误报） | 8.2 需 --deep 确认；容器内实测 HIGH（正确） |
| WordPress 源码 `hello.php` / `shell.php` | HIGH × 2（误报） | INFO「属应用自带文件，已忽略」 |
| FPM 9000 暴露 | HIGH × 2（重复） | HIGH × 1 |
| `/var/www` + `/var/www/html` | 演示/备份文件各报 2 次 | 各报 1 次 |
| 空 `wp-config.php` | 判定为 WordPress | 无指纹输出 |
| `session.upload_progress.enabled` 未设置 | 无任何提示 | MED 提示 |
| 仅中危项时结论 | 「安全 / 不存在攻击面」 | 「待确认 / 仍可能构成攻击面」 |
| `--deep`（podman 0.10.1） | 残留 4 个孤儿容器 | 残留 0 个 |
| 第 3 节运行时清单 | 含 `phpize -> Can't find PHP headers` | 仅 php / php-cgi / php-fpm |

---

## 5. 已知限制

1. 容器内 PHP 版本探测依赖 `docker/podman exec <容器> php -v`，对未运行容器、Minimal 镜像（无 php 二进制）或无权限场景无效；此类场景仍需 `--deep`（镜像级探测）。
2. `--deep` 会在镜像内启动一次性容器读取版本号，属脚本唯一的有副作用动作（本版本已确保容器被显式删除）。
3. 宿主机的 `php.ini` 判定不覆盖容器内生效的 PHP 配置（容器内 `memory_limit`、`session.upload_progress.enabled` 仍需人工核查）。
4. 演示 / 测试文件判定为"启发式 + 内容特征"，对刻意改名的恶意文件无能为力，最终仍需人工复核中危项。

---

## 6. 复现方式

```bash
# 1. 取脚本
curl -sSLO https://raw.githubusercontent.com/ishadowland/Kylinpatch/main/php2shell_scan.sh

# 2. 常规扫描
bash php2shell_scan.sh --no-color --log /tmp/scan.log

# 3. 含容器内 PHP 版本探测 + 镜像深度探测
bash php2shell_scan.sh --no-color --deep --log /tmp/scan-deep.log

# 4. 扫描容器卷内的应用源码
bash php2shell_scan.sh --no-color \
  --web-root /var/lib/docker/volumes/<project>_wp_html/_data \
  --log /tmp/scan-wp.log
```

退出码：`0` = 无 CRIT/HIGH（存在中危项时判定为"待确认"）、`1` = 存在 CRIT/HIGH、`2` = 执行错误。
