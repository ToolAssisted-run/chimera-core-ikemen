/* chimera_core.c - the calls Chimera makes to the core, and the C half of
 * the glue between them and Ikemen GO (chimera_core.go is the Go half).
 *
 * Ikemen GO runs its own loops, on a thread of its own (a goroutine locked to
 * one), and ends every frame by swapping the window's buffers. The swap is
 * the frame's end here: the Go half mixes the frame's sound and calls
 * chimera_frame_end, which takes the picture and waits until Chimera asks for
 * the next frame. FrameAdvance hands the frame over and waits for that end.
 * So no Go code runs on the thread Chimera calls the core on.
 *
 * The picture is drawn by Mesa's llvmpipe behind OSMesa, into a buffer of the
 * core's own, in BGRA with the top row first: that buffer is the picture.
 */
#include <GL/gl.h>
#include <GL/osmesa.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include "chimera_core.h"

#ifdef CHIMERA_GUEST
/* machine spec v3: the sandbox's own clock and timed waits, which the Go
 * runtime's scheduler and timers use */
__attribute__((visibility("default"))) __attribute__((used)) const uint32_t __wbx_machine_spec = 3;
#endif

/* ---- the machine --------------------------------------------------------- */

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;

static int started;          /* Init handed Ikemen GO its start */
static int failed;           /* Ikemen GO stopped; load_error says why */
static long long asked = -1; /* the frame Chimera asked for */
static long long ended = -1; /* the last frame Ikemen GO finished */
static char load_error[1024];

static int fps = 60;
static uint8_t buttons[CHIMERA_BUTTONS];
static int32_t axes[CHIMERA_AXES];
static int rendering = 1;

static OSMesaContext gl_ctx;
static uint32_t *gl_buffer; /* what Mesa draws into, w x h */
static int gl_w, gl_h;
static uint32_t picture[CHIMERA_MAX_W * CHIMERA_MAX_H];
static int pic_w, pic_h;

static int16_t sound[CHIMERA_MAX_SAMPLES * 2];
static int sound_frames;

/* ---- called from Go -------------------------------------------------------- */

int chimera_wait_start(void)
{
	pthread_mutex_lock(&mu);
	while (!started)
		pthread_cond_wait(&cv, &mu);
	pthread_mutex_unlock(&mu);
	return fps;
}

void chimera_failed(const char *why)
{
	pthread_mutex_lock(&mu);
	if (!failed) {
		snprintf(load_error, sizeof load_error, "%s", why);
		failed = 1;
	}
	pthread_cond_broadcast(&cv);
	pthread_mutex_unlock(&mu);
	/* this thread has nothing more to do: it waits for ever */
	pthread_mutex_lock(&mu);
	for (;;)
		pthread_cond_wait(&cv, &mu);
}

int chimera_setting_long(const char *key, long dflt)
{
	return (int)wbx_setting_long(key, dflt);
}

int chimera_slot(const char *id, int index, char *out, int outsz)
{
	return wbx_slot_name(id, index, out, outsz) != NULL;
}

int chimera_gl_make(int w, int h)
{
	if (w < 1 || h < 1 || w > CHIMERA_MAX_W || h > CHIMERA_MAX_H)
		return -1;
	const int attribs[] = {
		OSMESA_FORMAT, OSMESA_BGRA,
		OSMESA_DEPTH_BITS, 24,
		OSMESA_STENCIL_BITS, 8,
		OSMESA_PROFILE, OSMESA_CORE_PROFILE,
		OSMESA_CONTEXT_MAJOR_VERSION, 3,
		OSMESA_CONTEXT_MINOR_VERSION, 3,
		0,
	};
	gl_ctx = OSMesaCreateContextAttribs(attribs, NULL);
	if (!gl_ctx)
		return -2;
	gl_buffer = calloc((size_t)w * h, 4);
	if (!gl_buffer || !OSMesaMakeCurrent(gl_ctx, gl_buffer, GL_UNSIGNED_BYTE, w, h))
		return -3;
	/* the top row first, as Chimera's picture is */
	OSMesaPixelStore(OSMESA_Y_UP, 0);
	gl_w = w;
	gl_h = h;
	return 0;
}

int chimera_gl_width(void) { return gl_w; }
int chimera_gl_height(void) { return gl_h; }

/* go-gl finds OpenGL's functions through GLX's lookup; here it is OSMesa's */
void *glXGetProcAddressARB(const unsigned char *name)
{
	return (void *)OSMesaGetProcAddress((const char *)name);
}

void *glXGetProcAddress(const unsigned char *name)
{
	return glXGetProcAddressARB(name);
}

long long chimera_frame_end(const int16_t *samples, int frames)
{
	if (gl_ctx) {
		glFinish();
		if (rendering) {
			const size_t n = (size_t)gl_w * gl_h;
			for (size_t i = 0; i < n; i++)
				picture[i] = gl_buffer[i] | 0xff000000u;
			pic_w = gl_w;
			pic_h = gl_h;
		}
	}
	if (frames > CHIMERA_MAX_SAMPLES)
		frames = CHIMERA_MAX_SAMPLES;
	if (frames > 0)
		memcpy(sound, samples, (size_t)frames * 4);
	sound_frames = frames > 0 ? frames : 0;

	pthread_mutex_lock(&mu);
	ended = asked;
	pthread_cond_broadcast(&cv);
	while (asked == ended)
		pthread_cond_wait(&cv, &mu);
	const long long next = asked;
	pthread_mutex_unlock(&mu);
	return next;
}

void chimera_inputs(uint8_t *b, int32_t *a)
{
	memcpy(b, buttons, sizeof buttons);
	memcpy(a, axes, sizeof axes);
}

/* the files the game wrote: names and bytes, C's copies (Go publishes them
 * when they change) */
struct saved { char *name; void *data; long long size; };
static struct saved *saves;
static int nsaves;

void chimera_savedata_begin(int count)
{
	for (int i = 0; i < nsaves; i++) {
		free(saves[i].name);
		free(saves[i].data);
	}
	free(saves);
	saves = count > 0 ? calloc((size_t)count, sizeof *saves) : NULL;
	nsaves = saves ? count : 0;
}

void chimera_savedata_put(int index, char *name, void *data, long long size)
{
	if (index < 0 || index >= nsaves) {
		free(name);
		free(data);
		return;
	}
	saves[index].name = name;
	saves[index].data = data;
	saves[index].size = size;
}

/* ---- Chimera's calls ------------------------------------------------------- */

ECL_EXPORT const char *GetLoadError(void)
{
	return load_error;
}

ECL_EXPORT int Init(void)
{
	long rate = wbx_setting_long("frameRate", 60);
	fps = rate >= 1 && rate <= 1000 ? (int)rate : 60;
	pthread_mutex_lock(&mu);
	started = 1;
	/* the first frame is Ikemen GO's start, up to its first picture */
	asked = 0;
	pthread_cond_broadcast(&cv);
	while (ended < 0 && !failed)
		pthread_cond_wait(&cv, &mu);
	const int ok = !failed;
	pthread_mutex_unlock(&mu);
	return ok;
}

ECL_EXPORT void SetButton(int32_t index, int32_t state)
{
	if (index >= 0 && index < CHIMERA_BUTTONS)
		buttons[index] = state ? 1 : 0;
}

ECL_EXPORT void SetAxis(int32_t index, int32_t value)
{
	if (index >= 0 && index < CHIMERA_AXES)
		axes[index] = value;
}

ECL_EXPORT void SetRenderingEnabled(int on)
{
	rendering = on != 0;
}

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	(void)packed;
	pthread_mutex_lock(&mu);
	if (failed || ended < 0) {
		pthread_mutex_unlock(&mu);
		return;
	}
	pthread_mutex_unlock(&mu);
#ifdef CHIMERA_GUEST
	/* a frame of the machine's time passes, where the Go runtime's timers and
	 * scheduler see it */
	struct timespec t = { 0, 1000000000L / fps };
	nanosleep(&t, NULL);
#endif
	pthread_mutex_lock(&mu);
	asked = ended + 1;
	pthread_cond_broadcast(&cv);
	while (ended != asked && !failed)
		pthread_cond_wait(&cv, &mu);
	pthread_mutex_unlock(&mu);
}

ECL_EXPORT uint32_t *GetVideoBgra(void) { return picture; }
ECL_EXPORT int GetVideoWidth(void) { return pic_w; }
ECL_EXPORT int GetVideoHeight(void) { return pic_h; }
ECL_EXPORT int16_t *GetAudio(void) { return sound; }
ECL_EXPORT int GetAudioSampleCount(void) { return sound_frames; }
ECL_EXPORT int GetVsyncNumerator(void) { return fps; }
ECL_EXPORT int GetVsyncDenominator(void) { return 1; }

/* Ikemen GO reads its controls every frame. */
ECL_EXPORT int InputWasRead(void) { return 1; }

/* The machine's clock, in frames. */
ECL_EXPORT uint64_t GetCycleCount(void) { return ended < 0 ? 0 : (uint64_t)ended; }

/* Emulator > Export Save Data: every file the game wrote, by its path in the
 * game's folder (save/config.ini, save/stats.json...) */
ECL_EXPORT int32_t GetSaveDataFileCount(void) { return nsaves; }

ECL_EXPORT const char *GetSaveDataFileName(int32_t i)
{
	return i >= 0 && i < nsaves ? saves[i].name : "";
}

ECL_EXPORT int64_t GetSaveDataFileSize(int32_t i)
{
	return i >= 0 && i < nsaves ? saves[i].size : 0;
}

ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t i)
{
	return i >= 0 && i < nsaves ? (const uint8_t *)saves[i].data : NULL;
}
