# Actions-LEDE

Build [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) firmware with GitHub Actions or locally via Docker.

## Features

- **ImmortalWrt master** base — up-to-date kernel and packages
- **GitHub Actions** workflow for automated builds (push to trigger)
- **Local Docker build** — reproducible, same environment as Actions, with optional build cache
- **Custom script hooks** — `diy-part1.sh` (pre-feeds) and `diy-part2.sh` (post-feeds) for custom packages/config
- **Device-specific overrides** — use `openwrt-device.conf` to set `RELEASE_NAME` and `BUILD_CACHE_DIR` per device

## Quick Start

### 1. Fork & configure

Fork this repository, then push a custom `config.seed` and optional `files/` overlay directory.

### 2. Trigger a build

**GitHub Actions:** push to the `main` branch — the workflow builds automatically.

**Local Docker build:**

```bash
cd docker
docker-compose run --rm build
```

To reuse the cross-compiler toolchain across rebuilds:

```bash
# Create a cache directory on a fast volume
mkdir -p /data/build-cache
docker-compose run -e BUILD_CACHE_DIR=/workdir/Actions-LEDE/cache -v /data/build-cache:/workdir/Actions-LEDE/cache --rm build
```

Output goes to `release/` — `.img.gz` firmware plus `.manifest` and checksums.

### 3. Customize

- **`config.seed`** — package selection (start from ImmortalWrt `make menuconfig`)
- **`diy-part1.sh`** — clone custom packages, patch feeds before `feeds update`
- **`diy-part2.sh`** — UCI defaults, config templates, package fixes after `feeds install`
- **`files/`** — overlay directory copied verbatim into the firmware image

## Files

| File | Purpose |
|------|---------|
| `build.sh` | Full build pipeline (clone → feeds → configure → compile → package) |
| `diy-part1.sh` | Custom packages & feed patches (runs before `feeds update`) |
| `diy-part2.sh` | UCI defaults, config templates, package fixes (runs after `feeds install`) |
| `config.seed` | OpenWrt `.config` template (`make defconfig` input) |
| `docker/docker-compose.yml` | Local build container definition |
| `docker/docker-build.sh` | Script inside the container to launch `build.sh` |
| `files/` | Root overlay for firmware image (optional) |

## Project Structure

```
actions-lede/
├── .github/workflows/     # GitHub Actions workflow
├── config.seed            # Package selection template
├── diy-part1.sh           # Pre-feeds customizations
├── diy-part2.sh           # Post-feeds customizations
├── build.sh               # Full build script
├── docker/
│   ├── docker-compose.yml # Container orchestration
│   └── docker-build.sh    # Container entrypoint
├── files/                 # Firmware root overlay
└── scripts/               # Custom build-time helpers
```

## Notes

- **Caching**: the `BUILD_CACHE_DIR` volume preserves `dl/`, `staging_dir/`, and `build_dir/` between containers — saves ~15 minutes per rebuild.
- **Clean rebuild**: `docker-compose down -v` removes all volumes; the next build starts fresh.
- The expanded `.config` is saved as `config.buildinfo` after each successful build.

## Credits

- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt) — original template
- [GitHub Actions](https://github.com/features/actions)
