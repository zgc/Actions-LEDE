# Actions-LEDE

基于 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) `master` 的通用固件构建基座。它负责公共构建逻辑、软件包选择和 CI；设备仓库通过 rebase 继承本仓库，并只维护设备差异。

## 设计边界

- **Base**：`build.sh`、DIY 脚本、通用 `scripts/`、Docker 和 GitHub Actions。Base 不包含 `files/`。
- **设备仓库**：`config.seed`、`openwrt-device.conf`、`files/`、端口映射、恢复脚本和硬件专用模块。
- **同步方式**：设备仓库执行 `git fetch base main && git rebase base/main`，解决冲突时保留设备参数，不把设备配置回流到 Base。
- **构建输入**：只从干净且已提交的工作树构建，避免无法复现的本地试验进入固件。

## 构建流程

`build.sh` 是唯一的构建编排入口，流程如下：

1. 固定 ImmortalWrt 源码版本并恢复可复用缓存。
2. 更新和安装 feeds，运行 `diy-part1.sh` 获取自定义软件包。
3. 两次解析 `config.seed`：先验证 feed 依赖，再验证 DIY 新增的软件包和设备 overlay。
4. 并行下载、并行编译，并在失败时保存完整日志。
5. 导出镜像、manifest、展开后的配置和 MD5；验证 SquashFS 与 LuCI 静态资源后才视为成功。

## 本地 Docker 构建

Docker 容器以宿主 UID/GID 运行，避免 bind mount 中的产物变成 `nobody`。首次构建使用当前 Dockerfile 创建镜像；Dockerfile 更新后需显式重建镜像。

```bash
cd docker
docker compose up build
```

Dockerfile 更新后：

```bash
cd docker
docker compose up --build build
```

仅在工具链损坏或构建路径改变后清理陈旧产物：

```bash
cd docker
docker compose up clean
```

可选的持久缓存会复用 `dl/`、`staging_dir/` 和 `build_dir/`：

```bash
mkdir -p /data/build-cache
docker compose run --rm \
  -e BUILD_CACHE_DIR=/workspace/cache \
  -v /data/build-cache:/workspace/cache \
  build
```

构建产物位于 `release/`：

- `<设备名>.img.gz`：刷写镜像。
- `<设备名>.manifest`：实际写入镜像的软件包清单。
- `config.buildinfo` 和 `<设备名>.target.config.buildinfo`：展开后的构建配置。
- `.md5`：压缩镜像和解压后镜像的校验值。

## 定制入口

| 文件 | 职责 |
| --- | --- |
| `config.seed` | 公共软件包选择模板；设备仓库可在此添加硬件驱动。 |
| `diy-part1.sh` | feeds 更新前获取第三方软件包和源码。 |
| `diy-part2.sh` | feeds 安装后设置默认配置、软件包覆盖和构建元数据。 |
| `scripts/` | 可复用的构建、验证和设备运行时辅助脚本。 |
| `openwrt-device.conf` | 仅设备仓库维护的发布名、磁盘、版本和私有运行参数。 |
| `files/` | 仅设备仓库维护的 rootfs overlay，按原路径写入镜像。 |

## 验证要求

每次变更后至少完成以下检查：

```bash
git diff --check
find . -path './openwrt' -prune -o -name '*.sh' -type f -print0 | xargs -0 -r -n1 bash -n
docker compose -f docker/docker-compose.yml config >/dev/null
```

固件构建成功后，`scripts/verify_firmware.sh` 会验证：选中软件包是否出现在 manifest、压缩镜像是否完整、SquashFS 是否可完整提取，以及 LuCI 所需资源是否存在。刷机前仍应结合目标设备日志、网络接口和关键服务做实际验证。

## CI

GitHub Actions 调用同一份 `build.sh`，不复制构建逻辑。CI 只读取 `openwrt-device.conf` 中格式受限的 `RELEASE_NAME`，不会打印或 `source` 整个设备配置，从而避免私有运行参数进入日志。

## 致谢

- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [GitHub Actions](https://github.com/features/actions)
