/* chimera_core.h - what the two halves of the glue share (chimera_core.c,
 * chimera_core.go). The controls are in waterbox.config's order. */
#ifndef CHIMERA_CORE_H
#define CHIMERA_CORE_H

#include <stdint.h>

/* the largest picture: waterbox.config's video capacity */
#define CHIMERA_MAX_W 1920
#define CHIMERA_MAX_H 1080
/* sound: 44100 Hz stereo; the most one frame holds (the lowest frame rate is 1) */
#define CHIMERA_RATE 44100
#define CHIMERA_MAX_SAMPLES 44100

/* four players of fourteen buttons each, then Escape */
#define CHIMERA_PLAYERS 4
#define CHIMERA_PLAYER_BUTTONS 14
#define CHIMERA_BUTTONS (CHIMERA_PLAYERS * CHIMERA_PLAYER_BUTTONS + 1)
#define CHIMERA_AXES 1

int chimera_wait_start(void);
void chimera_failed(const char *why);
int chimera_setting_long(const char *key, long dflt);
int chimera_slot(const char *id, int index, char *out, int outsz);
int chimera_gl_make(int w, int h);
int chimera_gl_width(void);
int chimera_gl_height(void);
long long chimera_frame_end(const int16_t *samples, int frames);
void chimera_inputs(uint8_t *buttons, int32_t *axes);
void chimera_savedata_begin(int count);
void chimera_savedata_put(int index, char *name, void *data, long long size);

#endif
