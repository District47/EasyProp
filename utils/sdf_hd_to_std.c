/****************************************************************************
 * sdf_hd_to_std -- downsample a SPLAT! HD .sdf (1 arc-sec, 3600x3600) into
 *                  a standard-resolution .sdf (3 arc-sec, 1200x1200) by
 *                  averaging 3x3 blocks of HD elevation samples.
 *
 * Lets a pre-cached HD tile library be reused by standard splat (the "draft"
 * binary in our Phase 14 viewer toggle) without re-downloading the original
 * .hgt files. ~5x faster than re-fetching, since the on-disk HD .sdf is
 * already local and we only do one read + one write.
 *
 * SDF format (see utils/srtm2sdf.c WriteSDF and src/splat.cpp LoadSDF_SDF):
 *
 *   line 1: max_west   (integer degrees, west-positive)
 *   line 2: min_north  (integer degrees)
 *   line 3: min_west   (integer degrees)
 *   line 4: max_north  (integer degrees)
 *   then ippd*ippd elevation samples (one short int per line),
 *   emitted in   "for y = ippd .. 1, for x = mpi .. 0"   descending order.
 *
 * For HD: ippd=3600, mpi=3599, total data lines = 12,960,000.
 * For STD: ippd=1200, mpi=1199, total data lines = 1,440,000.
 *
 * The 4 header lines are copied verbatim -- the tile's geographic extent is
 * unchanged, only the sample density drops 3x in each direction.
 *
 * Usage: sdf_hd_to_std <input-hd.sdf> <output.sdf>
 ****************************************************************************/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HD_IPPD   3600
#define STD_IPPD  1200

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <input-hd.sdf> <output.sdf>\n", argv[0]);
        return 1;
    }
    const char *inpath  = argv[1];
    const char *outpath = argv[2];

    FILE *in = fopen(inpath, "r");
    if (!in) { perror(inpath); return 2; }
    FILE *out = fopen(outpath, "w");
    if (!out) { perror(outpath); fclose(in); return 2; }

    /* Copy 4 header lines verbatim. */
    char line[64];
    for (int i = 0; i < 4; i++) {
        if (!fgets(line, sizeof(line), in)) {
            fprintf(stderr, "%s: header truncated at line %d\n", inpath, i + 1);
            fclose(in); fclose(out); return 3;
        }
        fputs(line, out);
    }

    /* Load all HD samples into a (HD_IPPD+1) x HD_IPPD short buffer,
     * indexed [y][x] with y in [1..HD_IPPD] and x in [0..HD_IPPD-1] to
     * match srtm2sdf.c's geographic-y / 0-based-x convention. The +1 row
     * is just to keep the indexing 1-based on y without arithmetic. */
    short *hd = (short *)malloc((size_t)(HD_IPPD + 1) * HD_IPPD * sizeof(short));
    if (!hd) {
        fprintf(stderr, "%s: out of memory (need %zu bytes)\n",
                inpath, (size_t)(HD_IPPD + 1) * HD_IPPD * sizeof(short));
        fclose(in); fclose(out); return 4;
    }
    memset(hd, 0, (size_t)(HD_IPPD + 1) * HD_IPPD * sizeof(short));

    /* Read in the writer's order:  for y = HD_IPPD .. 1, for x = HD_IPPD-1 .. 0 */
    for (int y = HD_IPPD; y >= 1; y--) {
        for (int x = HD_IPPD - 1; x >= 0; x--) {
            if (!fgets(line, sizeof(line), in)) {
                fprintf(stderr, "%s: data truncated at y=%d x=%d\n", inpath, y, x);
                free(hd); fclose(in); fclose(out); return 3;
            }
            hd[(size_t)y * HD_IPPD + x] = (short)atoi(line);
        }
    }
    fclose(in);

    /* Write standard SDF samples in the writer's order:
     *   for y_std = STD_IPPD .. 1, for x_std = STD_IPPD-1 .. 0
     * Each STD sample is the average of the 3x3 HD block:
     *   y_hd in [(y_std-1)*3 + 1 ... y_std*3]
     *   x_hd in [x_std*3 ... x_std*3 + 2] */
    for (int ys = STD_IPPD; ys >= 1; ys--) {
        int y_lo = (ys - 1) * 3 + 1;   /* inclusive */
        int y_hi = ys * 3;             /* inclusive */
        for (int xs = STD_IPPD - 1; xs >= 0; xs--) {
            int x_lo = xs * 3;
            int x_hi = xs * 3 + 2;
            long sum = 0;
            int  n   = 0;
            for (int y = y_lo; y <= y_hi; y++) {
                for (int x = x_lo; x <= x_hi; x++) {
                    if (y >= 1 && y <= HD_IPPD && x >= 0 && x < HD_IPPD) {
                        sum += hd[(size_t)y * HD_IPPD + x];
                        n++;
                    }
                }
            }
            int avg = (n > 0) ? (int)((sum + (n / 2)) / n) : 0;   /* nearest, not floor */
            fprintf(out, "%d\n", avg);
        }
    }

    free(hd);
    fclose(out);
    return 0;
}
