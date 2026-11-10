package local.tvextend.tv

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException

/** Wire format shared with the Mac app. See protocol.md at the repo root. */
object Protocol {
    const val PORT = 48100
    const val VERSION = 1
    const val MAGIC = 0x5458 // "TX"
    const val HEADER_SIZE = 16
    const val MAX_PAYLOAD = 8 * 1024 * 1024

    const val HELLO = 0x01
    const val HELLO_ACK = 0x02
    const val CODEC_CONFIG = 0x10
    const val FRAME = 0x11
    const val REQUEST_KEYFRAME = 0x20
    const val PING = 0x30
    const val PONG = 0x31
    const val BYE = 0x7F

    const val FLAG_KEYFRAME = 0x01

    class Header(val type: Int, val flags: Int, val length: Int, val timestampUs: Long) {
        val isKeyframe get() = (flags and FLAG_KEYFRAME) != 0
    }

    /**
     * Reads messages from the Mac. The payload buffer is reused between messages to avoid
     * allocating a new array for every video frame.
     */
    class Reader(private val input: DataInputStream) {
        var payload = ByteArray(512 * 1024)
            private set

        /** Returns null when the other side closed the connection cleanly. */
        fun next(): Header? {
            val magic = try {
                input.readUnsignedShort()
            } catch (_: EOFException) {
                return null
            }
            if (magic != MAGIC) throw IOException("Bad message (magic 0x${magic.toString(16)})")

            val type = input.readUnsignedByte()
            val flags = input.readUnsignedByte()
            val length = input.readInt()
            val timestampUs = input.readLong()
            if (length < 0 || length > MAX_PAYLOAD) throw IOException("Bad message length $length")

            if (length > payload.size) payload = ByteArray(maxOf(length, payload.size * 2))
            input.readFully(payload, 0, length)
            return Header(type, flags, length, timestampUs)
        }
    }

    /** Thread-safe writer for messages to the Mac. */
    class Writer(private val output: DataOutputStream) {
        fun send(type: Int, timestampUs: Long = 0, payload: ByteArray = ByteArray(0), flags: Int = 0) {
            synchronized(this) {
                output.writeShort(MAGIC)
                output.writeByte(type)
                output.writeByte(flags)
                output.writeInt(payload.size)
                output.writeLong(timestampUs)
                output.write(payload)
                output.flush()
            }
        }
    }
}
