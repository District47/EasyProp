# ---------------------------------------------------------------------------
# SPLAT! companion utilities.
#
# Of the original five (srtm2sdf, usgs2sdf, citydecoder, bearing, fontdata),
# only `srtm2sdf` has been ported to Windows so far -- it's the one that's
# load-bearing for the new workflow (fetch SRTM hgt -> srtm2sdf -> splat).
# The other four still rely on POSIX-only constructs and only build for
# non-MSVC targets; turn SPLAT_BUILD_UTILS=ON to attempt them on Linux/Mac.
# ---------------------------------------------------------------------------

enable_language(C)

# --- srtm2sdf (ported; builds on MSVC + POSIX) ------------------------------
add_executable(srtm2sdf srtm2sdf.c)
target_link_libraries(srtm2sdf PRIVATE BZip2::BZip2)
target_include_directories(srtm2sdf PRIVATE "${CMAKE_SOURCE_DIR}/src")

# The HD variant is the same source compiled to a different binary name --
# the program checks its own argv[0] to decide IPPD=1200 vs 3600. Upstream
# achieves this with a symlink (which Windows can't reliably do); we ship
# two binaries instead.
add_executable(srtm2sdf-hd srtm2sdf.c)
target_link_libraries(srtm2sdf-hd PRIVATE BZip2::BZip2)
target_include_directories(srtm2sdf-hd PRIVATE "${CMAKE_SOURCE_DIR}/src")
set_target_properties(srtm2sdf-hd PROPERTIES OUTPUT_NAME "srtm2sdf-hd")

if(MSVC)
  foreach(_t srtm2sdf srtm2sdf-hd)
    target_compile_definitions(${_t} PRIVATE
      _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_WARNINGS)
  endforeach()
endif()

# --- Not-yet-ported (POSIX-only) -------------------------------------------
if(NOT MSVC)
  add_executable(citydecoder citydecoder.c)
  add_executable(usgs2sdf    usgs2sdf.c)
  add_executable(bearing     bearing.c)
  if(ZLIB_FOUND)
    add_executable(fontdata fontdata.c)
    target_link_libraries(fontdata PRIVATE ZLIB::ZLIB)
  endif()
endif()
