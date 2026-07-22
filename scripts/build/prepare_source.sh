#!/bin/bash
# Create or refresh the OpenWrt source tree without mixing it with build steps.
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
		[ -d "$BUILD_CACHE_DIR/$directory" ] && mv "$BUILD_CACHE_DIR/$directory" "/tmp/$directory-cache"
	done
	for directory in dl staging_dir build_dir; do
		[ -d "/tmp/$directory-cache" ] && mv "/tmp/$directory-cache" "$SOURCE_DIR/$directory" && echo "✅ Restored $directory from build cache"
	done
}

if [ ! -e "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR/.git" ]; then
	[ -d "$SOURCE_DIR" ] && save_build_caches
	rm -rf "$SOURCE_DIR"
	git config --global http.version HTTP/1.1
	for _ in 1 2 3; do
		rm -rf "$SOURCE_DIR"
		git clone --depth 1 "$REPO_URL" -b "$REPO_BRANCH" "$SOURCE_DIR" && break
		echo "⚠️ git clone failed, retrying..."
		sleep 3
	done
	[ -f "$SOURCE_DIR/Makefile" ] || { echo "❌ git clone failed after 3 attempts"; exit 1; }
	restore_build_caches
fi

# Normalize a fresh clone and an existing worktree through the same immutable
# source selection path. `git pull <commit>` can merge unexpectedly.
pushd "$SOURCE_DIR"
rm -rf files package
if [ -n "$REPO_COMMIT" ]; then
	git fetch --depth 1 origin "$REPO_COMMIT" || {
		echo "❌ unable to fetch requested OpenWrt commit: $REPO_COMMIT"
		exit 1
	}
else
	git fetch --depth 1 origin "$REPO_BRANCH" || {
		echo "❌ unable to fetch OpenWrt branch: $REPO_BRANCH"
		exit 1
	}
fi
git reset --hard FETCH_HEAD
popd
