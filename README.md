# Actions-LEDE

基于 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) `master` 的通用固件构建基座。它负责公共构建逻辑、软件包选择和 CI；设备仓库通过 rebase 继承本仓库，并只维护设备差异。默认直接跟随 ImmortalWrt `master` 最新提交，让上游修复能自动进入构建；`upstream.lock`/`REPO_COMMIT` 仅用于临时固定候选版本验证。

## 设计边界

- **Base**：`build.sh`、DIY 脚本、通用 `scripts/`、Docker 和 GitHub Actions。Base 不包含 `files/`。
- **设备仓库**：`config.seed`、`openwrt-device.conf`、`files/`、端口映射、恢复脚本和硬件专用模块。
- **同步方式**：设备仓库执行 `git fetch base main && git rebase base/main`，解决冲突时保留设备参数，不把设备配置回流到 Base。
- **构建输入**：只从干净且已提交的工作树构建，避免无法复现的本地试验进入固件。
- **上游边界**：不修改 ImmortalWrt 源码。默认不锁定版本；仅在候选验证时临时使用 `upstream.lock`/`REPO_COMMIT`，验证完成后移除，不保留固定值。
- **通用组件**：MMC/SDHCI、i915 GuC/HuC、Intel HDA 等通用覆盖由 Base 统一维护，设备仓库只追加硬件专用模块。

## 构建流程

`build.sh` 是唯一的构建编排入口，流程如下：

1. 默认拉取 ImmortalWrt `master` 最新提交；若临时设置了 `upstream.lock`/`REPO_COMMIT`，则恢复该候选版本。
2. 更新 feeds，运行 `diy-part1.sh` 获取自定义软件包，只注册 `config.seed` 请求的软件包及 feeds 自动解析出的依赖。
3. 两次解析 `config.seed`：先验证 feed 依赖，再验证 DIY 新增的软件包和设备 overlay。
4. 并行下载、并行编译，并在失败时保存完整日志。
5. 导出镜像、manifest、展开后的配置和 MD5；验证 SquashFS 与 LuCI 静态资源后才视为成功。

## 上游更新

日常构建跟随 ImmortalWrt `master`，无需维护固定提交。若上游出现破坏性变更，在 Base 修复配置并同步到设备仓库；需要隔离验证某个候选提交时，临时设置 `upstream.lock` 或 `REPO_COMMIT`，验证结束后移除固定值。

## CI 自动同步（merge_upstream）

`merge_upstream.yml` 保留“上游有更新则自动 rebase 到下游”的设计：Base 每 8 小时检查 `P3TERX/Actions-OpenWrt` 的 `main`，也可在 GitHub Actions 手动触发。没有新提交时直接跳过，不产生无意义的历史重写；有更新时执行 `git rebase upstream/main`，随后用 `git push --force-with-lease` 推送。冲突时工作流失败并保留人工处理，不允许用 `merge=ours` 静默覆盖。因为这是历史重写，任何本地克隆在自动同步后都必须重新 fetch 并对齐 `origin/main`，不要基于旧历史继续提交。

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
 - `<设备名>.bin`（或 `.bin.gz`）：NAND 设备（如 MT7621 HiWiFi HC5962）的 sysupgrade/factory 镜像。
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

## 运行时软件包与 SmartDNS

当前基座选择 `CONFIG_USE_APK=y`，目标系统使用 `apk`，不包含旧版 `opkg`。上游 `default-settings-chn` 首启时会设置 `system.@imm_init[0].apk_mirror`，并据此重写自动生成的 `/etc/apk/repositories.d/distfeeds.list`；不要手改该文件。在线安装前先检查该 UCI 值和 `distfeeds.list`，自定义源放入 `customfeeds.list`。

`diy-part1.sh` 查询 PikuZheng SmartDNS 最新的非预发布 `_with_ui` Release，只接受与该 tag 精确对应的 `x86_64` UI 包，并以同一 tag 固定源码。UI 下载会重试瞬态网络错误；只有元数据、下载或包校验最终失败时，才回退到 ImmortalWrt feed 的 `smartdns`、`smartdns-ui` 和 `luci-app-smartdns`。构建后以 release manifest 核对实际打入的版本。

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
