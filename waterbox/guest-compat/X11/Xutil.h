/* X11/Xutil.h for the sandbox build (see Xlib.h beside it). */
#ifndef CHIMERA_X11_XUTIL_H
#define CHIMERA_X11_XUTIL_H
#include <X11/Xlib.h>
typedef struct {
	Visual *visual;
	unsigned long visualid;
	int screen, depth, c_class;
	unsigned long red_mask, green_mask, blue_mask;
	int colormap_size, bits_per_rgb;
} XVisualInfo;
#endif
