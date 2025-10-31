// Wrapper file to compile Clay termbox2 renderer and its dependencies
// This file should be compiled once to provide the renderer implementation

#define CLAY_IMPLEMENTATION
#include "clay.h"

#define TB_IMPL
#define TB_OPT_ATTR_W 32  // Required for truecolor support
#include "../termbox2/termbox2.h"

#define STB_IMAGE_IMPLEMENTATION
#include "../stb/stb_image.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "../stb/stb_image_resize2.h"

// Include the Clay termbox2 renderer implementation
#include "clay_renderer_termbox2.c"

// Wrapper function to initialize termbox (without setting text measurement)
void Clay_Termbox_Initialize_With_MeasureText(int color_mode, enum border_mode border_mode,
                                               enum border_chars border_chars, enum image_mode image_mode,
                                               bool transparency) {
    Clay_Termbox_Initialize(color_mode, border_mode, border_chars, image_mode, transparency);
}

// Function to set text measurement after Clay_Initialize is called
void Clay_Termbox_SetMeasureText(void) {
    Clay_SetMeasureTextFunction(Clay_Termbox_MeasureText, NULL);
}
