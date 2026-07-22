#!/bin/bash
# 创建或刷新 OpenWrt 源码树，不与构建步骤混合。
set -euo pipefail

WORKSPACE=${1:?usage: prepare_source.sh <workspace> <repo-url> <repo-branch> <repo-commit> <cache-dir>}
REPO_URL=${2:?usage: prepare_source.sh <workspace> <repo-url> <repo-branch> <repo-commit> <cache-dir>}
REPO_BRANCH=${3:?usage: prepare_source.sh <workspace> <repo-url> <repo-branch> <repo-commit> <cache-dir>}
REPO_COMMIT=${4:-}
BUILD_CACHE_DIR=${5:-}
SOURCE_DIR="$WORKSPACE/openwrt"

save_build_caches() {
	local directory
	[ -n "$BUILD_CACHE_DIR" ] || return 0
	for directory in dl staging_dir build_dir; do
		if [ -d "$SOURCE_DIR/$directory" ] && [ ! -L "$SOURCE_DIR/$directory" ]; then
			mkdir -p "$BUILD_CACHE_DIR"
			rm -rf "$BUILD_CACHE_DIR/$directory"
			mv "$SOURCE_DIR/$directory" "$BUILD_CACHE_DIR/$directory"
			echo "✅ Saved $directory to build cache"
		fi
	done
}

restore_build_caches() {
	local directory
	[ -n "$BUILD_CACHE_DIR" ] || return 0
	for directory in dl staging_dir build_dir; do
		if [ -d "$BUILD_CACHE_DIR/$directory" ]; then
			mv "$BUILD_CACHE_DIR/$directory" "$SOURCE_DIR/$directory"
			echo "✅ Restored $directory from build cache"
		fi
	done
}

if [ ! -e "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR/.git" ]; then
	[ -d "$SOURCE_DIR" ] && save_build_caches
	rm -rf "$SOURCE_DIR"
	for _ in 1 2 3; do
		rm -rf "$SOURCE_DIR"
		git -c http.version=HTTP/1.1 clone --depth 1 "$REPO_URL" -b "$REPO_BRANCH" "$SOURCE_DIR" && break
		echo "⚠️ git clone failed, retrying..."
		sleep 3
	done
	[ -f "$SOURCE_DIR/Makefile" ] || { echo "❌ git clone failed after 3 attempts"; exit 1; }
	restore_build_caches
fi

# 新克隆和已有工作树均使用同一条不可变的源码选择路径。
# `git pull <commit>` 可能引入非预期合并，因此不使用。
pushd "$SOURCE_DIR"
if [ -n "$REPO_COMMIT" ]; then
	git -c http.version=HTTP/1.1 fetch --depth 1 origin "$REPO_COMMIT" || {
		echo "❌ unable to fetch requested OpenWrt commit: $REPO_COMMIT"
		exit 1
	}
else
	git -c http.version=HTTP/1.1 fetch --depth 1 origin "$REPO_BRANCH" || {
		echo "❌ unable to fetch OpenWrt branch: $REPO_BRANCH"
		exit 1
	}
fi
git reset --hard FETCH_HEAD
# 在选定上游版本后，仅清理 DIY 生成的 overlay。
# 这样即使 fetch 失败也不会预先破坏可复用源码树，同时保留受跟踪的上游文件和构建缓存。
git clean -fdx -- files package
popd
