# EasyProp

**Modern, click-anywhere RF coverage viewer built on SPLAT!**

Open a browser, drop a transmitter pin anywhere in the contiguous US,
pick a band (FRS / GMRS / MURS / 2 m / 70 cm / UHF-TV / …) and an
antenna preset, and see the real-terrain signal-strength contours
overlaid on an OpenStreetMap basemap. Backed by [SPLAT! 1.4.2][splat]'s
ITWOM propagation engine + 1-arc-second SRTM terrain auto-fetched on
demand.

![Interactive coverage map over real SRTM terrain](viewer/screenshots/auto-fetch-vineland.png)

## What it does

Built around three pieces that talk to each other through plain files:

1. **SPLAT! HD** (the original C++ engine, ported here to Windows
   MSVC / CMake / vcpkg) reads a `.qth` (TX location + height), a
   `.lrp` (radio params + ERP), and SRTM-derived `.sdf` terrain tiles,
   then writes a coverage map as **PNG** or **GeoTIFF** (Phase 2 and
   Phase 3 added these alongside the legacy PPM output).
2. **A static-file + JSON server** ([viewer/launch.ps1](viewer/launch.ps1))
   that turns POSTed form data into `.qth` + `.lrp`, invokes SPLAT!,
   and serves the result. It auto-fetches missing SRTM tiles from the
   public AWS Mapzen Skadi mirror through
   [utils/fetch_srtm.ps1](utils/fetch_srtm.ps1).
3. **A Leaflet front-end** ([viewer/index.html](viewer/index.html))
   that lets you click-to-place a TX, pick band / antenna / power
   presets, and overlay the resulting georeferenced PNG on an OSM
   basemap with an opacity slider.

So you get a workflow like:

```
click map → POST /compute → fetch SRTM tiles → write qth+lrp →
   splat-hd → png+geo → overlay refreshes on basemap
```

## Quick start (Windows)

```powershell
# 0. Prereqs (one-time): Visual Studio Build Tools 2022 (C++ workload),
#    vcpkg bootstrapped at $env:USERPROFILE\vcpkg.

# 1. Build everything (std splat for tests, HD splat for interactive,
#    plus the srtm2sdf converter).
$env:VCPKG_ROOT = "$env:USERPROFILE\vcpkg"
cmake -S . -B C:\splat-build    -G "Visual Studio 17 2022" -A x64 -DSPLAT_BUILD_UTILS=ON
cmake --build C:\splat-build    --config Release --target srtm2sdf-hd

cmake -S . -B C:\splat-build-hd -G "Visual Studio 17 2022" -A x64 -DSPLAT_HD_MODE=1 -DSPLAT_MAXPAGES=9
cmake --build C:\splat-build-hd --config Release --target splat

# 2. Launch the viewer. SRTM tiles get cached in -SourceDir on first
#    click in each new region (~6 min); subsequent clicks reuse them.
mkdir C:\splat-work
copy sample_data\wnju-dt.qth C:\splat-work\         # any TX for the initial preview
copy sample_data\wnju-dt.lrp C:\splat-work\
.\viewer\launch.ps1 -SourceDir C:\splat-work
```

Browser opens at `http://localhost:8765/`. Click anywhere in the
contiguous US, pick band + antenna + power, hit **Compute coverage**,
wait for terrain to download (first time per region) + SPLAT! to run.

If PowerShell complains about execution policy on first launch:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

See [viewer/README.md](viewer/README.md) for the full interactive-viewer
docs (the HTTP API, options, screenshots, etc.).

## Repo layout

```
.
├── CMakeLists.txt          ← top-level build (replaces upstream bash
│                              configure + build, supports MSVC + GCC)
├── cmake/Dependencies.cmake  ← find_package wrappers for bzip2, zlib, tiff
├── vcpkg.json              ← dependency manifest for vcpkg
├── src/                    ← splat sources (moved here from project root)
│   ├── splat.cpp           ← the engine + the 4 image writers (refactored
│   │                          to emit PPM / PNG / GeoTIFF behind a unified
│   │                          per-pixel-color dispatch path)
│   ├── itwom3.0.cpp        ← propagation physics (untouched)
│   ├── compat/             ← Windows portability shims (unistd/mkstemp/...)
│   ├── render/             ← Image + PngWriter + GeoTiffWriter (Phase 2-3)
│   └── third_party/        ← vendored stb_image_write.h
├── utils/                  ← srtm2sdf (ported to Windows) + others
│   └── fetch_srtm.ps1      ← public SRTM tile fetcher
├── viewer/                 ← Leaflet front-end + PowerShell HTTP server
│   ├── index.html
│   ├── launch.ps1
│   ├── README.md           ← full viewer docs
│   └── screenshots/
├── tests/                  ← regression harnesses
│   ├── run_golden.ps1            ← Tier-1: text path-report SHA-256
│   ├── run_image_golden.ps1      ← Tier-2: 4 image writers x 3 formats
│   └── inspect_geotiff.ps1       ← pure-PS GeoTIFF tag inspector
├── sample_data/            ← upstream WNJU-DT sample inputs (unchanged)
├── docs/                   ← upstream SPLAT! documentation
├── README                  ← original SPLAT! 1.4.2 README (preserved)
├── CHANGES                 ← original SPLAT! 1.4.2 changelog (preserved)
└── COPYING                 ← GPL v2 license text (this is GPL too)
```

## What's been built on top of upstream SPLAT! 1.4.2

In commit-history order — each step has a regression net behind it
(`tests/run_golden.ps1` text reports, `tests/run_image_golden.ps1`
4-variant × 3-format image gates):

| # | Phase | What it added |
|---|-------|---------------|
| 1 | Cross-platform | CMake + vcpkg replace the bash `./configure` + interactive prompts. Builds on MSVC, gcc, clang. |
| 1 | DEM heap refactor | The multi-GB compile-time-sized static arrays became heap-allocated pointer-to-row buffers — required for MSVC (no `-mcmodel=medium`), zero call-site changes. |
| 1 | 3 porting bug fixes | `assert((s=new ...))` side effect lost in Release; MSVC stack default too small for the ITWOM call chain; `acos(1+ε)` NaN in `Distance()` under `/fp:fast`. |
| 1 | SDF separator | Tile filenames switched from `:` (illegal on NTFS) to `_` on Windows. |
| 2 | PNG output | New `src/render/` module (vendored `stb_image_write.h`); all 4 image writers (topo/LR/SS/dBm) emit PNG alongside PPM, verified byte-identical (34.9 M pixels, 0 diffs). |
| 3 | GeoTIFF output | libtiff-backed GeoTIFF writer with EPSG:4326 georeferencing tags; recognized by QGIS / ArcGIS / GDAL / leaflet-geotiff. |
| 5 | Leaflet viewer | Static-overlay viewer with the PNG anchored to its `.geo` bounds. |
| 6 | Real terrain | Ported `srtm2sdf` to Windows; `fetch_srtm.ps1` pulls 1-arc-second SRTM from public mirrors and converts to `.sdf-hd`. |
| 7 | Interactive form | Click-to-place TX + band / antenna presets + radio params + `POST /compute` endpoint that drives splat live. |
| 8 | Click anywhere | Auto-fetch fills in whatever SRTM tiles the click needs; AWS Mapzen Skadi mirror (more complete than ESA) is primary. |

## Credits

- **SPLAT! 1.4.2** by [John A. Magliacane, KD2BD][splat] — the engine,
  the SRTM/USGS pipeline, the LRP propagation model. EasyProp is a
  derivative work and keeps SPLAT!'s GPL v2 license (see [COPYING](COPYING)
  and the preserved [README](README)).
- **ITWOM 3.0** by Sid Shumate — propagation physics.
- **stb_image_write.h** by Sean Barrett — public-domain single-header
  PNG writer (vendored under [src/third_party/](src/third_party/)).
- **libtiff** via vcpkg — GeoTIFF.
- **Leaflet** + **OpenStreetMap** — basemap.
- **AWS Mapzen Skadi** + **ESA SRTMGL1** — public SRTM mirrors.

## License

GPL v2 (matching upstream SPLAT!). See [COPYING](COPYING).

[splat]: https://www.qsl.net/kd2bd/splat.html
