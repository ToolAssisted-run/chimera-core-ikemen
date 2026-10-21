// Music in a format none of Ikemen GO's decoders reads, decoded whole by the
// core's FFmpeg from a copy of the file in memory (chimera_music.go). Every
// frame of every packet is taken and the decoder is emptied at the end (a
// Musepack 8 packet holds several frames). The sound comes out as 16-bit
// samples at the file's own rate, one channel for a mono file (the Go side
// puts it on both sides at full level, as Ikemen GO's own decoders do), two
// for any other.
#include "chimera_music.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libswresample/swresample.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct memfile
{
	const unsigned char *data;
	int64_t size, pos;
};

static int mem_read(void *opaque, uint8_t *buf, int n)
{
	struct memfile *m = opaque;
	int64_t left = m->size - m->pos;
	if (left <= 0)
		return AVERROR_EOF;
	if (n > left)
		n = (int)left;
	memcpy(buf, m->data + m->pos, n);
	m->pos += n;
	return n;
}

static int64_t mem_seek(void *opaque, int64_t off, int whence)
{
	struct memfile *m = opaque;
	if (whence & AVSEEK_SIZE)
		return m->size;
	whence &= ~AVSEEK_FORCE;
	int64_t to = whence == SEEK_SET ? off : whence == SEEK_CUR ? m->pos + off : whence == SEEK_END ? m->size + off : -1;
	if (to < 0 || to > m->size)
		return -1;
	m->pos = to;
	return to;
}

struct out
{
	int16_t *s;
	long n, cap; // samples (of every channel)
};

static int push(struct out *o, const uint8_t *data, long n)
{
	if (o->n + n > o->cap)
	{
		long cap = o->cap ? o->cap * 2 : 1 << 20;
		while (cap < o->n + n)
			cap *= 2;
		int16_t *s = realloc(o->s, cap * sizeof *s);
		if (!s)
			return -1;
		o->s = s;
		o->cap = cap;
	}
	memcpy(o->s + o->n, data, n * sizeof *o->s);
	o->n += n;
	return 0;
}

// a frame converted and appended; with none, what the converter still holds
static int take(SwrContext *swr, AVFrame *fr, int channels, struct out *o)
{
	uint8_t *buf = NULL;
	int max = swr_get_out_samples(swr, fr ? fr->nb_samples : 0);
	if (max <= 0)
		return 0;
	if (av_samples_alloc(&buf, NULL, channels, max, AV_SAMPLE_FMT_S16, 0) < 0)
		return -1;
	int got = swr_convert(swr, &buf, max, fr ? (const uint8_t **)fr->extended_data : NULL, fr ? fr->nb_samples : 0);
	int r = got < 0 ? -1 : push(o, buf, (long)got * channels);
	av_freep(&buf);
	return r;
}

int chimera_music_decode(const void *data, long size, struct chimera_music *out)
{
	memset(out, 0, sizeof *out);
	struct memfile m = {data, size, 0};
	AVFormatContext *fmt = NULL;
	AVIOContext *io = NULL;
	AVCodecContext *dec = NULL;
	SwrContext *swr = NULL;
	AVPacket *pkt = av_packet_alloc();
	AVFrame *fr = av_frame_alloc();
	struct out o = {0};
	unsigned char *iobuf = av_malloc(1 << 16);
	int st = -1, r = -1, channels = 0;
	AVChannelLayout layout = {0};
#define FAIL(...) do { snprintf(out->error, sizeof out->error, __VA_ARGS__); goto done; } while (0)
	if (!pkt || !fr || !iobuf)
		FAIL("out of memory");
	io = avio_alloc_context(iobuf, 1 << 16, 0, &m, mem_read, NULL, mem_seek);
	fmt = avformat_alloc_context();
	if (!io || !fmt)
		FAIL("out of memory");
	iobuf = NULL; // the context's now
	fmt->pb = io;
	if (avformat_open_input(&fmt, NULL, NULL, NULL) < 0)
		FAIL("FFmpeg does not know the file's format");
	if (avformat_find_stream_info(fmt, NULL) < 0)
		FAIL("FFmpeg cannot read the file's streams");
	st = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
	if (st < 0)
		FAIL("FFmpeg finds no sound in it");
	const AVCodec *codec = avcodec_find_decoder(fmt->streams[st]->codecpar->codec_id);
	if (!codec)
		FAIL("the core's FFmpeg has no decoder for its sound (%s)", avcodec_get_name(fmt->streams[st]->codecpar->codec_id));
	dec = avcodec_alloc_context3(codec);
	if (!dec || avcodec_parameters_to_context(dec, fmt->streams[st]->codecpar) < 0 || avcodec_open2(dec, codec, NULL) < 0)
		FAIL("FFmpeg cannot open its decoder");
	channels = dec->ch_layout.nb_channels == 1 ? 1 : 2;
	av_channel_layout_default(&layout, channels);
	if (swr_alloc_set_opts2(&swr, &layout, AV_SAMPLE_FMT_S16, dec->sample_rate, &dec->ch_layout, dec->sample_fmt,
		dec->sample_rate, 0, NULL) < 0 || swr_init(swr) < 0)
		FAIL("FFmpeg cannot convert its sound");
	int eof = 0;
	while (!eof)
	{
		int e = av_read_frame(fmt, pkt);
		if (e < 0)
			eof = 1; // then the decoder is emptied
		else if (pkt->stream_index != st)
		{
			av_packet_unref(pkt);
			continue;
		}
		e = avcodec_send_packet(dec, eof ? NULL : pkt);
		av_packet_unref(pkt);
		if (e < 0 && e != AVERROR_EOF)
			FAIL("FFmpeg's decoder refused a packet (%d)", e);
		while ((e = avcodec_receive_frame(dec, fr)) >= 0)
		{
			if (take(swr, fr, channels, &o) < 0)
				FAIL("out of memory");
			av_frame_unref(fr);
		}
		if (e != AVERROR(EAGAIN) && e != AVERROR_EOF)
			FAIL("FFmpeg's decoder failed (%d)", e);
	}
	if (take(swr, NULL, channels, &o) < 0)
		FAIL("out of memory");
	if (o.n == 0)
		FAIL("FFmpeg decodes no sound from it");
	out->samples = o.s;
	out->frames = o.n / channels;
	out->channels = channels;
	out->rate = dec->sample_rate;
	o.s = NULL;
	r = 0;
done:
	free(o.s);
	av_channel_layout_uninit(&layout);
	swr_free(&swr);
	avcodec_free_context(&dec);
	if (fmt)
		avformat_close_input(&fmt); // frees fmt, not its pb
	if (io)
	{
		av_freep(&io->buffer);
		avio_context_free(&io);
	}
	av_free(iobuf);
	av_frame_free(&fr);
	av_packet_free(&pkt);
	return r;
#undef FAIL
}

void chimera_music_free(struct chimera_music *m)
{
	free(m->samples);
	m->samples = NULL;
}
