# SwanGate

一条命令在 Linux 服务器上装好 **IPv6 IKEv2 VPN**（StrongSwan）。服务器用 Let's Encrypt 证书表明身份，客户端用本机私有 CA 签发的证书登录，不用账号密码。连上后客户端同时拿到 IPv4 和 IPv6 内网地址，全部流量走 VPN。

## 安装

两步即可，命令可原样复制粘贴：

```bash
# 1) 安装 swangate 工具
curl -fsSL https://raw.githubusercontent.com/alphajc/swangate/main/get.sh | sudo bash

# 2) 配置 VPN（终端会提示输入域名；邮箱可回车跳过）
sudo swangate install
```

第一步只下载并安装 `/usr/local/bin/swangate`。第二步在交互终端询问域名和可选邮箱，再安装 StrongSwan 与证书。之后直接用 `swangate` 管理。

非交互（脚本 / CI）仍可带参数，或把工具安装与 VPN 配置合成一行：

```bash
sudo swangate install --domain vpn.example.com --email admin@example.com
# 或
curl -fsSL https://raw.githubusercontent.com/alphajc/swangate/main/get.sh | sudo bash -s -- install --domain vpn.example.com --email admin@example.com
```

安装前确认：

- 域名的 AAAA 记录已经指向这台服务器。安装程序会用这条 AAAA 记录，或本机唯一的全局 IPv6。一台机器有多个 IPv6 时再加 `--ipv6`。
- 80/tcp 没被占用，Let's Encrypt 要用它验证域名。已有有效证书时会跳过这一步。
- 云厂商安全组放行 IPv6 的 UDP/500、UDP/4500，以及证书申请和续期用的 TCP/80；要用 Android 系统自带 VPN 时再放行 ESP（IP 协议 50）。本机防火墙由安装程序处理。规则见「云主机安全组」。
- 要用 Android 系统自带 VPN，安装时加 `--key-type rsa`，见「Android」。

## 命令

```bash
sudo swangate install
sudo swangate update
sudo swangate issue alice
sudo swangate revoke alice
sudo swangate status
```

| 子命令 | 作用 |
| --- | --- |
| `install` | 安装或重新配置服务端。重复执行是安全的：不会重建客户端 CA，也不会重复加防火墙规则 |
| `update` | 从 GitHub 拉取最新 `swangate`，按上次保存的参数重新应用服务端配置 |
| `issue <名字>` | 签发客户端证书；`--force` 先吊销旧证书再重签 |
| `revoke <名字>` | 吊销证书、发布 CRL 并重启 StrongSwan，立刻拒绝该证书 |
| `status` | 查看服务、连接、证书到期时间、数据通道、防火墙和所有客户端 |

已有服务器升级到新版本：

```bash
# 旧版本没有 update 子命令时，用 get.sh 安装新工具并立刻 update
curl -fsSL https://raw.githubusercontent.com/alphajc/swangate/main/get.sh | sudo bash -s -- update

# 同时重签所有未吊销客户端的 .mobileconfig / .p12
curl -fsSL https://raw.githubusercontent.com/alphajc/swangate/main/get.sh | sudo bash -s -- update --reissue-clients
```

`update` 默认不跑 certbot（沿用现有 Let's Encrypt 证书），也不自动重签客户端；需要新描述文件时加 `--reissue-clients`，或对单个客户端执行 `swangate issue --force <名字>`。

`swangate <子命令> --help` 列出全部参数。`install` 常用的可选参数：

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `--ipv6` | 域名 AAAA 或本机唯一全局地址 | 服务器已有的 IPv6 |
| `--interface` | 持有该 IPv6 的网卡 | NAT 出口 |
| `--ca-org` | `IKEv2` | 客户端 CA 的组织名 |
| `--ca-country` | `CN` | 客户端 CA 的国家代码 |
| `--pool-v4` | `10.10.10.0/24` | 分给客户端的 IPv4 |
| `--pool-v6` | `fd00:10:10::/64` | 分给客户端的 IPv6，不能大于 /64 |
| `--dns` | `1.1.1.1,2606:4700:4700::1111` | 推给客户端的 DNS（默认各一个 IPv4/IPv6，避免 IKE_AUTH 过大） |
| `--clients-dir` | `/root/vpn-clients` | 客户端文件目录 |
| `--backend` | `auto` | `ipsec`（ipsec.conf）或 `swanctl` |
| `--firewall` | `auto` | `firewalld`、`iptables` 或 `nftables` |
| `--dataplane` | `auto` | `kernel` 或 `libipsec` |
| `--key-type` | 现有证书的类型，没有证书时 `ecdsa` | 服务器和客户端证书的密钥类型：`ecdsa` 或 `rsa`。Android 系统自带 VPN 只支持 `rsa` |

也可以用环境变量传参，例如 `VPN_DOMAIN`、`VPN_IPV6`、`VPN_EMAIL`。

## 支持的系统

按 `/etc/os-release` 判断发行版家族，不绑定具体版本号：

| 家族 | 例子 | 包管理器 |
| --- | --- | --- |
| Debian | Debian、Ubuntu、Linux Mint、Pop!_OS | apt |
| RHEL | RHEL、CentOS、Rocky、AlmaLinux、Oracle Linux、Fedora、Amazon Linux | dnf / yum，缺包时自动启用 EPEL |
| SUSE | openSUSE Leap / Tumbleweed、SLES | zypper |
| Arch | Arch、Manjaro | pacman |
| Alpine | Alpine | apk，使用 OpenRC |

Alpine 默认没有 bash 和 curl，先执行 `apk add bash curl`。

NixOS、Gentoo、Void 以及其他系统不支持，安装程序会在改动任何配置之前退出并说明原因。

装完软件包后，安装程序按本机实际情况选择：

- **StrongSwan**：有 `strongswan-starter` 就写 `ipsec.conf`；只有 swanctl（如 Fedora、Arch）就写 `swanctl/conf.d/ikev2-vpn.conf`。两套服务都在时只启用一套。
- **防火墙**：正在运行的 firewalld 优先；否则用 iptables；再否则用 nftables。iptables 和 nftables 规则会在开机时自动恢复。
- **数据通道**：iOS 只用 AES-CBC + SHA2-256 建立数据通道。内核不支持这组算法时（会报 `Requested type not found`），自动改用 StrongSwan 的用户态 `kernel-libipsec`。子 SA 优先协商带 DH14 的 PFS，并保留不含 DH 的算法给旧客户端。`kernel-libipsec` 从 StrongSwan 5.9.11 起才能收发不封装的 ESP，更旧的版本接不了 Android 系统自带 VPN。
- **内核参数**：写入 `/etc/sysctl.d/99-ikev2-vpn.conf`，打开转发，关闭反向路径过滤和 ICMP 重定向，避免 IPsec 流量被丢掉。内核支持时启用 BBR，并加大连接跟踪表和 UDP 超时，减少 NAT-T 映射过期。思路参考 [setup-ipsec-vpn](https://github.com/hwdsl2/setup-ipsec-vpn)，不包含它的 L2TP 和 Libreswan。

## 云主机安全组

云安全组（以及部分厂商额外的网络 ACL）和本机防火墙是两层。`swangate install` 只改本机的 firewalld、iptables 或 nftables，改不到控制台里的规则。

VPN 入口是 IPv6。入站来源填 IPv6；客户端地址不固定时用 `::/0`。

| 协议 | 端口 | 方向 | 地址族 | 用途 |
| --- | --- | --- | --- | --- |
| UDP | 500 | 入站 | IPv6 | IKE 协商从这里开始 |
| UDP | 4500 | 入站 | IPv6 | 后续的 IKE 和封装在 UDP 里的 ESP（iOS、macOS、Windows） |
| ESP（IP 协议 50） | 无 | 入站 | IPv6 | Android 系统自带 VPN 的数据。它走 IPv6 时不做 NAT-T，ESP 不封装进 UDP |
| TCP | 80 | 入站 | IPv6 | Let's Encrypt 的 HTTP-01。没有有效证书时安装会用到，之后续期也会用到。已经有证书，并且安装时加了 `--skip-certbot`，这条可以不开放 |
| ICMPv6 | Packet Too Big（类型 2） | 入站 | IPv6 | 告知路径 MTU。安装程序会钳制 TCP MSS，大包仍然依赖这条 ICMP |

ESP 没有端口。控制台里选「自定义协议」或「协议号」，填 50。不用 Android 系统自带 VPN 时，这条可以不加：其他客户端的 ESP 都封装在 UDP/4500 里。

管理用的 SSH（常见是 TCP/22）按你自己的来源限制，和 VPN 无关。出站保持默认放行即可，certbot 要能访问 Let's Encrypt。

Let's Encrypt 会顺着域名的 AAAA 记录访问 80/tcp。域名如果同时有 A 记录，IPv4 的 80/tcp 也要放行。

厂商控制台里 IPv4 和 IPv6 经常是两组规则。只给 `0.0.0.0/0` 打开 UDP/500 和 UDP/4500 时，IPv6 客户端仍然连不上。有网络 ACL 时，安全组和 ACL 都要放行上表里的端口。

- **阿里云 ECS**：在这台实例的安全组里添加 IPv6 入站规则，授权对象填 `::/0`。
- **腾讯云 CVM**：安全组入站选择 IPv6，来源填 `::/0`。
- **华为云 ECS**：安全组按 IPv6 单独授权，来源填 `::/0`。
- **AWS**：安全组入站来源填 `::/0`。
- **GCP**：VPC 防火墙规则的来源 IP 范围填 IPv6，例如 `::/0`。

连不上时，先在控制台确认规则挂在这台实例上，并且地址族是 IPv6。然后在服务器上执行 `sudo swangate status`，看 `Firewall` 是 firewalld、iptables 还是 nftables。安装程序会在这一层放行 UDP/500、UDP/4500 和 ESP。

## 客户端

`sudo swangate issue alice` 把文件写到 `/root/vpn-clients/alice/`：

- `alice.mobileconfig`：iOS / macOS 描述文件，已用服务器证书签名，包含客户端证书
- `alice.p12`：Windows、Android 用；随机口令打印在终端，也写在 `connection.txt`
- `server-ca.crt`：只在 `--key-type rsa` 时生成，Android 用它校验服务器
- `alice.crt`、`alice.key`、`ca.crt`

导入方法：

- **iPhone / Mac**：用隔空投送或 Safari 打开 `.mobileconfig`，在设置里安装。
- **Windows**：把 `.p12` 导入到“本地计算机”证书存储，新建 IKEv2 VPN，服务器填域名，认证方式选证书。
- **Android**：用系统自带 VPN，见下一节。

### Android

用系统自带的「IKEv2/IPSec RSA」，不用装 App。需要 Android 11 或更新版本；到 Android 16 字段都没变。下面的菜单名按原版 Android 写，各家手机略有不同，找不到时在设置里搜索「安装证书」或「VPN」。

先确认服务器满足三点：

- 安装时用了 `--key-type rsa`。系统 VPN 只会用 RSA 签名，也只认 RSA 签名的服务器，默认的 ECDSA 证书连不上。已经用 ECDSA 装好的服务器，执行 `sudo swangate install --key-type rsa` 换成 RSA 证书（certbot 会重新申请，需要 80/tcp），再执行 `sudo swangate update --skip-self --reissue-clients` 重签所有客户端。iPhone 和 Mac 要重新安装新的 `.mobileconfig`。
- 云安全组放行了 IPv6 的 ESP（IP 协议 50）。系统 VPN 走 IPv6 时不把 ESP 封装进 UDP。
- 数据通道是 `kernel`，或者是 StrongSwan 5.9.11 及以上的 `libipsec`（`sudo swangate status` 里的 `Dataplane`）。

把 `alice.p12` 和 `server-ca.crt` 拷到手机上。口令在 `connection.txt` 的 `PKCS#12 password` 一行，只在导入证书时用；VPN 本身没有账号密码。

导入两张证书（设置 → 安全和隐私 → 更多安全和隐私设置 → 加密与凭据 → 安装证书）：

1. 选「VPN 和应用用户证书」，打开 `alice.p12`，输入口令。
2. 选「CA 证书」，打开 `server-ca.crt`。系统会提醒网络可能受到监控，这是安装任何自定义 CA 时的固定提示。

`server-ca.crt` 是 Let's Encrypt 中间证书上一级的 CA，现在一般是 `Root YR`，由 ISRG Root X1 交叉签名。服务器每次握手都会附上签发它的中间证书（YR1、YR2 这类会轮换），手机只需要信任上一级，续期后不用重装。`ca.crt` 是签发客户端证书的 CA，不用装到手机上。

新建 VPN（设置 → 网络和互联网 → VPN → 右上角「+」）：

| 字段 | 填写 |
| --- | --- |
| 名称 | 随意 |
| 类型 | `IKEv2/IPSec RSA` |
| 服务器地址 | 域名，即 `connection.txt` 的 `Server`。不要填 IPv6 地址，证书里只有域名 |
| IPSec 标识符 | 客户端名字，即 `connection.txt` 的 `Local ID`，例如 `alice` |
| IPSec 用户证书 | 第 1 步导入的证书 |
| IPSec CA 证书 | 第 2 步导入的 CA（`connection.txt` 里写了它的名字）。不要选「不验证服务器」 |
| IPSec 服务器证书 | 从服务器接收 |

保存后点开连接。连上后 IPv4 和 IPv6 流量都走 VPN。手机所在网络必须有 IPv6，服务器只发布了 AAAA 记录。

想开机自动连接，在 VPN 列表里点这条配置旁的齿轮，打开「始终开启的 VPN」。

## 吊销

```bash
sudo swangate revoke alice
```

证书写入 CRL，StrongSwan 重启后立即拒绝它。iOS 描述文件不检查吊销状态，由服务端负责拒绝。

## 从源码运行

```bash
git clone https://github.com/alphajc/swangate.git
cd swangate
sudo ./swangate install
```

离线测试：`bash tests/check-render.sh`。

## 安全说明

- 仓库里没有任何真实域名、地址、私钥或口令。客户端 CA 在安装时生成，存放在 `/etc/ikev2-vpn/ca/`，权限 `700`；每个 `.p12` 的口令单独随机生成。
- `.p12` 和 `.mobileconfig` 含客户端私钥，请用 `scp` 或隔空投送传输，不要放到公网 HTTP 上。
- 客户端证书可以转发全部 IPv4 / IPv6 流量。设备丢失时立刻 `swangate revoke`。
- 安装工具时会以 root 运行从 GitHub 下载的脚本。介意的话先下载 `get.sh` 看过再执行，或者用上面的“从源码运行”。
