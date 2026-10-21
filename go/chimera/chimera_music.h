// chimera_music.c: music in a format none of Ikemen GO's decoders reads,
// decoded whole by the core's FFmpeg.
#ifndef CHIMERA_MUSIC_H
#define CHIMERA_MUSIC_H

#include <stdint.h>

struct chimera_music
{
	int16_t *samples; // interleaved; malloc'd, chimera_music_free frees it
	long frames;      // samples of each channel
	int channels;     // 1 or 2
	int rate;
	char error[160];
};

// 0, and *out filled; or -1, and out->error says why
int chimera_music_decode(const void *data, long size, struct chimera_music *out);
void chimera_music_free(struct chimera_music *m);

#endif
