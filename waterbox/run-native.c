/* run-native.c - the native reference for the test scripts.
 *
 * Links the SAME Ikemen GO, glue and Mesa the guest build uses, compiled for
 * this computer (build-ikemen.sh native, setup-mesa.sh -n), with the
 * sandbox's own math functions (make-native-libm.sh), and drives the core's
 * calls directly. The work dir holds what the sandbox would see mounted: the
 * game's pack, the "slots" file naming it, and the "settings" JSON.
 *
 * usage: run-native <workdir> [gate-harness options]
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "gate-harness.h"

extern int Init(void);
extern const char *GetLoadError(void);
extern void SetButton(int32_t index, int32_t state);
extern void SetAxis(int32_t index, int32_t value);
extern void FrameAdvance(uint64_t packed);
extern uint32_t *GetVideoBgra(void);
extern int GetVideoWidth(void);
extern int GetVideoHeight(void);
extern int16_t *GetAudio(void);
extern int GetAudioSampleCount(void);
extern int InputWasRead(void);
extern void SetRenderingEnabled(int on);
extern int GetVsyncNumerator(void);
extern int GetVsyncDenominator(void);
extern uint64_t GetCycleCount(void);
extern int32_t GetSaveDataFileCount(void);
extern const char *GetSaveDataFileName(int32_t i);
extern int64_t GetSaveDataFileSize(int32_t i);
extern const uint8_t *GetSaveDataFileBuffer(int32_t i);

static void frame(void) { FrameAdvance(0); }
static const uint32_t *video(int *w, int *h)
{
	*w = GetVideoWidth();
	*h = GetVideoHeight();
	return GetVideoBgra();
}
static const int16_t *audio(int *n)
{
	*n = GetAudioSampleCount();
	return GetAudio();
}

int main(int argc, char **argv)
{
	if (argc < 2)
	{
		fprintf(stderr, "usage: run-native <workdir> [options]\n");
		return 2;
	}
	static struct gate_opts o;
	if (!gate_parse_opts(argc, argv, 2, &o))
		return 2;
	/* the sandbox's environment and nothing of this computer's: Mesa and
	 * LLVM read theirs (LP_NATIVE_VECTOR_WIDTH would change llvmpipe's code) */
	clearenv();
	setenv("WATERBOX", "1", 1);
	if (chdir(argv[1]) != 0)
	{
		perror(argv[1]);
		return 1;
	}

	struct gate_core c = {
		.init = Init,
		.load_error = GetLoadError,
		.set_button = SetButton,
		.set_axis = SetAxis,
		.frame = frame,
		.video = video,
		.audio = audio,
		.input_was_read = InputWasRead,
		.vsync_numerator = GetVsyncNumerator,
		.vsync_denominator = GetVsyncDenominator,
		.pre_frame = NULL,
		.set_rendering = SetRenderingEnabled,
		.clock = GetCycleCount,
		.savedata_count = GetSaveDataFileCount,
		.savedata_name = GetSaveDataFileName,
		.savedata_size = GetSaveDataFileSize,
		.savedata_buffer = GetSaveDataFileBuffer,
	};
	return gate_run(&c, &o);
}
