#!/bin/bash

set -e

IMAGE_NAME="action-lede"
PROJECT_ROOT="$(cd .. && pwd)"
CACHE_DIR="${PROJECT_ROOT}/cache"
OUTPUT_DIR="${PROJECT_ROOT}/output"

mkdir -p "${CACHE_DIR}"/{dl,staging_dir,build_dir}
mkdir -p "${OUTPUT_DIR}"

case "${1:-help}" in
    build)
        echo "构建 Docker 镜像..."
        docker build -t "${IMAGE_NAME}:latest" .
        ;;
    run)
        echo "启动交互式环境..."
        docker run -it --rm \
            -v "${CACHE_DIR}/dl:/ext-cache/dl" \
            -v "${CACHE_DIR}/staging_dir:/ext-cache/staging_dir" \
            -v "${CACHE_DIR}/build_dir:/ext-cache/build_dir" \
            -v "${OUTPUT_DIR}:/workdir/Actions-LEDE/output" \
            -v "${PROJECT_ROOT}:/workdir/Actions-LEDE" \
            "${IMAGE_NAME}:latest"
        ;;
    compile)
        echo "开始编译..."
        docker run -it --rm \
            -v "${CACHE_DIR}/dl:/ext-cache/dl" \
            -v "${CACHE_DIR}/staging_dir:/ext-cache/staging_dir" \
            -v "${CACHE_DIR}/build_dir:/ext-cache/build_dir" \
            -v "${OUTPUT_DIR}:/workdir/Actions-LEDE/output" \
            -v "${PROJECT_ROOT}:/workdir/Actions-LEDE" \
            "${IMAGE_NAME}:latest" \
            bash -c "cd /workdir/Actions-LEDE && bash build.sh"
        echo "编译完成! 固件在: ${OUTPUT_DIR}"
        ;;
    *)
        echo "用法: $0 {build|run|compile}"
        exit 1
        ;;
esac
