# SwanGate

一条命令在 Linux 服务器上装好 **IPv6 IKEv2 VPN**（StrongSwan）。服务器用 Let's Encrypt 证书表明身份，客户端用本机私有 CA 签发的证书登录，不用账号密码。连上后客户端同时拿到 IPv4 和 IPv6 内网地址，全部流量走 VPN。

## 一键安装

在服务器上以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/alphajc/swangate/main/get.sh | sudo bash -s -- install --domain vpn.example.com --email admin@example.com
```

把域名和邮箱换成你自己的。这条命令会下载 `swangate`，装到 `/usr/local/bin/swangate`，再执行安装。之后直接用 `swangate` 管理。

安装前确认：

- 域名的 AAAA 记录已经指向这台服务器。安装程序会用这条 AAAA 记录，或本机唯一的全局 IPv6。一台机器有多个 IPv6 时再加 `--ipv6`。
- 80/tcp 没被占用，Let's Encrypt 要用它验证域名。已有有效证书时会跳过这一步。
- 云厂商的安全组放行 udp/500 和 udp/4500。本机防火墙由安装程序处理。

## 命令

```bash
sudo swangate install --domain vpn.example.com --email admin@example.com
sudo swangate issue alice
sudo swangate revoke alice
sudo swangate status
```

| 子命令 | 作用 |
| --- | --- |
| `install` | 安装或更新服务端。重复执行是安全的：不会重建客户端 CA，也不会重复加防火墙规则 |
| `issue <名字>` | 签发客户端证书；`--force` 先吊销旧证书再重签 |
| `revoke <名字>` | 吊销证书、发布 CRL 并重启 StrongSwan，立刻拒绝该证书 |
| `status` | 查看服务、连接、证书到期时间、数据通道、防火墙和所有客户端 |

`swangate <子命令> --help` 列出全部参数。`install` 常用的可选参数：

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `--ipv6` | 域名 AAAA 或本机唯一全局地址 | 服务器已有的 IPv6 |
| `--interface` | 持有该 IPv6 的网卡 | NAT 出口 |
| `--ca-org` | `IKEv2` | 客户端 CA 的组织名 |
| `--ca-country` | `CN` | 客户端 CA 的国家代码 |
| `--pool-v4` | `10.10.10.0/24` | 分给客户端的 IPv4 |
| `--pool-v6` | `fd00:10:10::/64` | 分给客户端的 IPv6，不能大于 /64 |
| `--dns` | `1.1.1.1,8.8.8.8,2606:4700:4700::1111` | 推给客户端的 DNS |
| `--clients-dir` | `/root/vpn-clients` | 客户端文件目录 |
| `--backend` | `auto` | `ipsec`（ipsec.conf）或 `swanctl` |
| `--firewall` | `auto` | `firewalld`、`iptables` 或 `nftables` |
| `--dataplane` | `auto` | `kernel` 或 `libipsec` |

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
- **数据通道**：iOS 只用 AES-CBC + SHA2-256 建立数据通道。内核不支持这组算法时（会报 `Requested type not found`），自动改用 StrongSwan 的用户态 `kernel-libipsec`。

## 客户端

`sudo swangate issue alice` 把文件写到 `/root/vpn-clients/alice/`：

- `alice.mobileconfig`：iOS / macOS 描述文件，已用服务器证书签名，包含客户端证书
- `alice.p12`：Windows、Android 用；随机口令打印在终端，也写在 `connection.txt`
- `alice.crt`、`alice.key`、`ca.crt`

导入方法：

- **iPhone / Mac**：用隔空投送或 Safari 打开 `.mobileconfig`，在设置里安装。
- **Windows**：把 `.p12` 导入到“本地计算机”证书存储，新建 IKEv2 VPN，服务器填域名，认证方式选证书。
- **Android**：安装 strongSwan 客户端，类型选 IKEv2 证书，选择 `.p12`；提示时导入 `ca.crt`。

## 吊销

```bash
sudo swangate revoke alice
```

证书写入 CRL，StrongSwan 重启后立即拒绝它。iOS 描述文件不检查吊销状态，由服务端负责拒绝。

## 从源码运行

```bash
git clone https://github.com/alphajc/swangate.git
cd swangate
sudo ./swangate install --domain vpn.example.com
```

离线测试：`bash tests/check-render.sh`。

## 安全说明

- 仓库里没有任何真实域名、地址、私钥或口令。客户端 CA 在安装时生成，存放在 `/etc/ikev2-vpn/ca/`，权限 `700`；每个 `.p12` 的口令单独随机生成。
- `.p12` 和 `.mobileconfig` 含客户端私钥，请用 `scp` 或隔空投送传输，不要放到公网 HTTP 上。
- 客户端证书可以转发全部 IPv4 / IPv6 流量。设备丢失时立刻 `swangate revoke`。
- 一键安装会以 root 运行从 GitHub 下载的脚本。介意的话先下载 `get.sh` 看过再执行，或者用上面的“从源码运行”。
