package com.example.local_assistant.media

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Звук в mp3, m4a или wav (ADR-026): MediaExtractor берёт первую звуковую
 * дорожку (у видео — его звук), системный MediaCodec декодирует её в PCM
 * 16 бит, а [PcmSink] кодирует: LAME (mp3), AAC + MediaMuxer (m4a) или
 * заголовок RIFF (wav). Больше двух каналов сводится в стерео.
 */
class AudioPipeline(private val job: MediaJob, private val progress: MediaProgress) {
    private val request = job.request

    fun run() {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var sink: PcmSink? = null
        try {
            try {
                extractor.setDataSource(request.input.path)
            } catch (error: IOException) {
                throw MediaFail(MediaCodes.MEDIA_OPEN)
            } catch (error: IllegalArgumentException) {
                throw MediaFail(MediaCodes.MEDIA_OPEN)
            }
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            } ?: throw MediaFail(MediaCodes.NO_STREAM)
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val duration =
                if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else -1L
            val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format)
                ?: throw MediaFail(MediaCodes.MEDIA_OPEN)
            val codec = try {
                MediaCodec.createByCodecName(name)
            } catch (error: Exception) {
                throw MediaFail(MediaCodes.MEDIA_OPEN)
            }
            decoder = codec
            format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            try {
                codec.configure(format, null, null, 0)
                codec.start()
            } catch (error: Exception) {
                throw MediaFail(MediaCodes.MEDIA_OPEN)
            }
            val out = sinkFor(request.target)
            sink = out
            decode(extractor, codec, format, duration, out)
            job.checkCancelled()
            out.finish()
        } finally {
            sink?.close()
            try {
                decoder?.stop()
            } catch (error: Exception) {
                // Уже остановлен или упал — освобождаем.
            }
            decoder?.release()
            extractor.release()
        }
    }

    private fun sinkFor(target: String): PcmSink = when (target) {
        MediaTargets.MP3 -> Mp3Sink(request.output, request.audioKbps)
        MediaTargets.M4A -> AacSink(request.output, request.audioKbps, job)
        MediaTargets.WAV -> WavSink(request.output)
        else -> throw MediaFail(MediaCodes.UNSUPPORTED)
    }

    private fun decode(
        extractor: MediaExtractor,
        codec: MediaCodec,
        input: MediaFormat,
        duration: Long,
        sink: PcmSink,
    ) {
        val info = MediaCodec.BufferInfo()
        var rate = input.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = input.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var encoding = AudioFormat.ENCODING_PCM_16BIT
        var opened = false
        var inputDone = false
        val pcm = PcmConverter()
        while (true) {
            job.checkCancelled()
            if (!inputDone) {
                val index = codec.dequeueInputBuffer(TIMEOUT_US)
                if (index >= 0) {
                    val buffer = codec.getInputBuffer(index) ?: throw MediaFail(MediaCodes.MEDIA)
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            val index = try {
                codec.dequeueOutputBuffer(info, TIMEOUT_US)
            } catch (error: IllegalStateException) {
                throw MediaFail(MediaCodes.MEDIA)
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val format = codec.outputFormat
                val newRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val newChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                if (opened && (newRate != rate || newChannels != channels)) {
                    // Смена частоты посреди файла: склеить честно нельзя.
                    throw MediaFail(MediaCodes.MEDIA)
                }
                rate = newRate
                channels = newChannels
                encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                    format.getInteger(MediaFormat.KEY_PCM_ENCODING)
                } else {
                    AudioFormat.ENCODING_PCM_16BIT
                }
                continue
            }
            if (index < 0) continue
            val buffer = codec.getOutputBuffer(index)
            if (buffer != null && info.size > 0) {
                buffer.position(info.offset)
                buffer.limit(info.offset + info.size)
                val (data, frames) = pcm.convert(buffer.slice(), channels, encoding)
                if (frames > 0) {
                    if (!opened) {
                        if (rate <= 0 || channels <= 0) throw MediaFail(MediaCodes.MEDIA)
                        sink.open(rate, minOf(channels, 2))
                        opened = true
                    }
                    sink.write(data, frames)
                }
                if (duration > 0) {
                    progress.report((info.presentationTimeUs.toDouble() / duration).coerceIn(0.0, 0.99))
                } else {
                    progress.report(null)
                }
            }
            codec.releaseOutputBuffer(index, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
        }
        if (!opened) throw MediaFail(MediaCodes.NO_STREAM)
    }

    companion object {
        private const val TIMEOUT_US = 10_000L
    }
}

/**
 * PCM от декодера → int16 с чередованием, не больше двух каналов, в прямом
 * буфере (его адрес уходит в JNI). 16 бит и 1–2 канала — без копии.
 */
class PcmConverter {
    private var work: ByteBuffer = ByteBuffer.allocateDirect(0)

    fun convert(input: ByteBuffer, channels: Int, encoding: Int): Pair<ByteBuffer, Int> {
        input.order(ByteOrder.nativeOrder())
        val bytes = when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> 4
            AudioFormat.ENCODING_PCM_16BIT -> 2
            else -> throw MediaFail(MediaCodes.MEDIA)
        }
        if (channels <= 0) throw MediaFail(MediaCodes.MEDIA)
        val frames = input.remaining() / (bytes * channels)
        if (bytes == 2 && channels <= 2) {
            input.limit(input.position() + frames * channels * 2)
            return Pair(input.slice().order(ByteOrder.nativeOrder()), frames)
        }
        val outChannels = minOf(channels, 2)
        val need = frames * outChannels * 2
        if (work.capacity() < need) {
            work = ByteBuffer.allocateDirect(need).order(ByteOrder.nativeOrder())
        }
        work.clear()
        val sample = FloatArray(channels)
        for (f in 0 until frames) {
            for (c in 0 until channels) {
                sample[c] = if (bytes == 4) {
                    input.getFloat()
                } else {
                    input.getShort() / 32768f
                }
            }
            if (outChannels == 1) {
                work.putShort(toShort(sample[0]))
            } else if (channels == 2) {
                work.putShort(toShort(sample[0]))
                work.putShort(toShort(sample[1]))
            } else {
                val (left, right) = downmix(sample)
                work.putShort(toShort(left))
                work.putShort(toShort(right))
            }
        }
        work.flip()
        return Pair(work, frames)
    }

    /** Порядок каналов Android: FL, FR, FC, LFE, BL, BR, …; LFE не берётся. */
    private fun downmix(s: FloatArray): Pair<Float, Float> {
        val k = 0.7071f
        var left = s[0]
        var right = s[1]
        var norm = 1f
        if (s.size > 2) {
            left += k * s[2]
            right += k * s[2]
            norm += k
        }
        if (s.size > 5) {
            left += k * s[4]
            right += k * s[5]
            norm += k
        } else if (s.size == 4) {
            // Квадро: FL, FR, BL, BR.
            left = s[0] + k * s[2]
            right = s[1] + k * s[3]
            norm = 1f + k
        }
        return Pair(left / norm, right / norm)
    }

    private fun toShort(v: Float): Short = (v.coerceIn(-1f, 1f) * 32767f).toInt().toShort()
}
