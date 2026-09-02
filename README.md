# DockSeed Cloudflared

用一个 Cloudflare Named Tunnel，把本机端口发布为自己的子域名。

```text
<前缀>.<根域名> -> Cloudflare Tunnel -> 本机端口或 Docker 服务
```

## 快速开始

前置条件：Bash、Docker、Docker Compose v2，以及一个由 Cloudflare 托管 DNS 的域名。Windows 请在 WSL 中运行脚本。

复制环境变量示例：

```bash
cp .env.example .env
```

编辑 `.env`，把 `DOMAIN` 改为自己的根域名，首次初始化时保持 `TUNNEL_ID` 为空。其他配置可以继续使用示例中的默认值。然后创建 Tunnel：

```bash
./start.sh init
```

脚本会显示 Cloudflare 授权地址。登录并选择对应域名后，它会创建 Tunnel、把 `TUNNEL_ID` 回填到 `.env`、保存本机密钥并启动 gateway。如需自定义 Tunnel 名称，使用 `./start.sh init <Tunnel名称>`。

`init` 只用于首次创建。检测到现有 `TUNNEL_ID` 或 Tunnel 密钥时会停止，不会执行重置或覆盖。

发布服务的通用格式：

```bash
./start.sh add <域名前缀> <本机端口> [Host header]
```

具体示例：

```bash
./start.sh add gitlab 8929
./start.sh add docsite 5173
```

假设根域名是 `domain.com`，结果是：

```text
gitlab.domain.com  -> 本机的 8929 端口
docsite.domain.com -> 本机的 5173 端口
```

`gitlab`、`docsite`、`8929` 和 `5173` 都只是示例，不是固定值。

## Docker 服务：默认端口模式

Docker 服务先把容器端口映射到本机。例如：

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    ports:
      - "127.0.0.1:8929:80"
```

这里：

- `8929` 是本机端口，可自行选择。
- `80` 是 GitLab 容器内部端口，由镜像决定。

发布命令使用本机端口：

```bash
./start.sh add gitlab 8929
```

脚本内部会转换成 `http://host.docker.internal:8929`。

Docker Desktop for Mac 可直接使用上面的 `127.0.0.1` 端口映射；Windows 请在 WSL 中使用 Docker Desktop。原生 Linux Docker Engine 虽然也会生成 `host.docker.internal`，但 cloudflared 容器通常无法访问只绑定到宿主机 `127.0.0.1` 的端口。Linux 上的 Docker 服务建议使用后文的“Docker 网络直连”；如果仍使用端口模式，需绑定到 Docker bridge 可访问的宿主机地址，并自行配置防火墙。

## 本机开发服务

如果本地开发服务监听 `5173`：

```bash
./start.sh add docsite 5173
```

某些开发服务器会拒绝陌生 Host header，这时追加第三个参数：

```bash
./start.sh add docsite 5173 localhost
```

不要默认加 `localhost`。它只是在本地服务返回 `Invalid Host` 或 `403` 时的兼容选项。

## Docker 网络直连：高级模式

不想映射本机端口时，可以使用完整 origin URL：

```bash
./start.sh add <域名前缀> http://<Compose服务名>:<容器端口>
```

具体示例：

```bash
./start.sh add gitlab http://gitlab:80
```

这个示例中的：

- 第一个 `gitlab` 是域名前缀。
- URL 中的 `gitlab` 是 Compose 服务名。
- `80` 是容器内部端口。

业务容器必须加入 gateway 的外部网络：

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    networks:
      - default
      - gateway

networks:
  gateway:
    external: true
    name: dockseed-gateway
```

默认优先使用前面的端口模式；Docker 直连只是可选优化。

## 日常命令

```bash
./start.sh help
./start.sh up
./start.sh status
./start.sh logs
./start.sh stop
```

`add` 会把路由永久保存到 `routes.conf`，自动生成并校验配置，然后启动或重建 gateway 容器。重复添加同一前缀会更新 origin，不会重复创建 DNS。

每次执行 `up` 都会恢复 `routes.conf` 中的全部路由，不检查对应业务服务是否启动。服务未启动时域名仍会匹配，但通常返回 `502 Bad Gateway`。

## 连接协议

默认使用 `auto`，由 cloudflared 自动选择连接协议。如果在 VPN、代理或限制 UDP 的网络中遇到 QUIC 连接不稳定，可以在 `.env` 中强制使用 HTTP/2：

```dotenv
CLOUDFLARED_PROTOCOL=http2
```

该设置只用于 cloudflared 到 Cloudflare 边缘节点之间的 Tunnel 连接，不改变浏览器或 Git 客户端的访问方式。可选值为 `auto`、`quic` 和 `http2`；修改后运行 `./start.sh up` 应用配置。

## 升级 Cloudflared

修改 `.env` 中 `CLOUDFLARED_IMAGE` 的 tag，然后执行：

```bash
./start.sh up
./start.sh status
```

本机缺少目标镜像时 Docker 会自动拉取。升级不需要重新执行 `init`，也不会改变 Tunnel ID、路由或凭据。

删除路由时，从 `routes.conf` 删除对应行，再运行：

```bash
./start.sh up
```

为避免误删外部资源，脚本不自动删除 Cloudflare DNS。请在 Cloudflare 控制台确认后人工删除。

如果新增 hostname 时提示 DNS 已存在，请先在 Cloudflare 控制台确认该记录属于哪个服务，再删除或改指向当前 Tunnel。

## 复用已有 Tunnel

已有 Tunnel 时不要再执行 `init`。从备份或旧工程恢复：

```text
.env                        # 从 .env.example 复制，填写 DOMAIN 和 TUNNEL_ID
routes.conf                 # 原来的本地路由
secrets/tunnel.json         # 原来的 <Tunnel UUID>.json
```

然后执行 `./start.sh up`。如果某个 hostname 的 DNS 已经指向这个 Tunnel，直接在 `routes.conf` 中写入对应路由并执行 `up`，不需要再创建 DNS。

## Git 与密钥

以下文件不会提交 Git：

```text
.env
routes.conf
secrets/tunnel.json
secrets/cert.pem
cloudflared/config.yml
```

- `routes.conf` 保存本机路由，不包含密钥。
- `tunnel.json` 用于运行当前 Tunnel。
- `cert.pem` 用于创建 Tunnel 和 DNS，权限范围比仅运行当前 Tunnel 的 `tunnel.json` 更大，应作为高敏感凭据保管。
- 常驻容器只挂载 `tunnel.json`，不会挂载 `cert.pem`。

GitHub clone 只能恢复代码。要在新电脑继续使用同一个 Tunnel，必须从备份恢复 `.env`、`routes.conf` 和 `secrets/`；密钥文件请使用密码管理器或其他加密存储。
