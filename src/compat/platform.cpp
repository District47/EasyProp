/****************************************************************************
*  compat/platform.cpp  --  Implementation of the SPLAT! portability shims. *
\****************************************************************************/

#include "compat/platform.h"

#include <string.h>

#if defined(_WIN32)

#include <windows.h>

FILE *splat_tmpfile(char *path, size_t path_len)
{
	char dir[MAX_PATH];
	char name[MAX_PATH];
	DWORD len;

	if (path == NULL || path_len == 0)
		return NULL;

	/* Locate the system temp directory (honours TMP/TEMP env vars). */
	len = GetTempPathA((DWORD)sizeof(dir), dir);
	if (len == 0 || len > sizeof(dir))
		return NULL;

	/* GetTempFileNameA creates a unique, empty file and returns its path. */
	if (GetTempFileNameA(dir, "spl", 0, name) == 0)
		return NULL;

	if (strlen(name) + 1 > path_len)
		return NULL;

	strcpy(path, name);

	/* Reopen via stdio ("w" truncates the just-created empty file) so the
	   caller can fprintf to it and later reopen it by name, exactly as the
	   original mkstemp()+fopen() flow did. */
	return fopen(path, "w");
}

#else  /* POSIX */

#include <stdlib.h>

FILE *splat_tmpfile(char *path, size_t path_len)
{
	const char *tmpdir;
	char templ[1024];
	int  wrote, fd;

	if (path == NULL || path_len == 0)
		return NULL;

	tmpdir = getenv("TMPDIR");
	if (tmpdir == NULL || tmpdir[0] == '\0')
		tmpdir = "/tmp";

	wrote = snprintf(templ, sizeof(templ), "%s/splatXXXXXX", tmpdir);
	if (wrote < 0 || (size_t)wrote >= sizeof(templ) || (size_t)wrote + 1 > path_len)
		return NULL;

	fd = mkstemp(templ);
	if (fd < 0)
		return NULL;

	close(fd);  /* reopen via stdio to match the original fopen-by-name flow */
	strcpy(path, templ);

	return fopen(path, "w");
}

#endif
