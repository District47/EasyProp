/****************************************************************************
*  compat/platform.h  --  Small cross-platform shims for SPLAT!.            *
*                                                                           *
*  SPLAT! was written for POSIX (Linux/Unix).  This header isolates the     *
*  handful of POSIX-only dependencies so the same sources build on Windows  *
*  (MSVC) as well.  It provides:                                            *
*    - <unistd.h> on POSIX, or the MSVC equivalents (<io.h>/<process.h>);   *
*    - unlink()  (mapped to _unlink on MSVC);                               *
*    - splat_tmpfile(), a portable replacement for mkstemp()+fopen().       *
\****************************************************************************/

#ifndef SPLAT_COMPAT_PLATFORM_H
#define SPLAT_COMPAT_PLATFORM_H

#include <stdio.h>
#include <stddef.h>

#if defined(_WIN32)
  #include <io.h>       /* _unlink, _access */
  #include <process.h>  /* _getpid          */
  #ifndef unlink
    #define unlink _unlink
  #endif
  /* The legacy SDF tile naming convention uses ':' as the field separator
     (e.g. "40:41:74:75.sdf"), but ':' is illegal in Windows filenames -- NTFS
     parses "name:stream" as an alternate-data-stream reference. Substitute
     '_' on Windows so terrain tiles can be created, named, and loaded
     normally. Tiles generated on a Unix host (':' names) won't be usable
     on Windows; regenerate them on the Windows side. */
  #define SDF_SEP "_"
#else
  #include <unistd.h>   /* unlink, getpid, mkstemp, ...                    */
  #define SDF_SEP ":"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Create a brand-new unique temporary file, open it for writing ("w"), and
 * write its full path into `path` (a caller-supplied buffer of `path_len`
 * bytes).  Returns the open FILE* (the caller is responsible for fclose and,
 * when finished, unlink(path)), or NULL on failure.
 *
 * Portable stand-in for the original "mkstemp(\"/tmp/XXXXXX\") + fopen()"
 * idiom, which does not exist on Windows and hard-codes the /tmp directory.
 */
FILE *splat_tmpfile(char *path, size_t path_len);

#ifdef __cplusplus
}
#endif

#endif /* SPLAT_COMPAT_PLATFORM_H */
