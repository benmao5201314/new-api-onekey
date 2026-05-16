# new-api 极简一键安装脚本

本目录提供一个面向 [`QuantumNous/new-api`](https://github.com/QuantumNous/new-api) 的极简一键安装脚本。脚本采用 Docker Compose 部署 `new-api` 主程序，并默认配套 PostgreSQL 与 Redis，安装完成后会自动识别 VPS 外网 IP，直接输出完整访问地址、OpenAI 兼容 API 地址、登录入口和管理员账号信息。[1]

> **使用原则：** 安装尽量默认化，只在确有必要时让用户选择；卸载默认彻底清理，不保留任何与 new-api 相关的数据、配置、日志、容器、网络和专用数据卷。

## 快速使用

在服务器上执行下面的一键命令即可进入安装菜单：

```bash
curl -fsSL https://github.com/benmao5201314/new-api-onekey/raw/refs/heads/main/install.sh | sudo bash
```

如果你已经下载了脚本，也可以在服务器本地执行：

```bash
chmod +x install.sh
sudo ./install.sh
```

## 菜单功能

运行脚本后会进入菜单。安装时默认使用 `3000` 端口；只有当 `3000` 被占用时，脚本才会要求输入其他端口。管理员账号固定为 `root`，管理员密码可以选择**随机生成**或**自定义输入**。如果选择随机生成，脚本会在安装结束时再次明确显示密码，避免用户不知道登录凭据。

| 菜单项 | 功能 | 行为说明 |
|---:|---|---|
| 1 | 安装 new-api | 自动安装 Docker、生成配置、启动 PostgreSQL、Redis 与 new-api，并初始化管理员账号。 |
| 2 | 更新 new-api | 拉取最新 `calciumion/new-api:latest` 镜像并重启服务。 |
| 3 | 查看状态与凭据 | 显示容器状态、本机状态接口和安装时保存的管理员凭据。 |
| 4 | 查看日志 | 实时查看 `new-api` 容器日志。 |
| 5 | 彻底卸载 new-api | 删除容器、专用网络、专用数据卷、安装目录、配置、数据和日志。 |
| 0 | 退出 | 不执行任何操作。 |

## 默认部署参数

脚本使用 `/opt/new-api` 作为安装目录，并将所有 new-api 相关配置、日志和数据集中放在该目录或专用 Docker 数据卷中。new-api 官方项目支持 Docker Compose 部署，并在常见示例中使用 `3000` 作为 Web 服务端口。[1]

| 配置项 | 默认值 | 是否询问 | 说明 |
|---|---:|---:|---|
| 安装目录 | `/opt/new-api` | 否 | 保存 `docker-compose.yml`、`.env`、数据目录和日志目录。 |
| Web 端口 | `3000` | 仅端口占用时询问 | 安装结束后访问 `http://VPS外网IP:端口/`。 |
| 管理员账号 | `root` | 否 | 为减少交互固定使用 root。 |
| 管理员密码 | 随机生成或自定义 | 是 | 随机生成会在安装结束显示，也会保存到凭据文件。 |
| 数据库 | PostgreSQL 15 | 否 | 使用专用 Docker 数据卷 `new-api-postgres-data`。 |
| 缓存 | Redis latest | 否 | 自动生成 Redis 密码，仅在容器网络内使用。 |
| new-api 镜像 | `calciumion/new-api:latest` | 否 | 更新菜单会拉取该镜像的最新版本。 |

## 安装完成后的输出

安装成功后，脚本会自动识别 VPS 外网 IPv4，并输出以下完整地址。若公网 IP 查询服务不可用，脚本会回退显示本机首个非回环 IPv4。

| 输出项 | 示例 |
|---|---|
| 服务首页 | `http://1.2.3.4:3000/` |
| 登录页面 | `http://1.2.3.4:3000/login` |
| Web 管理面板 | `http://1.2.3.4:3000/` |
| OpenAI 兼容 API Base URL | `http://1.2.3.4:3000/v1` |
| 模型列表接口 | `http://1.2.3.4:3000/v1/models` |
| 状态接口 | `http://1.2.3.4:3000/api/status` |

管理员凭据也会在安装结束显示，并保存到：

```bash
/opt/new-api/admin-credentials.txt
```

## 彻底卸载说明

卸载菜单不会询问是否保留数据，而是默认执行彻底清理。脚本会停止并删除 `new-api`、`new-api-postgres`、`new-api-redis` 容器，删除 `new-api-network` 网络，删除 `new-api-postgres-data` 专用数据卷，删除 `/opt/new-api` 安装目录，并尝试移除 `calciumion/new-api:latest` 应用镜像。PostgreSQL 与 Redis 的通用基础镜像可能被其他项目共用，因此脚本不会强制删除这些通用镜像。

## 常用管理命令

如果需要手动排查，可以进入安装目录使用 Docker Compose 命令。

```bash
cd /opt/new-api
sudo docker compose --env-file .env ps
sudo docker compose --env-file .env logs -f --tail=120 new-api
sudo docker compose --env-file .env restart new-api
```

## 参考资料

[1]: https://github.com/QuantumNous/new-api "QuantumNous/new-api GitHub Repository"
