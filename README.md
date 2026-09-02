# DockSeed Cloudflared

用一个 Cloudflare Named Tunnel，把本机端口发布为自己的子域名。

```text
<前缀>.<根域名> -> Cloudflare Tunnel -> 本机端口或 Docker 服务
```

## 快速开始

前置条件：Docker、Docker Compose v2，以及一个由 Cloudflare 托管 DNS 的域名。

首次创建 Tunnel：

```bash
./start.sh init <根域名>
```

具体示例：

```bash
./start.sh init domain.com
```

脚本会显示 Cloudflare 授权地址。登录并选择 `domain.com` 后，它会创建 Tunnel、保存本机密钥并启动 gateway。

`init` 只用于首次创建。检测到现有 `.env` 或 Tunnel 密钥时会停止，不会执行重置或覆盖。

发布服务的通用格式：

```bash
./start.sh add <域名前缀> <本机端口> [Host header]
```

`add` 会同时创建 Cloudflare DNS。如果 DNS 由 Dashboard、Terraform 或其他方式管理，或者 hostname 已存在并且确认需要保留，只添加本地路由：

```bash
./start.sh add-route gitlab 8929
```

`add-route` 会校验路由、持久化到本机 `routes.conf`，并启动或重载 gateway，但不会创建、删除或修改 Cloudflare DNS。`routes.conf` 不提交 Git，使用者必须自行确认 DNS 已指向正确的 Tunnel。

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

Docker Desktop for Mac/Windows 上可直接使用上面的 `127.0.0.1` 端口映射。原生 Linux Docker Engine 虽然也会生成 `host.docker.internal`，但 cloudflared 容器通常无法访问只绑定到宿主机 `127.0.0.1` 的端口。Linux 上的 Docker 服务建议使用后文的“Docker 网络直连”；如果仍使用端口模式，需绑定到 Docker bridge 可访问的宿主机地址，并自行配置防火墙。

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

`add` 会把路由永久保存到 `routes.conf`，自动生成并校验配置，然后启动或重载 gateway。重复添加同一前缀会更新 origin，不会重复创建 DNS。

每次执行 `up` 都会恢复 `routes.conf` 中的全部路由，不检查对应业务服务是否启动。服务未启动时域名仍会匹配，但通常返回 `502 Bad Gateway`。

删除路由时，从 `routes.conf` 删除对应行，再运行：

```bash
./start.sh up
```

为避免误删外部资源，脚本不自动删除 Cloudflare DNS。请在 Cloudflare 控制台确认后人工删除。

如果新增 hostname 时提示 DNS 已存在，请先在 Cloudflare 控制台确认该记录属于哪个服务。确认需要保留该 DNS 并由外部管理 Tunnel Target 时，使用 `./start.sh add-route <前缀> <端口|URL>`；否则在控制台处理冲突记录后，再重新执行 `add`。

## 复用已有 Tunnel

已有 Tunnel 时不要再执行 `init`。从备份或旧工程恢复：

```text
.env                        # 填写 DOMAIN 和 TUNNEL_ID
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
- `cert.pem` 用于创建 Tunnel 和 DNS。
- 常驻容器只挂载 `tunnel.json`，不会挂载 `cert.pem`。

GitHub clone 只能恢复代码。要在新电脑继续使用同一个 Tunnel，必须从备份恢复 `.env`、`routes.conf` 和 `secrets/`；密钥文件请使用密码管理器或其他加密存储。

## 开发检查

路由回归测试使用临时目录和 mock Docker，不会连接本机 Docker 或 Cloudflare：

```bash
tests/start_test.sh
```
