#!/bin/bash
#
# Docker build helper for Actions-LEDE
# Usage: ./docker-build.sh {build|run|compile}
#

set -e

IMAGE_NAME="action-lede"
PROJECT_ROOT="$(cd .. && pwd)"

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
        echo "开始编译..."
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
