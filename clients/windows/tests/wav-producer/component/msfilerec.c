/*
 * Copyright (c) 2010-2022 Belledonne Communications SARL.
 *
 * This file is part of mediastreamer2
 * (see https://gitlab.linphone.org/BC/public/mediastreamer2).
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#include <bctoolbox/defs.h>
#include <limits.h>

#if defined(HAVE_CONFIG_H)
#include "mediastreamer-config.h"
#endif

#include "asyncrw.h"
#include "mediastreamer2/msfilerec.h"
#include "waveheader.h"
#include <bctoolbox/vfs.h>

#include "fixture_recorder.h"

#include "fd_portab.h" // keep this include at the last of the inclusion sequence!

static int rec_close(MSFilter *f, void *arg);
static int write_wav_header(bctbx_vfs_file_t *fp, int rate, int nchannels, int size);

typedef struct RecState {
	bctbx_vfs_file_t *fp;
	int rate;
	int nchannels;
	int size;
	int max_size;
	char *mime;
	MSAsyncWriter *writer;
	MSRecorderState state;
	bool_t swap;
	bool_t is_wav;
	int io_error;
} RecState;

static void rec_init(MSFilter *f) {
	RecState *s = ms_new0(RecState, 1);
	s->rate = 8000;
	s->nchannels = 1;
	s->size = 0;
	s->max_size = 0;
	s->state = MSRecorderClosed;
	s->mime = "pcm";
	s->swap = FALSE;
	s->is_wav = FALSE;
	f->data = s;
}

static int _rec_close(RecState *s);

/* Only the producer writes its own header. No captured file is repaired. */
static int rec_refresh_empty_wav(RecState *s) {
	if (s->fp && s->is_wav && s->size == 0) {
		if (write_wav_header(s->fp, s->rate, s->nchannels, 0) != 0) {
			s->io_error = -1; s->state = MSRecorderPaused; return -1;
		}
	}
	return 0;
}

static void swap_bytes(unsigned char *bytes, int len) {
	int i;
	unsigned char tmp;
	for (i = 0; i < len; i += 2) {
		tmp = bytes[i];
		bytes[i] = bytes[i + 1];
		bytes[i + 1] = tmp;
	}
}

static void rec_process(MSFilter *f) {
	RecState *s = (RecState *)f->data;
	mblk_t *m;

	ms_mutex_lock(&f->lock);
	while ((m = ms_queue_get(f->inputs[0])) != NULL) {

		if (s->state == MSRecorderRunning) {
			int len = (int)(m->b_wptr - m->b_rptr);
			int max_size_reached = 0;
			if (s->max_size != 0 && s->size + len > s->max_size) {
				len = s->max_size - s->size;
				max_size_reached = 1;
			}
			if (len < 0 || len > INT_MAX - s->size) {
				s->io_error = -1; freemsg(m); _rec_close(s); continue;
			}
			/* The queued bytes must equal the bytes counted, including a size limit. */
			m->b_wptr = m->b_rptr + len;
			if (s->swap) {
				if (dblk_ref_value(m->b_datap) != 1) {
					mblk_t *old = m;
					m = copymsg(m);
					freemsg(old);
				}
				swap_bytes(m->b_rptr, len);
			}
			ms_async_writer_write(s->writer, m);
			s->size += len;
			if (max_size_reached) {
				ms_warning("MSFileRec: Maximum size (%d) has been reached. closing file.", s->max_size);
				_rec_close(s);
				ms_filter_notify_no_arg(f, MS_RECORDER_MAX_SIZE_REACHED);
			}
		} else freemsg(m);
	}
	ms_mutex_unlock(&f->lock);
}

static int rec_get_length(const char *file, int *length, int *rate, int *channels) {
	wave_header_t header;
	bctbx_vfs_file_t *fp = bctbx_file_open2(bctbx_vfs_get_default(), file, O_RDONLY | O_BINARY);
	ssize_t bytes; int ret; uint32_t count, hz, nch;
	if (!fp) return -1;
	bytes = bctbx_file_size(fp);
	if (bytes == 0) { bctbx_file_close(fp); *length = 0; return 0; }
	ret = (int)bctbx_file_read2(fp, &header, sizeof(header));
	bctbx_file_close(fp);
	if (ret != (int)sizeof(header)) return -1;
	if (memcmp(header.riff_chunk.riff, "RIFF", 4) != 0 ||
	    memcmp(header.riff_chunk.wave, "WAVE", 4) != 0 ||
	    memcmp(header.format_chunk.fmt, "fmt ", 4) != 0 ||
	    le_uint32(header.format_chunk.len) != 16 ||
	    memcmp(header.data_chunk.data, "data", 4) != 0) return -1;
	count = le_uint32(header.data_chunk.len); hz = le_uint32(header.format_chunk.rate);
	nch = le_uint16(header.format_chunk.channel);
	/* This fixture producer appends only its canonical PCM16 WAVs. */
	if (count > INT_MAX || bytes != (ssize_t)sizeof(header) + count ||
	    le_uint32(header.riff_chunk.len) != count + sizeof(header) - 8 ||
	    le_uint16(header.format_chunk.type) != 1 || le_uint16(header.format_chunk.bitpspl) != 16 ||
	    hz == 0 || hz > INT_MAX || nch == 0 || nch > 32767 || hz > UINT_MAX / (2 * nch) ||
	    le_uint16(header.format_chunk.blockalign) != 2 * nch ||
	    le_uint32(header.format_chunk.bps) != hz * 2 * nch || count % (2 * nch) != 0) return -1;
	*length = (int)count; *rate = (int)hz; *channels = (int)nch;
	return ret;
}

static int rec_open(MSFilter *f, void *arg) {
	RecState *s = (RecState *)f->data;
	const char *filename = (const char *)arg;
	int flags;
	ssize_t fsize;

	if (s->fp && rec_close(f, NULL) != 0) return -1;
	s->size = 0; s->io_error = 0; s->is_wav = FALSE;

	if (strstr(filename, ".wav") == filename + strlen(filename) - 4) {
		if (s->swap) return -1; /* WAV is little-endian PCM16, never raw L16. */
		s->is_wav = TRUE;
	}

	if (access(filename, R_OK | W_OK) == 0) {
		flags = O_WRONLY | O_BINARY;
		if (s->is_wav) {
			int result = rec_get_length(filename, &s->size, &s->rate, &s->nchannels);
			if (result < 0) return -1; /* never overwrite an unknown existing WAV */
		}
		if (s->is_wav && s->size > 0) {
			ms_message("Opening wav file in append mode, current data size is %i", s->size);
			s->is_wav = TRUE;
		}
	} else {
		flags = O_WRONLY | O_CREAT | O_TRUNC | O_BINARY;
		s->size = 0;
	}

	s->fp = bctbx_file_open2(bctbx_vfs_get_default(), filename, flags);
	if (s->fp == NULL) {
		ms_warning("Cannot open %s: %s", filename, strerror(errno));
		return -1;
	}

	if (s->size > 0) {
		if ((fsize = bctbx_file_size(s->fp)) != BCTBX_VFS_ERROR) {
			if (bctbx_file_seek(s->fp, (off_t)fsize, SEEK_SET) == BCTBX_VFS_ERROR) {
				int err = errno;
				ms_error("Could not lseek to end of file: %s", strerror(err));
				bctbx_file_close(s->fp); s->fp = NULL; return -1;
			}
		} else {
			ms_error("fstat() failed: %s", strerror(errno));
			bctbx_file_close(s->fp); s->fp = NULL; return -1;
		}
	}
	if (rec_refresh_empty_wav(s) != 0) {
		bctbx_file_close(s->fp); s->fp = NULL; return -1;
	}
	ms_message("MSFileRec: recording into %s", filename);
	s->writer = ms_async_writer_new(s->fp);
	ms_mutex_lock(&f->lock);
	s->state = MSRecorderPaused;
	ms_mutex_unlock(&f->lock);
	return 0;
}

static int rec_start(MSFilter *f, BCTBX_UNUSED(void *arg)) {
	RecState *s = (RecState *)f->data;
	if (s->state != MSRecorderPaused) {
		ms_error("MSFileRec: cannot start, state=%i", s->state);
		return -1;
	}
	ms_mutex_lock(&f->lock);
	s->state = MSRecorderRunning;
	ms_mutex_unlock(&f->lock);
	return 0;
}

static int rec_stop(MSFilter *f, BCTBX_UNUSED(void *arg)) {
	RecState *s = (RecState *)f->data;
	ms_mutex_lock(&f->lock);
	s->state = MSRecorderPaused;
	ms_mutex_unlock(&f->lock);
	return 0;
}

static int write_wav_header(bctbx_vfs_file_t *fp, int rate, int nchannels, int size) {
	wave_header_t header;
	if (size < 0 || rate <= 0 || nchannels <= 0 || nchannels > 32767 ||
	    size % (2 * nchannels) != 0 ||
	    (uint32_t)rate > UINT_MAX / (2u * (uint32_t)nchannels)) return -1;
	memcpy(&header.riff_chunk.riff, "RIFF", 4);
	header.riff_chunk.len = le_uint32((uint32_t)size + sizeof(header) - 8);
	memcpy(&header.riff_chunk.wave, "WAVE", 4);

	memcpy(&header.format_chunk.fmt, "fmt ", 4);
	header.format_chunk.len = le_uint32(0x10);
	header.format_chunk.type = le_uint16(0x1);
	header.format_chunk.channel = le_uint16(nchannels);
	header.format_chunk.rate = le_uint32(rate);
	header.format_chunk.bps = le_uint32((uint32_t)rate * 2u * (uint32_t)nchannels);
	header.format_chunk.blockalign = le_uint16(2 * nchannels);
	header.format_chunk.bitpspl = le_uint16(16);

	memcpy(&header.data_chunk.data, "data", 4);
	header.data_chunk.len = le_uint32(size);
	if (bctbx_file_seek(fp, 0, SEEK_SET) == BCTBX_VFS_ERROR ||
	    bctbx_file_write2(fp, &header, sizeof(header)) != sizeof(header) ||
	    bctbx_file_sync(fp) != 0) return -1;
	return 0;
}

static int _rec_close(RecState *s) {
	s->state = MSRecorderClosed;
	if (s->fp) {
		ms_async_writer_destroy(s->writer);
		s->writer = NULL;
		if (s->is_wav) {
			/* Drain first; never make a short/failed writer look complete. */
			if (bctbx_file_size(s->fp) != (ssize_t)sizeof(wave_header_t) + s->size ||
			    write_wav_header(s->fp, s->rate, s->nchannels, s->size) != 0) s->io_error = -1;
		}

		if (bctbx_file_close(s->fp) != 0) s->io_error = -1;
		s->fp = NULL;
	}
	return s->io_error;
}

static int rec_close(MSFilter *f, BCTBX_UNUSED(void *arg)) {
	RecState *s = (RecState *)f->data;
	int result;
	ms_mutex_lock(&f->lock);
	result = _rec_close(s);
	ms_mutex_unlock(&f->lock);
	return result;
}

static int rec_get_state(MSFilter *f, void *arg) {
	RecState *s = (RecState *)f->data;
	*(MSRecorderState *)arg = s->state;
	return 0;
}

static int rec_set_sr(MSFilter *f, void *arg) {
	RecState *s = (RecState *)f->data;
	ms_mutex_lock(&f->lock);
	if (*((int *)arg) <= 0 || (s->is_wav && s->size > 0 && s->rate != *((int *)arg))) { ms_mutex_unlock(&f->lock); return -1; }
	s->rate = *((int *)arg);
	int result = rec_refresh_empty_wav(s);
	ms_mutex_unlock(&f->lock);
	return result;
}

static int rec_get_sr(MSFilter *f, void *arg) {
	RecState *d = (RecState *)f->data;
	int *sample_rate = (int *)arg;
	*sample_rate = d->rate;
	return 0;
}

static int rec_set_nchannels(MSFilter *f, void *arg) {
	RecState *s = (RecState *)f->data;
	int result;
	ms_mutex_lock(&f->lock);
	if (*(int *)arg <= 0 || *(int *)arg > 32767 || (s->is_wav && s->size > 0 && s->nchannels != *(int *)arg)) { ms_mutex_unlock(&f->lock); return -1; }
	s->nchannels = *(int *)arg; result = rec_refresh_empty_wav(s);
	ms_mutex_unlock(&f->lock); return result;
}

static int rec_get_nchannels(MSFilter *f, void *arg) {
	RecState *d = (RecState *)f->data;
	int *nchannels = (int *)arg;
	*nchannels = d->nchannels;
	return 0;
}

static void rec_uninit(MSFilter *f) {
	RecState *s = (RecState *)f->data;
	if (s->fp) rec_close(f, NULL);
	ms_free(s);
}

static int rec_get_fmtp(MSFilter *f, void *arg) {
	RecState *d = (RecState *)f->data;
	MSPinFormat *pinfmt = (MSPinFormat *)arg;
	if (pinfmt->pin == 0) pinfmt->fmt = ms_factory_get_audio_format(f->factory, d->mime, d->rate, d->nchannels, NULL);
	return 0;
}

static int rec_set_fmtp(MSFilter *f, void *arg) {
	RecState *d = (RecState *)f->data;
	MSPinFormat *pinfmt = (MSPinFormat *)arg;
	ms_filter_lock(f);
	if (!pinfmt || !pinfmt->fmt || !pinfmt->fmt->encoding || pinfmt->fmt->rate <= 0 || pinfmt->fmt->nchannels <= 0 ||
	    (d->is_wav && (strcmp(pinfmt->fmt->encoding, "pcm") != 0 ||
	    (d->size > 0 && (d->rate != pinfmt->fmt->rate || d->nchannels != pinfmt->fmt->nchannels))))) { ms_filter_unlock(f); return -1; }
	d->rate = pinfmt->fmt->rate;
	d->nchannels = pinfmt->fmt->nchannels;
	d->mime = pinfmt->fmt->encoding;
	d->swap = strcmp(d->mime, "L16") == 0;
	if (d->swap) d->is_wav = FALSE;
	int result = rec_refresh_empty_wav(d);
	ms_filter_unlock(f); return result;
}

static int rec_set_max_size(MSFilter *f, void *arg) {
	RecState *d = (RecState *)f->data;
	d->max_size = *((int *)arg);
	return 0;
}

static MSFilterMethod rec_methods[] = {{MS_FILTER_SET_SAMPLE_RATE, rec_set_sr},
                                       {MS_FILTER_SET_NCHANNELS, rec_set_nchannels},
                                       {MS_FILTER_GET_SAMPLE_RATE, rec_get_sr},
                                       {MS_FILTER_GET_NCHANNELS, rec_get_nchannels},
                                       {MS_FILE_REC_OPEN, rec_open},
                                       {MS_FILE_REC_START, rec_start},
                                       {MS_FILE_REC_STOP, rec_stop},
                                       {MS_FILE_REC_CLOSE, rec_close},
                                       {MS_RECORDER_OPEN, rec_open},
                                       {MS_RECORDER_START, rec_start},
                                       {MS_RECORDER_PAUSE, rec_stop},
                                       {MS_RECORDER_CLOSE, rec_close},
                                       {MS_RECORDER_GET_STATE, rec_get_state},
                                       {MS_FILTER_GET_OUTPUT_FMT, rec_get_fmtp},
                                       {MS_FILTER_SET_OUTPUT_FMT, rec_set_fmtp},
                                       {MS_RECORDER_SET_MAX_SIZE, rec_set_max_size},
                                       {0, NULL}};

#ifdef _WIN32

MSFilterDesc ms_file_rec_desc = {MS_FILE_REC_ID,
                                 "OpenWebPBXFixtureWavRecorder",
                                 N_("Wav file recorder"),
                                 MS_FILTER_OTHER,
                                 NULL,
                                 1,
                                 0,
                                 rec_init,
                                 NULL,
                                 rec_process,
                                 NULL,
                                 rec_uninit,
                                 rec_methods};

#else

MSFilterDesc ms_file_rec_desc = {.id = MS_FILE_REC_ID,
                                 .name = "OpenWebPBXFixtureWavRecorder",
                                 .text = N_("Wav file recorder"),
                                 .category = MS_FILTER_OTHER,
                                 .ninputs = 1,
                                 .noutputs = 0,
                                 .init = rec_init,
                                 .process = rec_process,
                                 .uninit = rec_uninit,
                                 .methods = rec_methods};

#endif

MS_FILTER_DESC_EXPORT(ms_file_rec_desc)
