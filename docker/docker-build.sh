#!/bin/bash
#
# Docker build helper for Actions-LEDE (Base 仓库)
# Base 是通用模板 + 上游，本身也包含 config.seed，可以编译出通用固件
# 各设备 fork 有独立的 config.seed/openwrt-device.conf，请用各自的 docker-build.sh
#
# Usage: ./docker-build.sh {build|run|compile}
#

set -e

IMAGE_NAME="actions-lede-builder"
PROJECT_ROOT="$(cd .. && pwd)"

# === 安全校验：如果在 Base 目录下却发现有 openwrt-device.conf ===
# 说明可能误入了设备 fork 的 docker/ 目录（以源目录名判断）
if [ -f "$PROJECT_ROOT/openwrt-device.conf" ]; then
    REPO_NAME=$(basename "$PROJECT_ROOT")
    echo "⚠️  检测到 openwrt-device.conf (RELEASE_NAME=$(grep '^RELEASE_NAME=' "$PROJECT_ROOT/openwrt-device.conf" 2>/dev/null | cut -d= -f2))"
    echo "   当前目录: $PROJECT_ROOT"
    echo "   如果是想编译设备固件，建议用该设备 fork 自己的 docker-build.sh"
    echo "   继续执行将使用 Base 的 config.seed，而非设备配置"
    echo "   (按 Ctrl+C 取消，或等待 3 秒后继续...)"
    sleep 3
fi

case "${1:-help}" in
    build)
        echo "构建 Docker 镜像..."
        docker build -t "${IMAGE_NAME}:latest" .
        ;;
    run)
        echo "启动交互式环境..."
        docker run -it --rm \
            -v "${PROJECT_ROOT}:/workdir/Actions-LEDE" \
            "${IMAGE_NAME}:latest"
        ;;
    compile)
        echo "开始编译 (Base)..."
        docker run -i --rm \
            -v "${PROJECT_ROOT}:/workdir/Actions-LEDE" \
            "${IMAGE_NAME}:latest" \
            bash -c "cd /workdir/Actions-LEDE && bash build.sh"
        echo "编译完成! 固件在: ${PROJECT_ROOT}/release/"
        ;;
    *)
        echo "用法: $0 {build|run|compile}"
        exit 1
        ;;
esac
