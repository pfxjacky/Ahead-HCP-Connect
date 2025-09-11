# Ahead-HCP-Connect


One key Install script

```bash
wget https://raw.githubusercontent.com/pfxjacky/Ahead-HCP-Connect/refs/heads/main/dingliu-install-script.sh && chmod +x dingliu-install-script.sh && ./dingliu-install-script.sh
```







对齐要点 / 兼容性

协议完全与服务端对齐：

握手：client→server 发送 salt_c(32B)，收到 salt_s(32B)；

KDF：blake3.DeriveKey（“demo c2s key”/“demo s2c key”）+ 原始 PSK + 对应 salt；

Nonce：blake3.Sum256(... "demo * nonce") 取前 24B 作为 base nonce，末 8B 大端计数器；

帧：[2B ciphertext_len][ciphertext]，ciphertext= XChaCha20-Poly1305( [2B payload_len | payload] )；空 payload 帧 == 关闭信号。

SNI/证书：默认用 --server 作为 SNI，可用 --sni 覆盖；自签证书测试期可 --tls-insecure。

性能：默认每连接一个隧道；如你要复用/多路复用，后续可以在这层再做 Mux（或改服务端支持 HTTP/2/WS/QUIC 等传输，这就接近标准核心了）。



服务端完全协议对齐（Blake3 KDF、XChaCha20-Poly1305、24B 基 nonce + 8B 计数器、2B 长度头 + AEAD(len|payload) 帧、空帧表示对端关闭）。

客户端（Windows 为主，亦可 Linux/macOS）



smux 多路复用：单条外层 TLS+HEAD 隧道上，承载多条子流（每条子流首包携带目标 host:port）。

多线程/多隧道池：可配置 pool 条并发隧道（每条隧道各自一个 smux session），提升吞吐与多核利用。

多节点轮询/故障转移：节点列表 round-robin，握手失败/运行报错自动切换；后台健康检查恢复。

PSK 自举：客户端启动时若没有 PSK，会走一次 TLS + 管理口 /provision 请求，让服务端生成/轮换 psk.bin 并返回 Base64，然后客户端落盘/热加载。

GUI & 托盘：提供托盘图标+本地 Web 控制台（美观易用）；可最小化到系统托盘运行，v2rayN 仍可把它作为自定义核心启动/停止。
MUX/SMUX：已实现（xtaci/smux）。服务端补丁支持 CONNECT __mux__:0 触发多路复用；子流首帧携带目标。

服务端 PSK 从客户端启动时自动生成：客户端在 TLS 下调用 POST /provision（带 X-Admin-Token），服务端生成/落盘/热更新并回传 Base64，客户端保存。

GUI/托盘：内置系统托盘 + Web 控制台（好看的 UI 可继续美化成 React/Antd 版）；可最小化+托管。

多线程性能：Go runtime 多核；隧道 pool>1 + 每条隧道 smux 多子流，最大化吞吐。

多节点轮询/故障转移：节点列表 round-robin，隧道断开自动重连下一个；你也可以加“健康检查定时拨测”。

TLS（PKCS#12/PFX，自签自动生成）

/provision 接口（动态生成/轮换 PSK）

普通 CONNECT 与 MUX（smux） 模式


