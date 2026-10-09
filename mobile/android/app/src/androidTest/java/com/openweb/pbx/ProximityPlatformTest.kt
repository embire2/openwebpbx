/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.os.PowerManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** No phone account or call is required. Physical near/far behavior needs a handset. */
@RunWith(AndroidJUnit4::class)
class ProximityPlatformTest {
    @Test fun usesPlatformCapabilityAndAlwaysReleasesItsLock() {
        val power = InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(PowerManager::class.java)
        val platform = AndroidProximityPlatform(power)
        val supported = power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)
        assertEquals(supported, platform.isSupported())
        if (supported) {
            val lock = platform.createLock()
            try {
                assertFalse(lock.isHeld)
                lock.acquire(); assertTrue(lock.isHeld)
                lock.acquire(); assertTrue(lock.isHeld)
                lock.release(); assertFalse("Lock must not accumulate reference counts", lock.isHeld)
            } finally { if (lock.isHeld) lock.release() }
        }
        val protection = CallProximity(platform)
        try { protection.update(true); protection.update(false) }
        finally { protection.close() }
        protection.update(true) // A late SDK callback cannot reactivate a closed service.
    }
}
