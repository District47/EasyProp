/****************************************************************************
*  render/GeoTiffWriter.cpp  --  GeoTIFF output for SPLAT! map images.      *
*                                                                           *
*  Uses libtiff to write an 8-bit RGB TIFF, with the GeoTIFF tag set        *
*  computed by hand (no libgeotiff dependency required).  The output is a   *
*  WGS84 (EPSG:4326) geographic raster -- the same coordinate system the    *
*  legacy `.geo` sidecar describes -- with the image's top-left pixel       *
*  tiepointed to (west, north) and pixel scale set from the bounds extent.  *
*  Any GIS reader (QGIS, ArcGIS, GDAL, GeoTIFF.js, leaflet-geotiff, ...)    *
*  will load these files correctly georeferenced.                           *
\****************************************************************************/

#include "render/Image.h"

#include <tiffio.h>

#include <cstdarg>
#include <cstdio>
#include <vector>

namespace render {

/* ---- GeoTIFF tag numbers (from the GeoTIFF 1.1 spec) ------------------- */
#define TIFFTAG_GEOPIXELSCALE   33550
#define TIFFTAG_GEOTIEPOINTS    33922
#define TIFFTAG_GEOKEYDIRECTORY 34735

/* ---- GeoKey IDs we set ------------------------------------------------- */
#define KEY_GTModelType        1024  /* 2 = ModelTypeGeographic                */
#define KEY_GTRasterType       1025  /* 1 = RasterPixelIsArea                  */
#define KEY_GeographicType     2048  /* 4326 = GCS_WGS_84                      */

/* libtiff doesn't ship these tag definitions out of the box (they belong to
   libgeotiff). Register them as TIFFField extras so TIFFSetField accepts the
   tag numbers and emits the correct types and counts.

   All three are declared TIFF_VARIABLE (-1) with passcount=1, so every
   TIFFSetField call below is uniform: pass a (uint16_t)count followed by
   the data pointer. (Using a fixed writecount of 3 for GeoPixelScale would
   make TIFFSetField take just the pointer with no count, which silently
   mis-parses the varargs and the file ends up with no IFD written.) */
static const TIFFFieldInfo s_geotiff_extra_fields[] = {
    { TIFFTAG_GEOPIXELSCALE,   -1,-1, TIFF_DOUBLE, FIELD_CUSTOM, 1, 1,
      const_cast<char*>("GeoPixelScale")     },
    { TIFFTAG_GEOTIEPOINTS,    -1,-1, TIFF_DOUBLE, FIELD_CUSTOM, 1, 1,
      const_cast<char*>("GeoTiePoints")      },
    { TIFFTAG_GEOKEYDIRECTORY, -1,-1, TIFF_SHORT,  FIELD_CUSTOM, 1, 1,
      const_cast<char*>("GeoKeyDirectory")   },
};

static void register_geotiff_extras(TIFF* tif) {
    /* TIFFMergeFieldInfo is idempotent across handles -- safe to call once
       per open file. */
    TIFFMergeFieldInfo(tif, s_geotiff_extra_fields,
                       sizeof(s_geotiff_extra_fields) / sizeof(s_geotiff_extra_fields[0]));
}

/* Surface libtiff diagnostics to stderr -- without this, silent failures
   inside TIFFSetField / TIFFWriteScanline are easy to misdiagnose
   (we'd see a half-written file with no error). */
static void splat_tiff_error(const char* module, const char* fmt, va_list ap) {
    std::fprintf(stderr, "*** libtiff error [%s]: ", module ? module : "(none)");
    std::vfprintf(stderr, fmt, ap);
    std::fprintf(stderr, "\n");
}
static void splat_tiff_warning(const char* module, const char* fmt, va_list ap) {
    std::fprintf(stderr, "*** libtiff warning [%s]: ", module ? module : "(none)");
    std::vfprintf(stderr, fmt, ap);
    std::fprintf(stderr, "\n");
}
static void install_tiff_handlers_once() {
    static bool installed = false;
    if (!installed) {
        TIFFSetErrorHandler(splat_tiff_error);
        TIFFSetWarningHandler(splat_tiff_warning);
        installed = true;
    }
}

bool write_geotiff(const Image& img, const char* path, const GeoBounds& bounds) {
    install_tiff_handlers_once();

    if (img.width() == 0 || img.height() == 0)
        return false;

    TIFF* tif = TIFFOpen(path, "w");
    if (!tif) {
        std::fprintf(stderr, "*** ERROR: TIFFOpen failed for \"%s\"\n", path);
        return false;
    }
    register_geotiff_extras(tif);

    const unsigned w = img.width();
    const unsigned h = img.height();

    /* --- Standard TIFF baseline ---------------------------------------- */
    TIFFSetField(tif, TIFFTAG_IMAGEWIDTH,      w);
    TIFFSetField(tif, TIFFTAG_IMAGELENGTH,     h);
    TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, 3);
    TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE,   8);
    TIFFSetField(tif, TIFFTAG_PHOTOMETRIC,     PHOTOMETRIC_RGB);
    TIFFSetField(tif, TIFFTAG_PLANARCONFIG,    PLANARCONFIG_CONTIG);
    TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP,    TIFFDefaultStripSize(tif, 0));
    TIFFSetField(tif, TIFFTAG_COMPRESSION,     COMPRESSION_LZW);

    /* --- GeoTIFF tiepoint + pixel scale -------------------------------- */
    /* Tiepoint: top-left pixel (0,0,0) -> (west, north, 0) in WGS84 deg. */
    const double tiepoint[6] = { 0.0, 0.0, 0.0, bounds.west, bounds.north, 0.0 };
    TIFFSetField(tif, TIFFTAG_GEOTIEPOINTS, (uint16_t)6, tiepoint);

    /* Pixel scale: degrees per pixel in X (lon) and Y (lat). Y is positive
       because GeoTIFF pixel-scale Y is unsigned; the negative orientation
       (Y grows southward) is implicit from the tiepoint at the top edge. */
    const double pixelW = (bounds.east  - bounds.west)  / static_cast<double>(w);
    const double pixelH = (bounds.north - bounds.south) / static_cast<double>(h);
    const double pixscale[3] = { pixelW, pixelH, 0.0 };
    TIFFSetField(tif, TIFFTAG_GEOPIXELSCALE, (uint16_t)3, pixscale);

    /* --- GeoKey directory: WGS84 lat/lon geographic CRS ---------------- */
    /* Header: (Version, KeyRev, MinorRev, NumberOfKeys=3) then 3 entries
       of 4 shorts each. */
    const uint16_t geokeys[16] = {
        1, 1, 0, 3,
        KEY_GTModelType,    0, 1, 2,     /* ModelTypeGeographic */
        KEY_GTRasterType,   0, 1, 1,     /* RasterPixelIsArea   */
        KEY_GeographicType, 0, 1, 4326   /* GCS_WGS_84          */
    };
    TIFFSetField(tif, TIFFTAG_GEOKEYDIRECTORY, (uint16_t)16, geokeys);

    /* --- Pixel data: write row by row ----------------------------------- */
    const uint8_t* pixels = img.data();
    for (unsigned y = 0; y < h; ++y) {
        /* TIFFWriteScanline takes a non-const pointer; cast is safe -- libtiff
           does not modify on PHOTOMETRIC_RGB / PLANARCONFIG_CONTIG output. */
        uint8_t* row = const_cast<uint8_t*>(pixels + static_cast<size_t>(y) * w * 3);
        if (TIFFWriteScanline(tif, row, y, 0) < 0) {
            std::fprintf(stderr, "*** ERROR: TIFFWriteScanline failed at row %u of \"%s\"\n", y, path);
            TIFFClose(tif);
            return false;
        }
    }

    TIFFClose(tif);
    return true;
}

}  // namespace render
