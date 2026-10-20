/* gate-harness.h - the shared half of run-native.c and run-wbx.c.
 *
 * One replay-and-digest loop over an abstract core interface, so the native
 * reference and the sandboxed core run EXACTLY the same schedule and are
 * digested the same way: every step's picture, sound, length and lag, and
 * the core's clock.
 *
 * Input is a movie: one line per step naming what is held on that step, by
 * the tokens of input-names.h (the button names of waterbox.config without
 * spaces: "Space", "KeyA"... no: "KeyA" is "Key A" without the space), and
 * axes as token=value ("mx=1000"). An axis keeps its value until a line
 * changes it, as a mouse stays where it was put. A line starting with # is a
 * comment. --movie-at puts the movie's first line at a given step; --press
 * AT:TOKENS:LEN holds comma-separated tokens for LEN steps from step AT.
 *
 * GATE_STALL_US=<n> in the environment makes the harness wait n microseconds
 * of the computer's time before every step: the machine must not notice.
 */
#ifndef GATE_HARNESS_H
#define GATE_HARNESS_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "input-names.h"

struct gate_core
{
	int (*init)(void);
	const char *(*load_error)(void);
	void (*set_button)(int32_t index, int32_t state);
	void (*set_axis)(int32_t index, int32_t value);
	void (*frame)(void);
	const uint32_t *(*video)(int *w, int *h);
	const int16_t *(*audio)(int *n);
	int (*input_was_read)(void);
	int (*vsync_numerator)(void);
	int (*vsync_denominator)(void);
	void (*pre_frame)(long frame); /* optional (the rerecord and session legs) */
	void (*set_rendering)(int on);  /* optional (the turbo leg) */
	uint64_t (*clock)(void);
	/* optional (the save data legs): Emulator > Export Save Data's group */
	int32_t (*savedata_count)(void);
	const char *(*savedata_name)(int32_t i);
	int64_t (*savedata_size)(int32_t i);
	const uint8_t *(*savedata_buffer)(int32_t i);
};

#define GATE_MAX_PRESS 64
#define GATE_MAX_SHOTS 64

struct gate_press { long at, len; char tokens[256]; };
struct gate_shot { long at; const char *path; };

struct gate_opts
{
	long frames;
	const char *moviePath;
	long movieAt;
	struct gate_press press[GATE_MAX_PRESS];
	int npress;
	struct gate_shot shots[GATE_MAX_SHOTS];
	int nshots;
	const char *audioOut;
	const char *savedataOut; /* a folder: the exported save files, at the end */
	const char *framesOut;   /* per step: the step, the picture's size and digest */
	int turbo;
	long turboSettle;
};

static uint64_t gate_fnv(uint64_t h, const void *p, size_t n)
{
	const uint8_t *b = (const uint8_t *)p;
	if (!h) h = 1469598103934665603ULL;
	for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
	return h;
}

/* ------------------------------------------------------------ the movie */

static char **gate_movie;
static long gate_movie_len;

static int gate_load_movie(const char *path)
{
	FILE *f = fopen(path, "r");
	if (!f) { perror(path); return 0; }
	char line[4096];
	long cap = 0;
	while (fgets(line, sizeof line, f))
	{
		if (line[0] == '#') continue; /* a comment, not a step */
		if (gate_movie_len == cap)
		{
			cap = cap ? cap * 2 : 1024;
			gate_movie = (char **)realloc(gate_movie, (size_t)cap * sizeof *gate_movie);
		}
		gate_movie[gate_movie_len++] = strdup(line);
	}
	fclose(f);
	return 1;
}

/* the tokens of a line (spaces, commas or tabs between them) onto the
 * buttons held and the axes' values; 0 on a token nobody declared */
static int gate_apply_tokens(const char *line, uint8_t *buttons, int32_t *axes)
{
	char buf[4096];
	snprintf(buf, sizeof buf, "%s", line);
	for (char *tok = strtok(buf, " ,\t\r\n"); tok; tok = strtok(NULL, " ,\t\r\n"))
	{
		char *eq = strchr(tok, '=');
		int found = 0;
		if (eq)
		{
			*eq = 0;
			for (int a = 0; a < GATE_AXIS_COUNT; a++)
				if (!strcmp(tok, gate_axis_tokens[a])) { axes[a] = (int32_t)strtol(eq + 1, 0, 0); found = 1; }
		}
		else
		{
			for (int b = 0; b < GATE_BTN_COUNT; b++)
				if (!strcmp(tok, gate_button_tokens[b])) { buttons[b] = 1; found = 1; }
		}
		if (!found) { fprintf(stderr, "gate: no input is called %s\n", tok); return 0; }
	}
	return 1;
}

/* ------------------------------------------------------------ pictures */

static int gate_write_tga(const char *path, const uint32_t *bgra, int w, int h)
{
	FILE *f = fopen(path, "wb");
	if (!f) { perror(path); return 0; }
	uint8_t hdr[18] = { 0 };
	hdr[2] = 2;
	hdr[12] = (uint8_t)w; hdr[13] = (uint8_t)(w >> 8);
	hdr[14] = (uint8_t)h; hdr[15] = (uint8_t)(h >> 8);
	hdr[16] = 32; hdr[17] = 0x28; /* top-left origin, 8 alpha bits */
	fwrite(hdr, 1, sizeof hdr, f);
	fwrite(bgra, 4, (size_t)w * h, f);
	fclose(f);
	return 1;
}

/* ------------------------------------------------------------ the run */

static int gate_run(const struct gate_core *c, const struct gate_opts *o)
{
	if (c->init() != 1)
	{
		fprintf(stderr, "Init failed: %s\n", c->load_error ? c->load_error() : "?");
		printf("loadError=%s\n", c->load_error ? c->load_error() : "?");
		return 1;
	}
	if (o->moviePath && !gate_load_movie(o->moviePath))
		return 1;

	const long frames = o->frames;
	const long tail = frames / 2;
	const long hashFrom = tail + o->turboSettle;
	uint64_t vh = 0, th = 0, ah = 0, sh = 0;
	long lag = 0;
	uint8_t buttons[GATE_BTN_COUNT], prev[GATE_BTN_COUNT];
	int32_t axes[GATE_AXIS_COUNT], sent[GATE_AXIS_COUNT];
	memset(prev, 0, sizeof prev);
	for (int a = 0; a < GATE_AXIS_COUNT; a++)
		axes[a] = sent[a] = gate_axis_neutral[a];
	FILE *framesOut = o->framesOut ? fopen(o->framesOut, "w") : NULL;
	const char *stall = getenv("GATE_STALL_US");
	const long stallUs = stall ? strtol(stall, 0, 0) : 0;

	for (long f = 0; f < frames; f++)
	{
		memset(buttons, 0, sizeof buttons);
		if (o->moviePath && f >= o->movieAt && f - o->movieAt < gate_movie_len)
			if (!gate_apply_tokens(gate_movie[f - o->movieAt], buttons, axes))
				return 1;
		for (int i = 0; i < o->npress; i++)
			if (f >= o->press[i].at && f < o->press[i].at + o->press[i].len)
				if (!gate_apply_tokens(o->press[i].tokens, buttons, axes))
					return 1;

		if (o->turbo && c->set_rendering)
			c->set_rendering(f >= tail);
		if (c->pre_frame)
			c->pre_frame(f);

		for (int i = 0; i < GATE_BTN_COUNT; i++)
		{
			if (buttons[i] != prev[i])
				c->set_button(i, buttons[i]);
			prev[i] = buttons[i];
		}
		for (int a = 0; a < GATE_AXIS_COUNT; a++)
		{
			/* every step, as the frontend sets every axis before a frame */
			c->set_axis(a, axes[a]);
			sent[a] = axes[a];
		}

		if (stallUs > 0)
			usleep((useconds_t)stallUs);
		c->frame();

		int w = 0, h = 0, n = 0;
		const uint32_t *video = c->video(&w, &h);
		const int16_t *audio = c->audio(&n);
		const int num = c->vsync_numerator(), den = c->vsync_denominator();
		const int read = c->input_was_read();
		uint64_t one = gate_fnv(0, video, (size_t)w * h * 4);
		vh = gate_fnv(vh, &w, sizeof w);
		vh = gate_fnv(vh, &h, sizeof h);
		vh = gate_fnv(vh, video, (size_t)w * h * 4);
		if (f >= hashFrom)
		{
			th = gate_fnv(th, &w, sizeof w);
			th = gate_fnv(th, &h, sizeof h);
			th = gate_fnv(th, video, (size_t)w * h * 4);
		}
		ah = gate_fnv(ah, audio, (size_t)n * 2 * sizeof(int16_t));
		sh = gate_fnv(sh, &num, sizeof num);
		sh = gate_fnv(sh, &den, sizeof den);
		sh = gate_fnv(sh, &n, sizeof n);
		sh = gate_fnv(sh, &read, sizeof read);
		if (framesOut)
			fprintf(framesOut, "%ld %dx%d %016llx\n", f, w, h, (unsigned long long)one);
		if (o->audioOut)
		{
			FILE *af = fopen(o->audioOut, f == 0 ? "wb" : "ab");
			if (af) { fwrite(audio, 2 * sizeof(int16_t), (size_t)n, af); fclose(af); }
		}
		if (!read)
			lag++;
		for (int i = 0; i < o->nshots; i++)
			if (o->shots[i].at == f)
				gate_write_tga(o->shots[i].path, video, w, h);
	}
	if (framesOut) fclose(framesOut);
	(void)sent;

	printf("frames=%ld\n", frames);
	printf("vsync=%d/%d\n", c->vsync_numerator(), c->vsync_denominator());
	printf("videoHash=%016llx\n", (unsigned long long)vh);
	printf("tailVideoHash=%016llx\n", (unsigned long long)th);
	printf("audioHash=%016llx\n", (unsigned long long)ah);
	printf("stepsHash=%016llx\n", (unsigned long long)sh);
	printf("lagFrames=%ld\n", lag);
	printf("clock=%llu\n", (unsigned long long)c->clock());
	if (o->savedataOut && c->savedata_count)
	{
		const int32_t n = c->savedata_count();
		for (int32_t i = 0; i < n; i++)
		{
			char path[1024];
			snprintf(path, sizeof path, "%s/%s", o->savedataOut, c->savedata_name(i));
			/* a file in a folder of user:// gets its folders */
			for (char *slash = strchr(path + strlen(o->savedataOut) + 1, '/'); slash; slash = strchr(slash + 1, '/'))
			{
				*slash = 0;
				mkdir(path, 0755);
				*slash = '/';
			}
			FILE *sf = fopen(path, "wb");
			if (sf) { fwrite(c->savedata_buffer(i), 1, (size_t)c->savedata_size(i), sf); fclose(sf); }
			printf("savedata[%s]=%lld\n", c->savedata_name(i), (long long)c->savedata_size(i));
		}
	}
	return 0;
}

/* shared CLI parsing; 0 on a bad argument */
static int gate_parse_opts(int argc, char **argv, int first, struct gate_opts *o)
{
	memset(o, 0, sizeof *o);
	o->frames = 600;
	for (int i = first; i < argc; i++)
	{
		if (!strcmp(argv[i], "--frames") && i + 1 < argc) o->frames = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--movie") && i + 1 < argc) o->moviePath = argv[++i];
		else if (!strcmp(argv[i], "--movie-at") && i + 1 < argc) o->movieAt = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--press") && i + 1 < argc && o->npress < GATE_MAX_PRESS)
		{
			struct gate_press *p = &o->press[o->npress++];
			p->len = 1;
			if (sscanf(argv[++i], "%ld:%255[^:]:%ld", &p->at, p->tokens, &p->len) < 2) { fprintf(stderr, "bad --press %s\n", argv[i]); return 0; }
		}
		else if (!strcmp(argv[i], "--screenshot") && i + 1 < argc && o->nshots < GATE_MAX_SHOTS)
		{
			const char *arg = argv[++i];
			const char *colon = strchr(arg, ':');
			if (!colon) { fprintf(stderr, "bad --screenshot %s\n", arg); return 0; }
			o->shots[o->nshots].at = strtol(arg, 0, 0);
			o->shots[o->nshots].path = colon + 1;
			o->nshots++;
		}
		else if (!strcmp(argv[i], "--audio") && i + 1 < argc) o->audioOut = argv[++i];
		else if (!strcmp(argv[i], "--savedata-out") && i + 1 < argc) o->savedataOut = argv[++i];
		else if (!strcmp(argv[i], "--frames-out") && i + 1 < argc) o->framesOut = argv[++i];
		else if (!strcmp(argv[i], "--turbo")) o->turbo = 1;
		else if (!strcmp(argv[i], "--turbo-settle") && i + 1 < argc) o->turboSettle = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--rerecord") || !strcmp(argv[i], "--session")) ; /* run-wbx's */
		else if (!strcmp(argv[i], "--session-at") && i + 1 < argc) i++;                /* run-wbx's */
		else { fprintf(stderr, "unknown option %s\n", argv[i]); return 0; }
	}
	return 1;
}

#endif
