# Blight
A highly flexible image loading/saving library written in Zig.

When loading, translates all file formats to your choice of RGBA32, RGB16, R8, or R16. When saving, translates the memory formats to any of the supported file formats.

Also provides special in-memory image formats RGBA128F, RGBA128, R32F, and RG64F for use with compute shaders.

## Support Overview
| Format | Read   | Write  |
| :----: | :--:   | :---:  |
|  Jpg   |:tomato:|:tomato:|
|  Bmp   |:blush: |:tomato:|
|  Tga   |:blush: |:tomato:|
|  Png   |:tomato:|:tomato:|

More are planned!

## Getting Started

This library is on version 0.12.0-dev.789+e6590fea1. I will likely not be updating the version until 0.12 releases

1. Download this repository into your project.
2. Take a look at the types Image, PixelTag, PixelSlice, PixelContainer, ImageLoadOptions and glance over the various pixel formats, such as RGBA32, R8, etc... all in image/types.zig
3. Take a look at ImageFormat in utils/file.zig
4. import blight.zig and call blight.image.load() to load an image!

## Support Detail

### Jpg Read
None

### Bmp Read
#### Included:
- all Windows versions (V1 through V5). OS/2 versions *may* load.
- most common compression flavors (RGB, RLE8, RLE4, BITFIELDS, ALPHABITFIELDS) in sub-flavors (color table, true color, run-length encoded) in all pixel shapes and sizes from 1 to 32 bits
- most common colorspaces (CalibratedRGB, WindowsColorSpace, sRGB)
#### Missing:
- compression flavors (JPEG, PNG, CMYK, CMKYRLE8, CMYKRLE4)
- profiles
- gamma correction

Some infrastructure is already in place to work with profiles and gamma, so 100% support is possible in the future.

### Tga Read
#### Included:
- All versions (V1 and V2)
- all standard compression flavors (ColorMap, TrueColor, Greyscale, RleColorMap, RleTrueColor, RleGreyscale) in all pixel shapes and sizes from 8 to 32 bits.
#### Missing:
- returning special data like the postage stamp, and data in the extension area such as author comments
- usage of color correction data and gamma
 
### Png Read
None
