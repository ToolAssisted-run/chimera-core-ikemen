/* X11/Xlib.h for the sandbox build: the few X types Mesa's GL/glx.h names.
 * go-gl includes glx.h only to find OpenGL's functions through
 * glXGetProcAddress, which the core answers itself (chimera_core.c) with
 * OSMesa's lookup; nothing of X is ever called. */
#ifndef CHIMERA_X11_XLIB_H
#define CHIMERA_X11_XLIB_H
typedef unsigned long XID;
typedef XID Window;
typedef XID Drawable;
typedef XID Pixmap;
typedef XID Font;
typedef XID Colormap;
typedef int Bool;
typedef int Status;
typedef struct _XDisplay Display;
typedef struct _Visual Visual;
#endif
