package local.tvextend.tv

import android.os.SystemClock
import android.util.Log
import android.view.Surface
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * Listens for the Mac on [Protocol.PORT] and feeds its video into a [VideoDecoder].
 * One Mac at a time; when it disconnects, the server goes back to waiting.
 */
class StreamServer(
    private val surface: Surface,
    private val deviceName: String,
    private val listener: Listener,
) {
    interface Listener {
        fun onWaiting()
        fun onConnected(peer: String)
        fun onFirstFrame()
        fun onDisconnected(reason: String)
    }

    @Volatile private var running = false
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var client: Socket? = null
    private var worker: Thread? = null

    fun start() {
        running = true
        worker = thread(name = "tvextend-server") { acceptLoop() }
    }

    fun stop() {
        running = false
        closeQuietly(client)
        closeQuietly(serverSocket)
        worker?.join(2000)
        worker = null
    }

    private fun acceptLoop() {
        try {
            val server = ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(Protocol.PORT))
            }
            serverSocket = server

            while (running) {
                listener.onWaiting()
                val socket = try {
                    server.accept()
                } catch (e: IOException) {
                    break // stop() closed the server socket
                }
                socket.tcpNoDelay = true
                client = socket
                val peer = socket.inetAddress.hostAddress ?: "unknown"
                Log.i(TAG, "Mac connected from $peer")
                listener.onConnected(peer)

                val reason = try {
                    serve(socket)
                    "Your Mac disconnected."
                } catch (e: Exception) {
                    Log.w(TAG, "connection ended", e)
                    e.message ?: e.javaClass.simpleName
                } finally {
                    closeQuietly(socket)
                    client = null
                }
                if (running) listener.onDisconnected(reason)
            }
        } catch (e: IOException) {
            Log.e(TAG, "server failed", e)
            if (running) listener.onDisconnected("Couldn't listen on port ${Protocol.PORT}: ${e.message}")
        } finally {
            closeQuietly(serverSocket)
            serverSocket = null
        }
    }

    /** Handles one Mac connection until it closes. */
    private fun serve(socket: Socket) {
        val reader = Protocol.Reader(DataInputStream(BufferedInputStream(socket.getInputStream(), 256 * 1024)))
        val writer = Protocol.Writer(DataOutputStream(BufferedOutputStream(socket.getOutputStream())))

        var mime = "video/avc"
        var width = 1920
        var height = 1080
        var decoder: VideoDecoder? = null
        var lastConfig: ByteArray? = null
        var waitingForKeyframe = true
        var lastKeyframeRequest = 0L

        fun requestKeyframe() {
            val now = SystemClock.elapsedRealtime()
            if (now - lastKeyframeRequest > 500) {
                lastKeyframeRequest = now
                writer.send(Protocol.REQUEST_KEYFRAME)
            }
        }

        fun resetDecoder() {
            decoder?.release()
            decoder = null
            lastConfig = null
            waitingForKeyframe = true
        }

        try {
            while (running) {
                val header = reader.next() ?: return
                val payload = reader.payload

                when (header.type) {
                    Protocol.HELLO -> {
                        val hello = JSONObject(String(payload, 0, header.length, Charsets.UTF_8))
                        val codec = hello.optString("codec", "avc")
                        if (hello.optInt("version") != Protocol.VERSION || codec !in MIME_TYPES) {
                            Log.w(TAG, "unsupported HELLO: $hello")
                            writer.send(Protocol.BYE)
                            return
                        }
                        mime = MIME_TYPES.getValue(codec)
                        width = hello.optInt("width", 1920)
                        height = hello.optInt("height", 1080)
                        resetDecoder()

                        val ack = JSONObject()
                            .put("version", Protocol.VERSION)
                            .put("name", deviceName)
                            .put("maxWidth", 1920)
                            .put("maxHeight", 1080)
                            .put("codecs", JSONArray(MIME_TYPES.keys.toList()))
                        writer.send(Protocol.HELLO_ACK, payload = ack.toString().toByteArray(Charsets.UTF_8))
                    }

                    Protocol.CODEC_CONFIG -> {
                        val config = payload.copyOf(header.length)
                        // The Mac resends the config with every keyframe; only restart if it changed.
                        if (decoder == null || !config.contentEquals(lastConfig)) {
                            resetDecoder()
                            decoder = VideoDecoder(mime, width, height, surface) { listener.onFirstFrame() }
                                .also { it.queueConfig(config, config.size) }
                            lastConfig = config
                        }
                    }

                    Protocol.FRAME -> {
                        val current = decoder
                        when {
                            current == null -> requestKeyframe()
                            current.error != null -> {
                                resetDecoder()
                                requestKeyframe()
                            }
                            waitingForKeyframe && !header.isKeyframe -> requestKeyframe()
                            else -> {
                                waitingForKeyframe = false
                                if (!current.queueFrame(payload, header.length, header.timestampUs, header.isKeyframe)) {
                                    // A dropped frame breaks the chain of delta frames; resync on a keyframe.
                                    waitingForKeyframe = true
                                    requestKeyframe()
                                }
                            }
                        }
                    }

                    Protocol.PING -> writer.send(Protocol.PONG, header.timestampUs)
                    Protocol.BYE -> return
                    else -> Log.w(TAG, "ignoring message type ${header.type}")
                }
            }
        } finally {
            resetDecoder()
        }
    }

    private fun closeQuietly(c: Closeable?) {
        try {
            c?.close()
        } catch (_: IOException) {
        }
    }

    private companion object {
        const val TAG = "TVExtend/Server"
        val MIME_TYPES = mapOf("avc" to "video/avc", "hevc" to "video/hevc")
    }
}
