#!/bin/bash
#
# Actions-LEDE 的 Docker 构建辅助脚本
# 对 docker compose 的轻量封装，构建配置仅以 compose 为准
#
# 用法：./docker-build.sh {build|run|compile}
#

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="actions-lede-builder"

# 可用时显示目标设备信息
if [ -f "$PROJECT_ROOT/openwrt-device.conf" ]; then
    DEVICE=$(grep '^RELEASE_NAME=' "$PROJECT_ROOT/openwrt-device.conf" 2>/dev/null | cut -d= -f2)
    [ -n "$DEVICE" ] && echo "🎯 目标设备: $DEVICE"
fi

case "${1:-help}" in
    build)
        echo "构建 Docker 镜像..."
        cd "$SCRIPT_DIR"
        docker build -t "${IMAGE_NAME}:latest" .
        ;;
    run)
        echo "启动交互式环境..."
        cd "$SCRIPT_DIR"
        docker compose run --rm builder
        ;;
    compile)
        echo "开始编译..."
        cd "$SCRIPT_DIR"
        docker compose run --rm build
        echo "编译完成! 固件在: ${PROJECT_ROOT}/release/"
        ;;
    clean)
        echo "清理 toolchain 构建缓存..."
        cd "$SCRIPT_DIR"
        docker compose up clean
        ;;
    *)
        echo "用法: $0 {build|run|compile|clean}"
        echo ""
        echo "  build   构建 Docker 镜像"
        echo "  run     启动交互式 bash 环境"
        echo "  compile 编译固件"
        echo "  clean   清理 toolchain 缓存（路径迁移后首次构建前执行）"
        echo ""
        echo "也可直接用 docker compose:"
        echo "  docker compose run --rm build    # 编译"
        echo "  docker compose run --rm builder  # 交互 shell"
        echo "  docker compose up clean          # 清理 toolchain"
        exit 1
        ;;
esac
