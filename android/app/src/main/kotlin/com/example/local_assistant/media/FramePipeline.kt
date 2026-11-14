package com.example.local_assistant.media

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import java.io.FileOutputStream

/** Кадр из видео на первой секунде (короче — самый первый) в JPEG или PNG. */
class FramePipeline(private val job: MediaJob) {
    private val request = job.request

    fun run() {
        val retriever = MediaMetadataRetriever()
        var frame: Bitmap? = null
        try {
            try {
                retriever.setDataSource(request.input.path)
            } catch (error: Exception) {
                throw MediaFail(MediaCodes.MEDIA_OPEN)
            }
            val hasVideo = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO)
            if (hasVideo != "yes") throw MediaFail(MediaCodes.NO_STREAM)
            job.checkCancelled()
            frame = retriever.getFrameAtTime(1_000_000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: throw MediaFail(MediaCodes.MEDIA)
            job.checkCancelled()
            val png = request.target == MediaTargets.FRAME_PNG
            FileOutputStream(request.output).use { out ->
                val ok = frame.compress(
                    if (png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG,
                    if (png) 100 else request.jpegQuality,
                    out,
                )
                if (!ok) throw MediaFail(MediaCodes.ENCODER)
                out.fd.sync()
            }
        } finally {
            frame?.recycle()
            try {
                retriever.release()
            } catch (error: Exception) {
                // Молча.
            }
        }
    }
}
