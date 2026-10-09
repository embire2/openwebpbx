/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.junit.Assert.*
import org.junit.Test
import org.linphone.core.AudioDevice
import org.linphone.core.Call

class CallProximityTest {
    private class Lock: ProximityWakeLock {
        override var isHeld = false
        var acquisitions = 0
        var releases = 0
        var acquireFailure = false
        var releaseFailure = false
        override fun acquire() {
            if (acquireFailure) throw SecurityException("Unavailable firmware API")
            isHeld = true; acquisitions++
        }
        override fun release() {
            if (releaseFailure) throw IllegalStateException("Transient release failure")
            assertTrue("No double release", isHeld)
            isHeld = false; releases++
        }
    }
    private class Platform(val supported: Boolean = true): ProximityPlatform {
        val lock = Lock()
        var checks = 0
        var creations = 0
        var checkFailure = false
        var createFailure = false
        override fun isSupported(): Boolean {
            checks++
            if (checkFailure) throw UnsupportedOperationException("Unavailable firmware API")
            return supported
        }
        override fun createLock(): ProximityWakeLock {
            creations++
            if (createFailure) throw SecurityException("Unavailable firmware API")
            return lock
        }
    }

    @Test fun unansweredIncomingCallsNeverBlankTheScreen() {
        for (state in listOf(Call.State.IncomingReceived, Call.State.IncomingEarlyMedia)) {
            assertFalse(state.toString(), CallProximityPolicy.enabled(true, state, AudioDevice.Type.Earpiece))
            assertFalse(state.toString(), CallProximityPolicy.enabled(false, state, AudioDevice.Type.Earpiece))
        }
        assertFalse(CallProximityPolicy.enabled(false, Call.State.StreamsRunning, AudioDevice.Type.Earpiece))
    }
    @Test fun outgoingSetupAndRingingProtectOnlyTheActualEarpiece() {
        for (state in listOf(Call.State.OutgoingInit, Call.State.OutgoingProgress,
            Call.State.OutgoingRinging, Call.State.OutgoingEarlyMedia)) {
            for (output in AudioDevice.Type.values()) {
                assertEquals("$state/$output", output == AudioDevice.Type.Earpiece,
                    CallProximityPolicy.enabled(false, state, output))
            }
            assertFalse(CallProximityPolicy.enabled(false, state, null))
        }
    }
    @Test fun onlyTheRealEarpieceOutputEnablesProtection() {
        for (output in AudioDevice.Type.values()) {
            assertEquals(output.toString(), output == AudioDevice.Type.Earpiece,
                CallProximityPolicy.enabled(true, Call.State.StreamsRunning, output))
        }
        assertFalse(CallProximityPolicy.enabled(true, Call.State.StreamsRunning, null))
    }
    @Test fun localHoldAndEveryTerminalStateRestoreScreenControls() {
        for (state in listOf(Call.State.Pausing, Call.State.Paused, Call.State.End,
            Call.State.Error, Call.State.Released, Call.State.Idle)) {
            assertFalse(state.toString(), CallProximityPolicy.enabled(true, state, AudioDevice.Type.Earpiece))
        }
        assertFalse(CallProximityPolicy.enabled(true, null, AudioDevice.Type.Earpiece))
    }
    @Test fun renegotiationResumeAndRemoteHoldKeepEarpieceProtected() {
        for (state in listOf(Call.State.Connected, Call.State.StreamsRunning, Call.State.Updating,
            Call.State.UpdatedByRemote, Call.State.Resuming, Call.State.PausedByRemote)) {
            assertTrue(state.toString(), CallProximityPolicy.enabled(true, state, AudioDevice.Type.Earpiece))
        }
    }
    @Test fun supportedDeviceAcquiresOnceAndReleasesImmediatelyOnRouteChange() {
        val platform = Platform(); val protection = CallProximity(platform)
        protection.update(false); assertEquals(0, platform.creations)
        protection.update(true); protection.update(true)
        assertEquals(1, platform.checks); assertEquals(1, platform.creations)
        assertEquals(1, platform.lock.acquisitions); assertTrue(platform.lock.isHeld)
        protection.update(false)
        assertFalse(platform.lock.isHeld); assertEquals(1, platform.lock.releases)
        protection.update(false); protection.close(); assertEquals(1, platform.lock.releases)
    }
    @Test fun returningFromSpeakerReusesLockAndServiceCloseCannotReacquire() {
        val platform = Platform(); val protection = CallProximity(platform)
        protection.update(true); protection.update(false); protection.update(true)
        assertEquals(2, platform.lock.acquisitions); assertEquals(1, platform.creations)
        protection.close(); protection.update(true); protection.close()
        assertFalse(platform.lock.isHeld); assertEquals(2, platform.lock.releases)
        assertEquals(2, platform.lock.acquisitions)
    }
    @Test fun sensorlessDeviceNeverCreatesAWakeLockOrBlocksCalling() {
        val platform = Platform(false); val protection = CallProximity(platform)
        repeat(4) { protection.update(true); protection.update(false) }
        protection.close()
        assertEquals(1, platform.checks); assertEquals(0, platform.creations)
        assertEquals(0, platform.lock.acquisitions); assertFalse(platform.lock.isHeld)
    }
    @Test fun firmwareSupportAndCreationFailuresAreSafe() {
        for (createFailure in listOf(false, true)) {
            val platform = Platform().apply {
                this.createFailure = createFailure; checkFailure = !createFailure
            }
            val protection = CallProximity(platform)
            protection.update(true); protection.update(true); protection.update(false); protection.close()
            assertFalse(platform.lock.isHeld); assertEquals(0, platform.lock.acquisitions)
        }
    }
    @Test fun acquisitionFailureDoesNotBreakTheCallOrRetryForever() {
        val platform = Platform().apply { lock.acquireFailure = true }
        val protection = CallProximity(platform)
        protection.update(true); protection.update(true); protection.update(false); protection.close()
        assertEquals(1, platform.creations); assertEquals(0, platform.lock.acquisitions)
        assertFalse(platform.lock.isHeld)
    }
    @Test fun failedReleaseRetainsHandleForCleanupRetry() {
        val platform = Platform(); val protection = CallProximity(platform)
        protection.update(true); platform.lock.releaseFailure = true; protection.update(false)
        assertTrue(platform.lock.isHeld)
        platform.lock.releaseFailure = false; protection.close(); protection.update(true)
        assertFalse(platform.lock.isHeld); assertEquals(1, platform.lock.releases)
        assertEquals(1, platform.lock.acquisitions)
    }
}
