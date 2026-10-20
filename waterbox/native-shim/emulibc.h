/* emulibc.h - the NATIVE build's stand-in for miniBox's emulibc.h.
 *
 * The native reference compiles the same core as the sandbox does; outside
 * the sandbox there is nothing to seal or hide, so the memory kinds are
 * plain allocations and the section attributes are nothing. The guest build
 * never sees this file: its include path has miniBox's real emulibc first.
 */
#ifndef _EMULIBC_H
#define _EMULIBC_H

#include <stdlib.h>

#ifdef __cplusplus
#define ECL_EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))
#else
#define ECL_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif
#define ECL_ENTRY
#define ECL_SEALED
#define ECL_INVISIBLE

#ifdef __cplusplus
extern "C" {
#endif
static inline void *alloc_sealed(size_t size) { return calloc(size, 1); }
static inline void *alloc_invisible(size_t size) { return calloc(size, 1); }
static inline void *alloc_plain(size_t size) { return calloc(size, 1); }
#ifdef __cplusplus
}
#endif

#endif
