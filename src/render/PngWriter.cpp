/****************************************************************************
*  render/PngWriter.cpp  --  PNG output for SPLAT! map images.              *
*                                                                           *
*  Wraps the vendored single-header stb_image_write library (public domain, *
*  https://github.com/nothings/stb). One TU defines the implementation; all *
*  other users include only render/Image.h.                                 *
\****************************************************************************/

#include "render/Image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "third_party/stb_image_write.h"

namespace render {

bool write_png(const Image& img, const char* path) {
    /* 3 = RGB channels; stride = width * 3 bytes (tightly packed). */
    const int rc = stbi_write_png(
        path,
        static_cast<int>(img.width()),
        static_cast<int>(img.height()),
        3,
        img.data(),
        static_cast<int>(img.width()) * 3);
    return rc != 0;
}

}  // namespace render
