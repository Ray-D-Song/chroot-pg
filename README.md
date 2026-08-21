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

默认监听 `0.0.0.0:5432`，远程认证使用 SCRAM 密码。安装时生成随机 `postgres` 密码，或通过 `--password` / `CHROOT_PG_PASSWORD` 指定；生产使用前必须通过防火墙和 `pg_hba.conf` 限制来源地址。

密码来源（仅全新集群）：`--password` > `CHROOT_PG_PASSWORD` > 随机生成。已有数据目录时传入密码会被忽略并警告，密码以 credentials 文件为准。自动化场景优先使用环境变量，避免密码进入 shell 历史：

```bash
sudo CHROOT_PG_PASSWORD='your-secret-here' ./install.sh
```

可覆盖默认值：

```bash
sudo ./install.sh --prefix /opt/chroot-pg --data-dir /var/lib/chroot-pg/data \
  --port 5432 --listen-addresses '127.0.0.1' --password 'your-secret-here'
```

数据库集群位于数据目录下的 `data` 子目录，例如 `/var/lib/chroot-pg/data/data`。`install.sh` 在该集群的 `postgresql.conf` 与 `pg_hba.conf` 末尾维护一段 `# BEGIN chroot-pg managed settings` 到 `# END chroot-pg managed settings` 的区块，每次安装都会重写它。自定义配置请写在区块之外；`pg_hba.conf` 先匹配先生效，收紧来源地址时把自己的规则放在区块之前。

安装包同时提供 `bin/chroot-pg-backup`，用于以 PostgreSQL 用户调用
`pg_basebackup`、`pg_receivewal`、`pg_combinebackup` 和 `pg_verifybackup`。
本机模式传入 `--data-dir` 并继续使用 WAL archive；远程模式传入
`--remote`，不绑定或清理本机 PGDATA，备份文件写入 `--backup-dir`，并可用
`create-slot`、`receive-wal --slot SLOT --endpos LSN`、`drop-slot` 管理复制槽和
WAL。所有模式都通过临时 `PGPASSFILE` 传递密码，不把密码放到命令行。
安装器会维护 PG17 物理备份所需的 WAL archive、WAL summary 和 replication
连接配置。

`sudo ./uninstall.sh` 删除服务和 rootfs、保留数据；仅在确认不再需要数据库时使用 `sudo ./uninstall.sh --purge-data`。
