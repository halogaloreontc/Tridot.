package com.example.local_assistant.media

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/** Куда идёт PCM 16 бит (1–2 канала, чередование, прямой буфер). */
interface PcmSink {
    fun open(rate: Int, channels: Int)

    /** [pcm] — с позиции 0, ровно [frames] кадров. */
    fun write(pcm: ByteBuffer, frames: Int)

    /** Дописывает файл; после него — [close]. */
    fun finish()

    /** Освобождает всё; можно звать много раз и без [finish]. */
    fun close()
}

/** MP3 через встроенный LAME (CBR), кадр «Info» в начале файла. */
class Mp3Sink(private val output: File, private val kbps: Int) : PcmSink {
    private var handle = 0L
    private var channels = 2
    private var file: RandomAccessFile? = null
    private var channel: FileChannel? = null
    private var out: ByteBuffer = ByteBuffer.allocateDirect(0)

    override fun open(rate: Int, channels: Int) {
        if (!Mp3Native.loaded) throw MediaFail(MediaCodes.UNSUPPORTED)
        this.channels = channels
        handle = Mp3Native.open(rate, channels, kbps, 0)
        if (handle == 0L) throw MediaFail(MediaCodes.ENCODER)
        val outRate = Mp3Native.outRate(handle)
        if (outRate <= 0) throw MediaFail(MediaCodes.ENCODER)
        // По частоте MP3, не входа: 8–24 кГц на высоком битрейте
        // пересэмплируются вверх и дают больше байт.
        out = ByteBuffer.allocateDirect(Mp3Native.outCap(CHUNK, rate, outRate))
        val raf = RandomAccessFile(output, "rw")
        raf.setLength(0)
        file = raf
        channel = raf.channel
    }

    override fun write(pcm: ByteBuffer, frames: Int) {
        val ch = channel ?: throw MediaFail(MediaCodes.FAILED)
        var at = 0
        while (at < frames) {
            val n = minOf(CHUNK, frames - at)
            pcm.limit((at + n) * channels * 2)
            pcm.position(at * channels * 2)
            val chunk = pcm.slice()
            out.clear()
            val written = Mp3Native.encode(handle, chunk, n, channels, out)
            if (written < 0) throw MediaFail(MediaCodes.ENCODER)
            writeAll(ch, written)
            at += n
        }
    }

    override fun finish() {
        val ch = channel ?: throw MediaFail(MediaCodes.FAILED)
        out.clear()
        val tail = Mp3Native.flush(handle, out)
        if (tail < 0) throw MediaFail(MediaCodes.ENCODER)
        writeAll(ch, tail)
        // Кадр «Info» поверх первого кадра: точная длительность у плееров.
        out.clear()
        val tag = Mp3Native.lametag(handle, out)
        if (tag > 0) {
            out.position(0)
            out.limit(tag)
            var pos = 0L
            while (out.hasRemaining()) pos += ch.write(out, pos)
        }
        ch.force(false)
    }

    private fun writeAll(ch: FileChannel, size: Int) {
        if (size == 0) return
        out.position(0)
        out.limit(size)
        while (out.hasRemaining()) ch.write(out)
    }

    override fun close() {
        if (handle != 0L) {
            Mp3Native.close(handle)
            handle = 0L
        }
        try {
            file?.close()
        } catch (error: Exception) {
            // Закрываем молча: ошибка записи уже сообщена.
        }
        file = null
        channel = null
    }

    companion object {
        /** Кадров PCM за один вызов LAME. */
        private const val CHUNK = 16_384
    }
}

/** WAV: PCM 16 бит, заголовок RIFF дописывается в конце (до 4 ГБ). */
class WavSink(private val output: File) : PcmSink {
    private var file: RandomAccessFile? = null
    private var rate = 0
    private var channels = 0
    private var data = 0L

    override fun open(rate: Int, channels: Int) {
        this.rate = rate
        this.channels = channels
        val raf = RandomAccessFile(output, "rw")
        raf.setLength(0)
        raf.channel.write(header(0))
        file = raf
    }

    override fun write(pcm: ByteBuffer, frames: Int) {
        val raf = file ?: throw MediaFail(MediaCodes.FAILED)
        val size = frames.toLong() * channels * 2
        if (data + size > MAX_DATA) throw MediaFail(MediaCodes.TOO_BIG_WAV)
        pcm.position(0)
        pcm.limit(size.toInt())
        while (pcm.hasRemaining()) raf.channel.write(pcm)
        data += size
    }

    override fun finish() {
        val raf = file ?: throw MediaFail(MediaCodes.FAILED)
        val head = header(data)
        var pos = 0L
        while (head.hasRemaining()) pos += raf.channel.write(head, pos)
        raf.channel.force(false)
    }

    /** Заголовок RIFF/WAVE на [size] байт данных. */
    private fun header(size: Long): ByteBuffer {
        val b = ByteBuffer.allocate(HEADER).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray(Charsets.US_ASCII))
        b.putInt((36 + size).toInt())
        b.put("WAVE".toByteArray(Charsets.US_ASCII))
        b.put("fmt ".toByteArray(Charsets.US_ASCII))
        b.putInt(16)
        b.putShort(1) // PCM
        b.putShort(channels.toShort())
        b.putInt(rate)
        b.putInt(rate * channels * 2)
        b.putShort((channels * 2).toShort())
        b.putShort(16)
        b.put("data".toByteArray(Charsets.US_ASCII))
        b.putInt(size.toInt())
        b.flip()
        return b
    }

    override fun close() {
        try {
            file?.close()
        } catch (error: Exception) {
            // Молча: ошибка записи уже сообщена.
        }
        file = null
    }

    companion object {
        private const val HEADER = 44

        /** Поле размера RIFF — 32 бита без знака. */
        private const val MAX_DATA = 0xFFFFFFFFL - 36
    }
}

/**
 * M4A: системный кодировщик AAC-LC с заданным битрейтом и MediaMuxer.
 * Частота выше 48 кГц уменьшается в целое число раз (96 → 48 кГц).
 */
class AacSink(
    private val output: File,
    private val kbps: Int,
    private val job: MediaJob,
) : PcmSink {
    private var encoder: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var track = -1
    private var started = false
    private var channels = 2
    private var rate = 0
    private var factor = 1
    private var frames = 0L
    private val info = MediaCodec.BufferInfo()
    private var work: ByteBuffer = ByteBuffer.allocateDirect(0)

    override fun open(rate: Int, channels: Int) {
        this.channels = channels
        factor = 1
        while (rate / factor > 48_000 || rate % factor != 0) {
            factor++
            if (factor > 8) throw MediaFail(MediaCodes.ENCODER)
        }
        this.rate = rate / factor
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, this.rate, channels)
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        format.setInteger(MediaFormat.KEY_BIT_RATE, kbps * 1000)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 64 * 1024)
        val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: throw MediaFail(MediaCodes.ENCODER)
        val codec = try {
            MediaCodec.createByCodecName(name).also {
                it.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                it.start()
            }
        } catch (error: Exception) {
            throw MediaFail(MediaCodes.ENCODER)
        }
        encoder = codec
        muxer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    override fun write(pcm: ByteBuffer, frames: Int) {
        val data = decimate(pcm, frames)
        val codec = encoder ?: throw MediaFail(MediaCodes.FAILED)
        val frameBytes = channels * 2
        while (data.hasRemaining()) {
            job.checkCancelled()
            val index = codec.dequeueInputBuffer(TIMEOUT_US)
            if (index >= 0) {
                val buffer = codec.getInputBuffer(index) ?: throw MediaFail(MediaCodes.ENCODER)
                buffer.clear()
                val n = minOf(buffer.remaining(), data.remaining()) / frameBytes * frameBytes
                if (n <= 0) throw MediaFail(MediaCodes.ENCODER)
                val slice = data.duplicate()
                slice.limit(slice.position() + n)
                buffer.put(slice)
                data.position(data.position() + n)
                codec.queueInputBuffer(index, 0, n, this.frames * 1_000_000L / rate, 0)
                this.frames += n / frameBytes
            }
            drain(codec, false)
        }
    }

    /** Каждые [factor] кадров — их среднее. */
    private fun decimate(pcm: ByteBuffer, frames: Int): ByteBuffer {
        pcm.position(0)
        pcm.limit(frames * channels * 2)
        if (factor == 1) return pcm
        pcm.order(ByteOrder.nativeOrder())
        val outFrames = frames / factor
        val need = outFrames * channels * 2
        if (work.capacity() < need) {
            work = ByteBuffer.allocateDirect(need).order(ByteOrder.nativeOrder())
        }
        work.clear()
        val sum = IntArray(channels)
        for (f in 0 until outFrames) {
            sum.fill(0)
            for (k in 0 until factor) {
                for (c in 0 until channels) sum[c] += pcm.getShort().toInt()
            }
            for (c in 0 until channels) work.putShort((sum[c] / factor).toShort())
        }
        work.flip()
        return work
    }

    override fun finish() {
        val codec = encoder ?: throw MediaFail(MediaCodes.FAILED)
        while (true) {
            job.checkCancelled()
            val index = codec.dequeueInputBuffer(TIMEOUT_US)
            if (index >= 0) {
                codec.queueInputBuffer(
                    index,
                    0,
                    0,
                    frames * 1_000_000L / rate,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                )
                break
            }
            drain(codec, false)
        }
        while (!drain(codec, true)) job.checkCancelled()
        if (!started) throw MediaFail(MediaCodes.ENCODER)
        muxer?.stop()
        started = false
    }

    /** Забирает готовое из кодировщика; `true` — дошли до конца. */
    private fun drain(codec: MediaCodec, end: Boolean): Boolean {
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (end) TIMEOUT_US else 0)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> return false
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val mux = muxer ?: throw MediaFail(MediaCodes.FAILED)
                    if (started) throw MediaFail(MediaCodes.ENCODER)
                    track = mux.addTrack(codec.outputFormat)
                    mux.start()
                    started = true
                }
                index >= 0 -> {
                    val buffer = codec.getOutputBuffer(index)
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (buffer != null && info.size > 0 && !config) {
                        if (!started) throw MediaFail(MediaCodes.ENCODER)
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer!!.writeSampleData(track, buffer, info)
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return true
                }
            }
        }
    }

    override fun close() {
        try {
            encoder?.stop()
        } catch (error: Exception) {
            // Уже остановлен.
        }
        encoder?.release()
        encoder = null
        try {
            if (started) muxer?.stop()
        } catch (error: Exception) {
            // Отмена посреди записи: файл всё равно удаляется.
        }
        try {
            muxer?.release()
        } catch (error: Exception) {
            // Молча.
        }
        muxer = null
        started = false
    }

    companion object {
        private const val TIMEOUT_US = 10_000L
    }
}
