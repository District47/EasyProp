# ---------------------------------------------------------------------------
# SPLAT! companion utilities.
#
# These are the original C programs from the legacy `utils/build` script.
# They are OFF by default (SPLAT_BUILD_UTILS) because they are older C and
# may still need Windows portability work; the core `splat` target is the
# Phase-1 deliverable.  srtm2sdf is linked against BZip2; fontdata needs zlib.
# ---------------------------------------------------------------------------

enable_language(C)

add_executable(citydecoder citydecoder.c)
add_executable(usgs2sdf    usgs2sdf.c)
add_executable(bearing     bearing.c)

add_executable(srtm2sdf    srtm2sdf.c)
target_link_libraries(srtm2sdf PRIVATE BZip2::BZip2)

# The original ships srtm2sdf-hd as a symlink to srtm2sdf; the program selects
# HD mode from its own argv[0] name. Build a second, identically-sourced binary.
add_executable(srtm2sdf-hd srtm2sdf.c)
target_link_libraries(srtm2sdf-hd PRIVATE BZip2::BZip2)
set_target_properties(srtm2sdf-hd PROPERTIES OUTPUT_NAME "srtm2sdf-hd")

if(ZLIB_FOUND)
  add_executable(fontdata fontdata.c)
  target_link_libraries(fontdata PRIVATE ZLIB::ZLIB)
endif()

if(MSVC)
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_WARNINGS)
endif()
