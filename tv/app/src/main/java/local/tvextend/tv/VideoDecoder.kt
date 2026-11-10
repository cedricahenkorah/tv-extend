package local.tvextend.tv

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Hardware decoder that renders straight to a Surface, tuned for low latency:
 * every decoded frame is shown immediately instead of being scheduled by timestamp.
 */
class VideoDecoder(
    mime: String,
    width: Int,
    height: Int,
    surface: Surface,
    private val onFirstFrame: () -> Unit,
) {
    /** Set if the codec reports an error; the owner should release and recreate the decoder. */
    @Volatile
    var error: Throwable? = null
        private set

    private val codec = MediaCodec.createDecoderByType(mime)
    private val callbackThread = HandlerThread("tvextend-decoder").apply { start() }
    private val freeInputs = LinkedBlockingQueue<Int>()
    @Volatile private var renderedAny = false

    init {
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // 0 = real-time
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && supportsLowLatency(mime)) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }

        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                freeInputs.offer(index)
            }

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                val hasImage = info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                codec.releaseOutputBuffer(index, hasImage)
                if (hasImage && !renderedAny) {
                    renderedAny = true
                    onFirstFrame()
                }
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                Log.i(TAG, "output format: $format")
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "decoder error", e)
                error = e
            }
        }, Handler(callbackThread.looper))

        codec.configure(format, surface, null, 0)
        codec.start()
        Log.i(TAG, "decoder ${codec.name} started: $mime ${width}x$height")
    }

    /** SPS/PPS (and VPS for HEVC) in Annex B form. */
    fun queueConfig(data: ByteArray, length: Int): Boolean =
        queue(data, length, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)

    fun queueFrame(data: ByteArray, length: Int, timestampUs: Long, isKeyframe: Boolean): Boolean =
        queue(data, length, timestampUs, if (isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)

    /** Returns false if the frame was dropped (decoder busy or frame too big). */
    private fun queue(data: ByteArray, length: Int, timestampUs: Long, flags: Int): Boolean {
        if (error != null) return false
        val index = freeInputs.poll(50, TimeUnit.MILLISECONDS) ?: return false
        return try {
            val buffer = codec.getInputBuffer(index) ?: return false
            if (length > buffer.capacity()) {
                Log.w(TAG, "frame of $length bytes is larger than the input buffer (${buffer.capacity()})")
                freeInputs.offer(index)
                return false
            }
            buffer.clear()
            buffer.put(data, 0, length)
            codec.queueInputBuffer(index, 0, length, timestampUs, flags)
            true
        } catch (e: IllegalStateException) {
            error = e
            false
        }
    }

    fun release() {
        try {
            codec.stop()
        } catch (_: IllegalStateException) {
        }
        codec.release()
        callbackThread.quitSafely()
    }

    private fun supportsLowLatency(mime: String): Boolean = try {
        codec.codecInfo.getCapabilitiesForType(mime)
            .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
    } catch (_: IllegalArgumentException) {
        false
    }

    private companion object {
        const val TAG = "TVExtend/Decoder"
    }
}
