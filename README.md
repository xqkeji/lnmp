# LNMP 一键安装

Linux 下一键自动安装 nginx（含 ACME 自动 HTTPS 模块）、MongoDB、PHP-FPM、Composer、PIE、
PHP 扩展（zip / mongodb）、xqkeji（新齐低代码开发框架扩展）与 ocserv（SSL VPN），并接管服务启停。

支持系统（自动探测，按包管理器分家族，见 `lib/os.sh`）：

| 家族 | 系统 | 包管理器 | nginx / PHP | MongoDB |
|---|---|---|---|---|
| debian | Debian 11/12/13、Ubuntu 20.04/22.04/24.04 及衍生版 | apt | 源码编译（可选 apt 路线） | 官方 tarball（debianXX/ubuntuXX） |
| rhel | RHEL/Rocky/AlmaLinux/CentOS 8/9、Fedora、openEuler 22.03/24.03 | dnf/yum | 源码编译（固定） | 官方 tarball（rhelXX，自动回退） |

- RHEL 家族自动启用 EPEL / CRB 仓库（openEuler 无 EPEL 时仅告警不中断）。
- openEuler 无官方 MongoDB 构建，脚本先试 rhel8、失败自动回退 rhel93（实测可用）。
- 容器等无 systemd 环境同样支持：服务启停自动切换为二进制直启路径。

## 快速开始

```bash
# 1. 按需修改 config.ini（版本号、acme 域名、MongoDB 账号等）
# 2. 全量安装（幂等，可重复执行，已装组件自动跳过）
sudo ./install.sh

# 只体检不安装
sudo ./install.sh --check
```

## 组件与安装路径

| 组件 | 路径 | 端口 | 方式 |
|---|---|---|---|
| nginx | /usr/local/nginx | 80 | 源码编译 + ngx_http_acme_module（动态模块） |
| MongoDB | /usr/local/mongodb | 27017 | 官方预编译 tarball + mongosh 单独下载 |
| PHP-FPM | /usr/local/php | 9000 | 源码编译（gd 编译期启用；opcache PHP 8.5 起内置） |
| Composer / PIE | /usr/local/composer、/usr/local/pie | - | phar |
| PHP 扩展 | - | - | PIE 装 zip、mongodb；xqkeji 为预编译 .so 直接部署 |
| ocserv | /usr/local/sbin | 4443(tcp/udp) | 官网（infradead）源码编译，meson 构建 |

ocserv 是 Cisco AnyConnect 兼容的 SSL VPN：客户端地址段 `10.10.10.0/24`，下发 DNS
`119.29.29.29` / `223.5.5.5`（均可在 config.ini 改）；安装时交互式创建首个账号，
自签服务端证书（certtool 生成），自动开 IPv4 转发。客户端连接地址为
`https://<服务器IP>:4443/`（AnyConnect / OpenConnect）。

## 防火墙收紧（ocserv 装完自动应用）

ocserv 就绪后 `scripts/78-firewall.sh` 自动收紧主机防火墙（firewalld / iptables
双路径自动识别，规则尽力持久化，重启仍生效）：

- 对外只放行 **80 / 443 / 4443**（tcp，VPN 端口含 udp），其余端口（含 MongoDB
  27017、PHP-FPM 9000）一律拒绝。
- **22/SSH 不再接受外部直连**：只放行本机回环与 VPN 段 `10.10.10.0/24`——外部
  工具必须先连上 ocserv 才能 SSH 服务器。已建立的 SSH 会话不受影响。
- 安全闸：ocserv 未安装或未运行时，本次不收紧 22（防止远程失联），其余策略照旧。
- VPN 客户端出网的 MASQUERADE 自动配置（firewalld 或 iptables nat）。
- 两个后端都拿不到时（精简系统里 iptables 装不上）**只告警不中止**：会打印装包
  命令和该手工放行的端口，让安装把 systemd 单元、启动与自检跑完；自检报告此时会
  明确写"防火墙 未收紧"，不会假装一切正常。

```bash
sudo ./scripts/78-firewall.sh        # 手动（重新）应用收紧策略
sudo ./scripts/78-firewall.sh undo   # 应急还原：恢复 SSH 对外访问
```

安装状态记录在 `/usr/local/lnmp/state/`，完整日志在 `/var/log/lnmp-install.log`，
源码包缓存在 `/usr/local/src/lnmp/`。缓存的包会先过一遍校验才复用：pin 了
sha256 按 sha256，没 pin 则按归档完整性（gzip/xz 全量解一遍），所以断流留下的
残包会被丢弃重下，不会拖到 tar 解压时才失败；下载先进同目录的 `<包名>.part`，
同一个 URL 中断后续传，换源时该半成品作废。解压出来的源码目录（nginx-acme、
php-xqkeji）也类似：只有成功取全过一次才留下 `.lnmp-ok` 标记，重跑时凭标记跳过
下载——半截解压留下的目录没有标记，会被重新取，不会拿截断的 `.so`/`Cargo.toml`
去编译加载。

## 服务管理（systemd 与容器通用）

```bash
sudo ./ctrl.sh status              # 查看全部
sudo ./ctrl.sh restart             # 全部重启
sudo ./ctrl.sh stop nginx mongodb  # 只停指定服务（nginx / php-fpm / mongodb / ocserv）
```

mongodb 的 start/restart 走安全启动：自动清理孤儿进程、修正数据目录属主、清陈旧锁，
必要时 `--repair` 兜底。

nginx / php-fpm / mongod / ocserv 安装完成后都会 `systemctl enable` 设置开机自启
（只 enable 实际装了的服务，`99-verify` 会逐项报告状态）；无 systemd 的容器环境改用
`ctrl.sh` 手动管理。

## 选装与单步执行

```bash
sudo ./install.sh --list                 # 列出可单独安装的组件
sudo ./install.sh nginx php              # 只装指定组件（自动补对应系统依赖）
sudo ./install.sh --download-only        # 先把源码包下齐（校验 sha256），之后离线再装
sudo ./scripts/30-php.sh                 # 每个 scripts/*.sh 都可绕开主入口单独执行
sudo ./scripts/00-deps.sh php            # 只装 PHP 的编译依赖
```

## 配置（config.ini）

所有版本号与开关集中在 `config.ini`，改完直接重跑 `install.sh` 即可，要点：

- `nginx_install`：`src`（默认，全系统通用）/ `apt`（nginx.org 官方 deb 包 + 预编译
  acme 模块，**仅 Debian/Ubuntu**，RHEL 家族填 apt 会在预检报错中止）。
  两条路线互斥，切换时自动清理已装的另一路线。
- `nginx_acme` / `acme_domains`：ACME 自动 HTTPS（仅 HTTP-01），域名空格分隔；
  src 路线编译 acme 模块需 Rust ≥1.81，脚本自动经 rsproxy.cn 安装。
- `upload_dirs`：站点里"只放文件、不该执行代码"的目录名（空格分隔，只要目录名不要
  路径），默认含 `uploads upload assets data tmp files attachments`——`assets` 是对外
  发布的静态资源、`upload` 是用户可写目录，两类都不该有代码被执行。据此生成
  `snippets/lnmp-upload-guard.conf`：任意层级的同名目录下
  `.php/.phtml/.phar/.cgi/.pl/.py/.sh` 一律 404，上传的 webshell 落地也执行不了；
  PHP 转发段同时带 `try_files $uri =404`，堵住 `/uploads/shell.jpg/x.php` 这类
  path info。新建站点自带这两段 include；已存在的站点由 `80-nginx-conf.sh` 按
  server 块自动补 guard include（原文件留 `.bak-lnmp` 备份，注入前后各跑一次
  `nginx -t`，通不过就回滚）。改了本项重跑 `sudo ./scripts/80-nginx-conf.sh` 覆盖
  片段文件，再 `sudo ./ctrl.sh restart nginx` 生效——站点里的 include 路径不变，
  不用逐个站点改配置。
- `mongodb_distro=auto`：按系统自动挑官方构建名，首选不可用自动回退重试；
  跨构建回退时 `mongodb_sha256` 不要 pin 死。
- `mongodb_root_user/pass`：安装后初始化的管理员账号，留空则跳过（裸跑无认证）。
- `php` 与 `xqkeji` 必须配对（当前 8.5.12 + v1.1.6-php8.5），否则 .so 加载失败。
  xqkeji 以 gitcode 归档为首选源，但 gitcode 的反爬按出口 IP 判，云主机即使带浏览
  器 UA 也会 418；此时脚本改用 gitcode 的 `git clone`（不经那条 WAF，排在 GitHub
  代理之前），仍失败才依次回退 GitHub 代理/直连，最后可填 `xqkeji_url` 指定镜像，
  或手动把包放到 `/usr/local/src/lnmp/`。
- `pie_extensions`：用 packagist 包名（`pecl/zip`、`mongodb/mongodb-extension`），
  gd 是核心 bundled 扩展 PIE 装不了，已由 PHP 编译期 `--enable-gd` 打开。
- `ocserv_port` / `ocserv_network` / `ocserv_netmask` / `ocserv_dns`：VPN 监听端口、
  客户端地址段与下发 DNS；`ocserv_user/pass` 留空则安装时交互式建号（非交互环境留空
  即跳过，之后用 `ocpasswd -c /etc/ocserv/ocpasswd <用户名>` 添加）。
  `/etc/ocserv/ocpasswd` 里**已有账号就不再建号**：升级/重跑不会重复追问，也不会用
  config.ini 里的密码顶掉你手工改过的密码；只有点名一个文件里没有的用户名才当新增。
  官网只提供 ftp:// 下载，国内不通时可填 `ocserv_url` 镜像整段 URL。

## 代码结构

```
install.sh          主入口（只编排，活都在 scripts/ 下）
config.ini          所有版本号与开关
ctrl.sh             服务管理 start/stop/restart/status
lib/common.sh       常量、日志、下载、幂等状态
lib/os.sh           系统抽象层入口（按家族 source lib/os/*.sh）
lib/os/common.sh      发行版探测 + 契约分发 + 幂等安装包装（不含包名）
lib/os/debian.sh      apt 家族：包管理实现 + 依赖组包名表
lib/os/rhel.sh        dnf/yum 家族：包管理实现 + EPEL/CRB + 依赖组包名表
lib/config.sh       读 config.ini（键名白名单，不 eval）
lib/preflight.sh    环境预检（root、系统家族、架构、端口、磁盘）
lib/service.sh      服务启停（systemd / 无 systemd 双路径）
scripts/00-deps.sh  依赖分组入口（装哪一组、为什么装；包名表在 lib/os/ 下）
scripts/10-nginx.sh       nginx（src / apt 双路线）
scripts/20-mongodb.sh     MongoDB + mongosh + 账号初始化
scripts/30-php.sh         PHP 编译
scripts/40~60-*.sh        Composer / PIE / PHP 扩展
scripts/70-xqkeji.sh      xqkeji 扩展
scripts/75-ocserv.sh      ocserv SSL VPN（源码编译 + 配置 + 账号 + 证书）
scripts/78-firewall.sh    防火墙收紧（仅放行 80/443/VPN 端口，SSH 限本机+VPN 段；含 undo）
scripts/80-nginx-conf.sh  nginx 配置骨架 + snippets 公共片段 + 默认站点（含上传目录禁执行注入）
scripts/90-systemd.sh     systemd 单元 + 开机自启（SELinux/防火墙检测告警）
scripts/99-verify.sh      安装结果自检
```

## 设计约定

1. **幂等**：已装版本记在 `state/<名>.version`，重复执行自动跳过。
2. **不 eval 配置**：ini 键名走白名单，值只做赋值。
3. **sha256 有则校验**，留空跳过；下载支持多镜像/多构建候选自动回退。
4. **国内源优先**：gitcode/gitee 镜像、TUNA nginx apt 仓库、rsproxy Rust 工具链，均可在
   config.ini 换回官方源。
