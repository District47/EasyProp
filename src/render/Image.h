/****************************************************************************
*  render/Image.h  --  Minimal RGB framebuffer used by SPLAT!'s map writers.*
*                                                                           *
*  The legacy WritePPM* functions stream raw P6 bytes directly to disk.     *
*  Modern formats (PNG, GeoTIFF) need the full pixel buffer in memory, so   *
*  this small class provides one. The PPM streaming path stays untouched    *
*  for behavior-preservation (and lower peak memory on HD maps).            *
\****************************************************************************/

#ifndef SPLAT_RENDER_IMAGE_H
#define SPLAT_RENDER_IMAGE_H

#include <cstddef>
#include <cstdint>
#include <vector>

namespace render {

struct Color { std::uint8_t r, g, b; };

class Image {
public:
    Image(unsigned w, unsigned h)
        : w_(w), h_(h), data_(static_cast<std::size_t>(w) * h * 3, 0) {}

    unsigned             width()  const { return w_; }
    unsigned             height() const { return h_; }
    const std::uint8_t*  data()   const { return data_.data(); }

    /* No bounds checking on the fast path -- callers loop over [0,w) x [0,h). */
    inline void set(unsigned x, unsigned y, Color c) {
        const std::size_t i = (static_cast<std::size_t>(y) * w_ + x) * 3;
        data_[i]     = c.r;
        data_[i + 1] = c.g;
        data_[i + 2] = c.b;
    }

private:
    unsigned                  w_;
    unsigned                  h_;
    std::vector<std::uint8_t> data_;
};

/* Writers ---------------------------------------------------------------- */

/* Write `img` to `path` as an 8-bit RGB PNG.  Returns true on success. */
bool write_png(const Image& img, const char* path);

}  // namespace render

#endif  // SPLAT_RENDER_IMAGE_H
