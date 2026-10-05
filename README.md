# IPv6 IKEv2 VPN

在 Ubuntu 上用一条命令安装 **StrongSwan IKEv2**。服务器用 Let's Encrypt 证书表明身份，客户端用本机私有 CA 签发的证书登录（公钥认证）。连上之后会同时拿到 IPv4 和 IPv6 内网地址，并把全部流量转发出去。

适用系统：**Ubuntu 22.04** 和 **Ubuntu 24.04**。

## 安装前

- 域名已经解析到这台服务器（Let's Encrypt 要能访问 80/tcp）。
- `--ipv6` 填这台机器上已经配好的 IPv6 地址。安装程序用它所在的网卡做 NAT。
- 云防火墙放行 **udp/500** 和 **udp/4500**。安装程序会在本机防火墙上放行这两个端口。

## 一条命令安装

在仓库目录执行：

```bash
sudo ./install.sh --domain vpn.example.com --ipv6 2001:db8::1 --email admin@example.com
```

把域名、IPv6 和邮箱换成你自己的。也可以用环境变量：

```bash
sudo VPN_DOMAIN=vpn.example.com VPN_IPV6=2001:db8::1 VPN_EMAIL=admin@example.com ./install.sh
```

`--domain` 和 `--ipv6` 必填。不写 `--email` 时，会向 Let's Encrypt 注册但不留邮箱。重复执行是安全的：已有的客户端 CA 和还没到期的证书会保留，防火墙规则不会重复添加。

常用可选项：

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `--interface` | 持有该 IPv6 的网卡 | NAT 出口 |
| `--ca-country` | `CN` | 客户端 CA 的国家代码 |
| `--ca-org` | `IKEv2` | 客户端 CA 的组织名 |
| `--pool-v4` | `10.10.10.0/24` | 分给客户端的 IPv4 |
| `--pool-v6` | `fd00:10:10::/64` | 分给客户端的 IPv6 |
| `--dns` | `1.1.1.1,8.8.8.8,2606:4700:4700::1111` | 推给客户端的 DNS |
| `--clients-dir` | `/root/vpn-clients` | 客户端文件目录 |

## 签发客户端证书

```bash
sudo ./issue-client.sh alice
```

证书写到 `/root/vpn-clients/alice/`：

- `alice.crt`、`alice.key`
- `alice.p12`（随机口令会打印在终端里，也写在 `connection.txt`）
- `alice.mobileconfig`（已用服务器证书签名，iOS / macOS 用）

iPhone 和 Mac 用 Safari 或隔空投送打开描述文件。Windows 导入 `.p12` 后新建 IKEv2，认证方式选证书。Android 用 strongSwan 客户端，类型选 IKEv2 证书，再选这个 `.p12`。

同一名字要换发时：

```bash
sudo ./issue-client.sh --force alice
```

这会先吊销旧证书，再签发新的。

## 吊销

原始搭建记录里没有吊销步骤。这里补了一条命令：吊销证书，并生成 CRL 放到 `/etc/ipsec.d/crls/`，然后重载 StrongSwan。

```bash
sudo ./revoke-client.sh alice
```

iOS 描述文件按记录里的做法关闭了证书吊销检查，手机不会自己去查 CRL。服务端会根据这份 CRL 拒绝已经吊销的证书。

## 安全说明

- 不要把真实域名、服务器地址、私钥或口令写进仓库。客户端 CA 在安装时生成，每个 `.p12` 的口令单独随机生成。
- `.p12` 和 `.mobileconfig` 里有客户端私钥。用 `scp` 或隔空投送拷走，不要放到公网 HTTP 上。
- 客户端证书可以转发全部 IPv4 / IPv6 流量（`0.0.0.0/0` 和 `::/0`）。丢掉的证书用上面的命令吊销。
- 服务器私钥和 CA 私钥权限是 `600`。Let's Encrypt 证书复制进 `/etc/ipsec.d/` 时用的是实体文件，不用软链接，避免 StrongSwan 读不到 `archive` 目录里的密钥。
