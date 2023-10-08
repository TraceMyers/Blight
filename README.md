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

## Support Detail

### Jpg Read
None

### Bmp Read
#### Included:
- most common compression flavors (RGB, RLE8, RLE4, BITFIELDS, ALPHABITFIELDS) in sub-flavors (color table, true color, run-length encoded) in all pixel shapes and sizes from 1 to 32 bits
- most common colorspaces (CalibratedRGB, WindowsColorSpace, sRGB)
#### Missing:
- compression flavors (JPEG, PNG, CMYK, CMKYRLE8, CMYKRLE4)
- profiles
- gamma correction

Some infrastructure is already in place to work with profiles and gamma, so 100% support is possible in the future.

### Tga Read
#### Included:
- all standard compression flavors (ColorMap, TrueColor, Greyscale, RleColorMap, RleTrueColor, RleGreyscale) in all pixel shapes and sizes from 8 to 32 bits.
#### Missing:
- returning special data like the postage stamp, and data in the extension area such as author comments
- usage of color correction data and gamma
 
### Png Read
None
