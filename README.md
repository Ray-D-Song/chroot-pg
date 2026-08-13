# chroot-pg

离线 PostgreSQL 17 发行包，使用 Debian 12 AMD64 chroot 运行环境，供没有外网或宿主发行版不固定的 Linux 服务器使用。

## 构建与发布

`versions.env` 锁定 PGDG 的 PostgreSQL 包版本。推送分支或 Pull Request 时 GitHub Actions 构建并验证；推送 `v*` tag 后，只有 Hosted Runner 与自建 CentOS 7 / Linux 3.10 Runner 都通过验证，才会创建 GitHub Release。

自建 Runner 必须包含标签：`self-hosted`、`linux`、`x64`、`centos7-kernel310`，并且允许无交互 `sudo`。它会真实安装、启动 systemd 服务、连接 PostgreSQL、重启并验证数据持久化。

## 安装发行包

```bash
tar -xzf chroot-pg-<version>-linux-amd64.tar.gz
cd chroot-pg-<version>-linux-amd64
sudo ./install.sh
sudo systemctl status chroot-pg
sudo cat /etc/chroot-pg/credentials
```

默认路径为 `/opt/chroot-pg`（rootfs）、`/var/lib/chroot-pg/data`（数据）和 `/etc/chroot-pg/credentials`（凭据）；数据目录不会随普通卸载或升级删除。

默认监听 `0.0.0.0:5432`，远程认证使用 SCRAM 密码。安装生成随机 `postgres` 密码；生产使用前必须通过防火墙和 `pg_hba.conf` 限制来源地址。

可覆盖默认值：

```bash
sudo ./install.sh --prefix /opt/chroot-pg --data-dir /var/lib/chroot-pg/data \
  --port 5432 --listen-addresses '127.0.0.1'
```

`sudo ./uninstall.sh` 删除服务和 rootfs、保留数据；仅在确认不再需要数据库时使用 `sudo ./uninstall.sh --purge-data`。

