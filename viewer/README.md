# SPLAT! web viewer

A tiny browser viewer that overlays SPLAT!'s coverage maps on an
OpenStreetMap basemap, geographically anchored using the `.geo` sidecar
SPLAT! already emits.

## What you get

- **OSM basemap** under your coverage data, so you can see exactly where
  the signal goes versus the actual coastline / roads / cities.
- An **opacity slider** to fade between the coverage overlay and the map.
- A **"Fit to coverage" button** that snaps the viewport to the analysis
  region.
- The parsed bounds (north/south/east/west) shown in the side panel as a
  sanity check.

## Quick start

```powershell
# 1. Generate a coverage PNG + the .geo sidecar (the -geo flag is what
#    produces the sidecar; the .png extension picks the new PNG writer).
splat -t wnju-dt.qth -c 30 -metric -geo -o coverage.png

# 2. Launch the viewer (opens http://localhost:8765/?name=coverage and
#    your default browser).
../viewer/launch.ps1 coverage
```

That's it. Ctrl+C in the launch.ps1 window stops the server and cleans
up its temp dir.

## How it works (no magic)

`launch.ps1` stages `<name>.png`, `<name>.geo`, and `viewer/index.html`
into a temp directory, then starts a tiny .NET `HttpListener` on
`http://localhost:<port>/` (default 8765). No admin needed -- localhost
binding doesn't require URL ACL reservations.

`index.html` is a single-page Leaflet app that:
1. Loads Leaflet from unpkg CDN.
2. Adds the OpenStreetMap tile layer as a basemap.
3. `fetch()`es `<name>.geo` and parses its two `TIEPOINT` lines for the
   bounding-box corners.
4. Adds the PNG as an `L.imageOverlay` over those bounds.
5. Fits the viewport, wires the opacity slider, done.

The same file works for any SPLAT! map -- `?name=foo` loads `foo.png`
and `foo.geo`.

## Options

```powershell
launch.ps1 coverage                   # default: -SourceDir . -Port 8765
launch.ps1 coverage -Port 9000        # different port
launch.ps1 coverage -SourceDir ..\work
launch.ps1 coverage -NoBrowser        # don't auto-open browser
```

## Notes

- The CDN load requires internet on first launch. If you need offline,
  download `leaflet.css` and `leaflet.js` from unpkg.com/leaflet@1.9.4
  alongside `index.html` and adjust the `<link>`/`<script>` URLs.
- Leaflet's `imageOverlay` reprojects on-the-fly between the source
  WGS-84 coordinates and the basemap's Web Mercator projection -- the
  alignment is correct but the overlay stretches slightly toward the
  poles, matching every other lat/lon raster in a slippy map.
- For a more polished UX you can swap the OSM tile layer for any other
  basemap (Mapbox, Esri World Imagery, Carto Voyager, ...). One line.
- This viewer reads the `.geo` sidecar, not the GeoTIFF. Loading
  GeoTIFF directly in the browser is possible via
  [`leaflet-geotiff-2`](https://github.com/danwild/leaflet-geotiff)
  or [`georaster-layer-for-leaflet`](https://github.com/GeoTIFF/georaster-layer-for-leaflet)
  if you'd rather skip the sidecar.
