# Actions-LEDE

Build [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) firmware with GitHub Actions or locally via Docker.

## Features

- **ImmortalWrt master** base — up-to-date kernel and packages
- **GitHub Actions** workflow for automated builds (push to trigger)
- **Local Docker build** — reproducible, same environment as Actions, with optional build cache
- **Custom script hooks** — `diy-part1.sh` (pre-feeds) and `diy-part2.sh` (post-feeds) for custom packages/config
- **Base/device inheritance** — Base owns generic build logic; each device repository rebases Base and owns its device configuration

## Quick Start

### 1. Fork & configure

Use this repository for generic package selection and build logic. Device repositories rebase this branch, then provide their own `config.seed`, `openwrt-device.conf`, `files/` overlay, and topology-specific scripts.

### 2. Trigger a build

**GitHub Actions:** push to the `main` branch — the workflow builds automatically.

**Local Docker build:**

```bash
cd docker

# First build (or after path changes): clean stale toolchain
# docker compose up clean     # manual, only when needed

# Daily build
docker compose up build
```

To reuse the cross-compiler toolchain across rebuilds:

```bash
mkdir -p /data/build-cache
docker compose run \
  -e BUILD_CACHE_DIR=/workspace/cache \
  -v /data/build-cache:/workspace/cache \
  --rm build
```

Output goes to `release/` — `.img.gz` firmware plus `.manifest` and checksums.

### 3. Customize

- **`config.seed`** — package selection (start from ImmortalWrt `make menuconfig`)
- **`diy-part1.sh`** — clone custom packages, patch feeds before `feeds update`
- **`diy-part2.sh`** — UCI defaults, config templates, package fixes after `feeds install`
- **Device `files/`** — device-owned overlay copied verbatim into that device's firmware image; Base deliberately has no `files/` directory

## Files

| File | Purpose |
|------|---------|
| `build.sh` | Full build pipeline (clone → feeds → configure → compile → package) |
| `diy-part1.sh` | Custom packages & feed patches (runs before `feeds update`) |
| `diy-part2.sh` | UCI defaults, config templates, package fixes (runs after `feeds install`) |
| `config.seed` | OpenWrt `.config` template (`make defconfig` input) |
| `docker/docker-compose.yml` | Local build services (builder, clean, build) |
| `docker/docker-build.sh` | Script inside the container to launch `build.sh` |
| Device `files/` | Device-owned root overlay; intentionally absent from Base |

## Project Structure

```
actions-lede/
├── .github/workflows/     # GitHub Actions workflow
├── config.seed            # Package selection template
├── diy-part1.sh           # Pre-feeds customizations
├── diy-part2.sh           # Post-feeds customizations
├── build.sh               # Full build script
├── docker/
│   ├── docker-compose.yml # builder / clean / build services
│   └── docker-build.sh    # Container entrypoint
└── scripts/               # Custom build-time helpers
```

## Notes

- **Caching**: the `BUILD_CACHE_DIR` volume preserves `dl/`, `staging_dir/`, and `build_dir/` between containers — saves ~15 minutes per rebuild.
- **Clean toolchain**: `docker compose up clean` removes stale toolchain artifacts (build_dir/toolchain*, staging_dir/toolchain*) — run after switching build paths or when toolchain gets corrupted.
- **Full reset**: stop containers, delete `openwrt/`, then `docker compose up build` for a from-scratch build.
- The expanded `.config` is saved as `config.buildinfo` after each successful build.
- **Device alignment**: in a device repository, run `git fetch base main && git rebase base/main`; resolve only device-owned differences and verify with `git merge-base --is-ancestor base/main HEAD`.

## Credits

- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt) — original template
- [GitHub Actions](https://github.com/features/actions)
