package com.tennanova.mirror

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.util.Base64
import android.util.Log
import android.view.Surface
import com.tennanova.core.Proto
import com.tennanova.core.Settings
import com.tennanova.net.SocketClient
import org.json.JSONObject
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

data class MirrorSize(val width: Int, val height: Int) {
    companion object {
        fun fit(width: Int, height: Int, maxLongEdge: Int = 1920): MirrorSize {
            require(width > 0 && height > 0)
            val long = maxOf(width, height)
            val scale = minOf(1.0, maxLongEdge.toDouble() / long)
            fun even(value: Int): Int = maxOf(2, value and 1.inv())
            return MirrorSize(
                even((width * scale).roundToInt()),
                even((height * scale).roundToInt())
            )
        }

        fun initialBitrate(width: Int, height: Int, fps: Int = 30): Int =
            (width.toLong() * height * fps * 8 / 100)
                .coerceIn(2_000_000L, 8_000_000L).toInt()
    }
}

class MirrorBitrateController(private val ceiling: Int, initial: Int = ceiling) {
    var bitrate: Int = initial.coerceIn(MIN_BITRATE, ceiling)
        private set
    private var highSamples = 0
    private var lowSinceMs: Long? = null

    fun sample(queuedBytes: Long, nowMs: Long): Int? {
        if (queuedBytes > HIGH_QUEUE) {
            lowSinceMs = null
            highSamples++
            if (highSamples >= 2) {
                highSamples = 0
                val next = (bitrate * 3 / 4).coerceAtLeast(MIN_BITRATE)
                if (next != bitrate) {
                    bitrate = next
                    return next
                }
            }
            return null
        }
        highSamples = 0
        if (queuedBytes < LOW_QUEUE) {
            val since = lowSinceMs ?: nowMs.also { lowSinceMs = it }
            if (nowMs - since >= 10_000) {
                lowSinceMs = nowMs
                val next = (bitrate + bitrate / 10).coerceAtMost(ceiling)
                if (next != bitrate) {
                    bitrate = next
                    return next
                }
            }
        } else {
            lowSinceMs = null
        }
        return null
    }

    companion object {
        const val HIGH_QUEUE = 1L * 1024 * 1024
        const val RECOVERY_QUEUE = 2L * 1024 * 1024
        const val LOW_QUEUE = 256L * 1024
        const val MIN_BITRATE = 2_000_000
    }
}

object MirrorVideoPacket {
    private const val HEADER_BYTES = 20

    fun encode(
        generation: Int,
        sequence: Long,
        presentationTimeUs: Long,
        keyframe: Boolean,
        accessUnit: ByteArray
    ): ByteArray {
        require(generation in 0..0xffff)
        require(sequence in 0..0xffff_ffffL)
        val buffer = ByteBuffer.allocate(HEADER_BYTES + accessUnit.size)
        buffer.put(byteArrayOf('T'.code.toByte(), 'N'.code.toByte(), 'M'.code.toByte(), 'V'.code.toByte()))
        buffer.put(1)
        buffer.put(if (keyframe) 1 else 0)
        buffer.putShort(generation.toShort())
        buffer.putInt(sequence.toInt())
        buffer.putLong(presentationTimeUs)
        buffer.put(accessUnit)
        return buffer.array()
    }
}

data class MirrorCodecConfig(
    val width: Int,
    val height: Int,
    val rotation: Int,
    val sps: ByteArray,
    val pps: ByteArray
)

/** A single surface-input AVC encoder. Rotation replaces the whole instance. */
class MirrorH264Encoder(
    val size: MirrorSize,
    initialBitrate: Int,
    private val rotation: Int,
    private val onConfig: (MirrorCodecConfig) -> Unit,
    private val onFrame: (ByteArray, Long, Boolean) -> Unit,
    private val onError: (Throwable) -> Unit
) {
    private val running = AtomicBoolean(false)
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    val surface: Surface
    private var drainThread: Thread? = null

    init {
        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC, size.width, size.height
        ).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, initialBitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = codec.createInputSurface()
    }

    fun start() {
        if (!running.compareAndSet(false, true)) return
        codec.start()
        drainThread = Thread(::drain, "tenna-mirror-encoder").apply {
            isDaemon = true
            start()
        }
    }

    fun requestKeyFrame() = runCatching {
        codec.setParameters(Bundle().apply {
            putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
        })
    }

    fun setBitrate(value: Int) = runCatching {
        codec.setParameters(Bundle().apply {
            putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, value)
        })
    }

    fun stop() {
        if (!running.getAndSet(false)) return
        runCatching { codec.signalEndOfInputStream() }
        drainThread?.join(800)
        drainThread = null
        runCatching { codec.stop() }
        runCatching { codec.release() }
        runCatching { surface.release() }
    }

    private fun drain() {
        val info = MediaCodec.BufferInfo()
        try {
            while (running.get()) {
                when (val index = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> publishConfig(codec.outputFormat)
                    else -> if (index >= 0) {
                        val output = codec.getOutputBuffer(index)
                        if (output != null && info.size > 0 &&
                            info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                        ) {
                            output.position(info.offset)
                            output.limit(info.offset + info.size)
                            val bytes = ByteArray(info.size)
                            output.get(bytes)
                            onFrame(
                                H264AnnexB.normalize(bytes),
                                info.presentationTimeUs,
                                info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            )
                        }
                        codec.releaseOutputBuffer(index, false)
                    }
                }
            }
        } catch (error: Throwable) {
            if (running.get()) onError(error)
        }
    }

    private fun publishConfig(format: MediaFormat) {
        val units = buildList {
            for (key in listOf("csd-0", "csd-1")) {
                format.getByteBuffer(key)?.let { addAll(H264AnnexB.units(it.toByteArray())) }
            }
        }
        val sps = units.firstOrNull { it.isNotEmpty() && it[0].toInt() and 0x1f == 7 }
        val pps = units.firstOrNull { it.isNotEmpty() && it[0].toInt() and 0x1f == 8 }
        if (sps == null || pps == null) {
            onError(IllegalStateException("Android encoder did not publish SPS/PPS"))
            return
        }
        onConfig(MirrorCodecConfig(size.width, size.height, rotation, sps, pps))
    }

    private fun ByteBuffer.toByteArray(): ByteArray {
        val copy = duplicate()
        val bytes = ByteArray(copy.remaining())
        copy.get(bytes)
        return bytes
    }
}

object H264AnnexB {
    private val START = byteArrayOf(0, 0, 0, 1)

    fun normalize(data: ByteArray): ByteArray {
        if (startCodeLength(data, 0) > 0) return data
        val output = ArrayList<Byte>(data.size + 16)
        var offset = 0
        while (offset + 4 <= data.size) {
            val length = ByteBuffer.wrap(data, offset, 4).int
            if (length <= 0 || offset + 4 + length > data.size) break
            START.forEach(output::add)
            for (i in offset + 4 until offset + 4 + length) output.add(data[i])
            offset += 4 + length
        }
        if (offset == data.size && output.isNotEmpty()) return output.toByteArray()
        return START + data
    }

    fun units(data: ByteArray): List<ByteArray> {
        val normalized = normalize(data)
        val starts = mutableListOf<Pair<Int, Int>>()
        var i = 0
        while (i < normalized.size - 2) {
            val length = startCodeLength(normalized, i)
            if (length > 0) {
                starts += i to length
                i += length
            } else i++
        }
        return starts.mapIndexedNotNull { index, (start, codeLength) ->
            val bodyStart = start + codeLength
            val bodyEnd = starts.getOrNull(index + 1)?.first ?: normalized.size
            if (bodyEnd > bodyStart) normalized.copyOfRange(bodyStart, bodyEnd) else null
        }
    }

    private fun startCodeLength(data: ByteArray, offset: Int): Int = when {
        offset + 4 <= data.size && data[offset] == 0.toByte() && data[offset + 1] == 0.toByte() &&
            data[offset + 2] == 0.toByte() && data[offset + 3] == 1.toByte() -> 4
        offset + 3 <= data.size && data[offset] == 0.toByte() && data[offset + 1] == 0.toByte() &&
            data[offset + 2] == 1.toByte() -> 3
        else -> 0
    }
}

/** Direct-only video connection. Its relay provider is deliberately always null. */
class MirrorVideoClient(
    context: Context,
    settings: Settings,
    private val sessionId: String,
    private val onAuthenticated: () -> Unit,
    private val onAvailability: (Boolean) -> Unit,
    private val onFailure: (String) -> Unit
) {
    @Volatile private var authenticated = false
    private val socket: SocketClient

    init {
        socket = SocketClient(
            context = context,
            settings = settings,
            onMessage = ::onMessage,
            onBinary = { },
            onStateChange = { state ->
                when (state) {
                    SocketClient.State.CONNECTED -> {
                        authenticated = false
                        onAvailability(false)
                        val token = settings.deviceToken
                        if (token == null) {
                            onFailure("Missing paired-device token")
                        } else {
                            socket.send(
                                Proto.envelope("mirror.stream.hello")
                                    .put("deviceId", settings.deviceId)
                                    .put("deviceToken", token)
                                    .put("sessionId", sessionId)
                            )
                        }
                    }
                    SocketClient.State.PIN_MISMATCH -> onFailure("Mac identity changed")
                    SocketClient.State.AUTH_FAILED -> onFailure("Mac rejected the video stream")
                    SocketClient.State.DISCONNECTED,
                    SocketClient.State.CONNECTING,
                    SocketClient.State.UNPAIRED -> {
                        authenticated = false
                        onAvailability(false)
                    }
                }
            },
            relayPort = { null }
        )
    }

    val queuedBytes: Long get() = socket.queuedBytes
    val isAuthenticated: Boolean get() = authenticated

    fun start() = socket.start()
    fun stop() = socket.stop()

    fun sendConfig(config: MirrorCodecConfig, generation: Int): Boolean {
        if (!authenticated) return false
        return socket.send(
            Proto.envelope("mirror.config")
                .put("sessionId", sessionId)
                .put("generation", generation)
                .put("codec", "h264")
                .put("width", config.width)
                .put("height", config.height)
                .put("rotation", config.rotation)
                .put("sps", Base64.encodeToString(config.sps, Base64.NO_WRAP))
                .put("pps", Base64.encodeToString(config.pps, Base64.NO_WRAP))
        )
    }

    fun sendFrame(frame: ByteArray): Boolean = authenticated && socket.sendBinary(frame)

    private fun onMessage(message: JSONObject) {
        if (message.optString("type") != "mirror.stream.ack") return
        if (!message.optBoolean("ok")) {
            val reason = message.optString("reason", "Stream authentication failed")
            // A primary reconnect can briefly arrive behind this auxiliary socket. The
            // Mac closes us after `not_ready`; SocketClient then retries within the
            // projection service's fixed ten-second direct-route grace period.
            if (reason != "not_ready") onFailure(reason)
            return
        }
        authenticated = true
        socket.sessionAuthenticated()
        onAvailability(true)
        onAuthenticated()
        Log.i("TennaMirror", "mirror video stream authenticated")
    }
}
