# singbox-onekey

基于官方 [sing-box](https://github.com/SagerNet/sing-box) 的多协议代理一键部署脚本，自带 HTTPS 订阅链接。

## 包含什么

| 协议 | 默认端口 |
|---|---|
| VLESS + Reality + Vision | TCP 443 |
| Hysteria2 | UDP 8443 |
| TUIC v5 | UDP 8444 |
| Shadowsocks 2022 | TCP/UDP 8388 |
| VMess + WebSocket | TCP 8080 |

- **订阅链接**：Caddy 提供 HTTPS 订阅，用 Let's Encrypt IP 证书（无需域名），自动续期
- **一个链接通吃**：Clash / Mihomo 系客户端自动拿到带分流规则的 Clash 配置，v2rayN / Shadowrocket / NekoBox 等拿到通用节点列表
- BBR 加速、虚拟内存（默认 8G）
- 密钥全部在服务器本地随机生成，重复运行沿用原密钥，订阅链接不变

## 一键安装

系统要求：Debian 11+ / Ubuntu 20.04+，root 用户，80 端口空闲（申请证书用）。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chen461365570/singbox-onekey/main/install.sh)
```

装完会显示订阅链接，粘贴到客户端的"添加订阅"即可。

## 管理命令

安装后可直接使用 `onekey` 命令：

```bash
onekey info        # 查看订阅链接和节点链接
onekey install     # 更新配置（沿用密钥）
onekey regen       # 更换全部密钥和订阅链接（旧链接立即失效）
onekey uninstall   # 卸载（保留虚拟内存）
```

## 可选参数

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chen461365570/singbox-onekey/main/install.sh) \
  --name JP --swap 2G --sni www.apple.com
```

| 参数 | 说明 | 默认 |
|---|---|---|
| `--name` | 节点名前缀 | 自动识别国家代码 |
| `--sni` | Reality 伪装站点 | www.microsoft.com |
| `--swap` | 虚拟内存大小，`0` 不创建 | 8G（磁盘不够自动缩小） |
| `--domain` | 订阅用自己的域名（需已解析到本机） | 直接用 IP |
| `--sub-port` | 订阅 HTTPS 端口 | 2096 |
| `--no-sub` / `--with-sub` | 关闭 / 重新开启订阅服务 | 开启 |
| `--ports` | VLESS,Hy2,TUIC,SS,VMess 端口 | 443,8443,8444,8388,8080 |

参数会被记住，下次运行 `onekey install` 自动沿用。

## 注意

- 订阅链接等于全部节点的钥匙，不要外泄；泄露后运行 `onekey regen`
- 云服务商有安全组的，需在控制台放行上表端口以及 80、2096
- Hysteria2 / TUIC 使用自签证书，客户端已设置跳过证书验证
- 密钥和链接保存在服务器 `/etc/onekey-proxy/`（仅 root 可读）

## License

MIT
