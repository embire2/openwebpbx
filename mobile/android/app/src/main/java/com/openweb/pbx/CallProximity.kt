/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.annotation.SuppressLint
import android.os.PowerManager
import org.linphone.core.AudioDevice
import org.linphone.core.Call

/** The actual call output route is authoritative, including automatic headset changes. */
internal object CallProximityPolicy {
    fun enabled(answered: Boolean, state: Call.State?, output: AudioDevice.Type?): Boolean =
        output == AudioDevice.Type.Earpiece && when (state) {
            // A caller can already hold the phone to their ear while it rings.
            // Unanswered incoming calls remain visible so they can be answered.
            Call.State.OutgoingInit, Call.State.OutgoingProgress,
            Call.State.OutgoingRinging, Call.State.OutgoingEarlyMedia -> true
            Call.State.Connected, Call.State.StreamsRunning, Call.State.Updating,
            Call.State.UpdatedByRemote, Call.State.Resuming, Call.State.PausedByRemote -> answered
            else -> false
        }
}

internal interface ProximityWakeLock {
    val isHeld: Boolean
    fun acquire()
    fun release()
}

internal interface ProximityPlatform {
    fun isSupported(): Boolean
    fun createLock(): ProximityWakeLock
}

/** Android owns near/far detection, display blanking and suppression of screen touches. */
internal class AndroidProximityPlatform(private val power: PowerManager): ProximityPlatform {
    override fun isSupported() = power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)
    override fun createLock(): ProximityWakeLock {
        val lock = power.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "OpenWebPBX:proximity")
        lock.setReferenceCounted(false)
        return object: ProximityWakeLock {
            override val isHeld get() = lock.isHeld
            // This lock is owned by the call service, not an Activity. Every inactive
            // call/route and service destruction releases it; process death also does.
            @SuppressLint("WakelockTimeout")
            override fun acquire() = lock.acquire()
            // Do not wait for a far event after hang-up or switching to speaker/headset.
            override fun release() = lock.release()
        }
    }
}

/** An unsupported or failing proximity API must never interrupt a phone call. */
internal class CallProximity(private val platform: ProximityPlatform): AutoCloseable {
    private var supported: Boolean? = null
    private var lock: ProximityWakeLock? = null
    private var closed = false
    private var failed = false

    fun update(enabled: Boolean) {
        if (!enabled || closed || failed) {
            release()
            return
        }
        try {
            if (supported == null) supported = platform.isSupported()
            if (supported != true) return // Sensorless devices keep normal power-button behavior.
            val current = lock ?: platform.createLock().also { lock = it }
            if (!current.isHeld) current.acquire()
        } catch (_: RuntimeException) {
            failed = true
            release()
        }
    }

    private fun release() {
        try {
            lock?.let { if (it.isHeld) it.release() }
        } catch (_: RuntimeException) {
            // Retain the handle so the next route/state change or close can retry.
            failed = true
        }
    }

    override fun close() {
        closed = true
        release()
    }
}
