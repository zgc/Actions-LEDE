#!/usr/bin/env bash
# 用 Docker 跑 OpenWrt 构建，产物归宿主用户所有。
#
# 背景（2026-11-09）：直接 docker run -v $PWD:/workspace actions-lede-builder ./build.sh
# 会以容器内 root 运行；release.stale.* / feeds / package / staging_dir 在宿主上
# 全部变成 root 所有，之后 git 和清理都要 root 才能动，只能再开一个容器去 chown。
# 这里统一用宿主 uid:gid 运行，产物直接是当前用户所有（镜像里已有 uid 1000 的 ubuntu 用户）。
#
# 用法：
#   scripts/docker-build.sh <repo-dir> [build.sh 的参数...]
#   scripts/docker-build.sh            # 不带目录参数时构建本脚本所在的仓库
#   BUILDER_IMAGE=actions-lede-builder:latest
#   ALLOW_DIRTY_BUILD=1                # 允许脏工作树（透传给 build.sh）
set -euo pipefail

IMAGE="${BUILDER_IMAGE:-actions-lede-builder:latest}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -gt 0 ] && [ -d "$1" ]; then
  TARGET="$(cd "$1" && pwd)"; shift
else
  TARGET="$(cd "$SELF_DIR/.." && pwd)"
fi

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 不可用" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "ERROR: 找不到镜像 $IMAGE" >&2; exit 1; }

echo "==> 目标 $TARGET"
echo "==> 镜像 $IMAGE（以 $(id -u):$(id -g) 运行，产物归当前用户）"
exec docker run --rm -i \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e ALLOW_DIRTY_BUILD="${ALLOW_DIRTY_BUILD:-0}" \
  -v "$TARGET":/workspace \
  -w /workspace \
  "$IMAGE" ./build.sh "$@"

