package com.demobo.mesh.local

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Records speech as 16 kHz mono 16-bit PCM (what speech models expect) and hands it back as a WAV file in memory. */
class VoiceRecorder {
    private var rec: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    private val pcm = ByteArrayOutputStream()

    val recording: Boolean get() = running

    /** Starts recording; false if the microphone could not be opened. Needs RECORD_AUDIO. */
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (running) return true
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, maxOf(min, RATE))
        if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); return false }
        synchronized(pcm) { pcm.reset() }
        rec = r
        r.startRecording()
        running = true
        thread = Thread {
            val buf = ByteArray(4096)
            while (running) {
                val n = r.read(buf, 0, buf.size)
                if (n > 0) synchronized(pcm) { pcm.write(buf, 0, n) }
                if (pcm.size() >= MAX_SECONDS * RATE * 2) running = false   // a minute is plenty for a message
            }
        }.also { it.start() }
        return true
    }

    /** Stops and returns the recording as WAV bytes (empty if nothing was recorded). */
    fun stop(): ByteArray {
        running = false
        thread?.join(1000)
        rec?.let { runCatching { it.stop() }; it.release() }
        rec = null; thread = null
        val data = synchronized(pcm) { pcm.toByteArray() }
        return if (data.isEmpty()) ByteArray(0) else wav(data)
    }

    companion object {
        const val RATE = 16000
        const val MAX_SECONDS = 60

        fun wav(pcm: ByteArray, rate: Int = RATE): ByteArray {
            val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            h.put("RIFF".toByteArray()); h.putInt(36 + pcm.size); h.put("WAVE".toByteArray())
            h.put("fmt ".toByteArray()); h.putInt(16); h.putShort(1); h.putShort(1)              // PCM, mono
            h.putInt(rate); h.putInt(rate * 2); h.putShort(2); h.putShort(16)                   // byte rate, block align, bits
            h.put("data".toByteArray()); h.putInt(pcm.size)
            return h.array() + pcm
        }
    }
}
