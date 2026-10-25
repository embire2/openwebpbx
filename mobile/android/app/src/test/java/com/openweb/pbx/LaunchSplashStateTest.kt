package com.openweb.pbx

import org.junit.Assert.*
import org.junit.Test

class LaunchSplashStateTest {
    @Test fun normalLaunchGetsFiveSecondsFromItsFirstVisibleFrame() {
        val state=LaunchSplashState();state.open(true,100)
        assertTrue(state.visible(900));state.firstFrame(1_000)
        assertEquals(5_000L,state.remaining(1_000));assertTrue(state.visible(5_999));assertFalse(state.visible(6_000))
    }
    @Test fun moreFramesNeverExtendTheDeadline() {
        val state=LaunchSplashState();state.open(true,100);state.firstFrame(200);state.firstFrame(4_000)
        assertEquals(1_200L,state.remaining(4_000));assertFalse(state.visible(5_200))
    }
    @Test fun recreationRetainsOnlyTheOriginalRemainingTime() {
        val first=LaunchSplashState();first.open(true,0);first.firstFrame(100)
        val restored=LaunchSplashState();restored.open(true,2_000,first.save());restored.firstFrame(2_000)
        assertEquals(3_100L,restored.remaining(2_000));assertFalse(restored.visible(5_100))
    }
    @Test fun expiredOrCompletedRestorationDoesNotReplayBranding() {
        for(saved in listOf(LaunchSplashState.Saved(false,1_000),LaunchSplashState.Saved(false,0))){
            val state=LaunchSplashState();state.open(true,3_000,saved);assertFalse(state.visible(3_000))
        }
    }
    @Test fun restorationBeforeTheFirstFrameStillShowsFiveVisibleSeconds() {
        val original=LaunchSplashState();original.open(true,0)
        val restored=LaunchSplashState();restored.open(true,500,original.save());restored.firstFrame(1_000)
        assertEquals(5_000L,restored.remaining(1_000))
    }
    @Test fun anotherElapsedTimeEpochCannotExtendARecoveredScreen() {
        val state=LaunchSplashState();state.open(true,100,LaunchSplashState.Saved(false,8_000_000))
        assertFalse(state.visible(100))
    }
    @Test fun callOrUpdateInterruptionBypassesNormalAndRestoredLaunches() {
        for(saved in listOf(null,LaunchSplashState.Saved(true,0),LaunchSplashState.Saved(false,4_000))){
            val state=LaunchSplashState();state.open(true,1_000,saved,interrupted=true)
            assertFalse(state.visible(1_000));assertEquals(0L,state.remaining(1_000))
        }
    }
    @Test fun internalCallSetupAndInstallerIntentsNeverShowTheScreen() {
        val state=LaunchSplashState();state.open(false,0);state.firstFrame(100)
        assertFalse(state.visible(100));assertEquals(0L,state.remaining(100))
    }
    @Test fun anIncomingCallImmediatelyReleasesAnAlreadyVisibleScreen() {
        val state=LaunchSplashState();state.open(true,0);state.firstFrame(100);state.cancel()
        assertFalse(state.visible(101));assertEquals(0L,state.remaining(101))
    }
    @Test fun aNewNormalOpenGetsANewBoundedScreenAfterPreviousDismissal() {
        val state=LaunchSplashState();state.open(true,0);state.firstFrame(100);state.cancel()
        state.open(true,10_000);state.firstFrame(10_050)
        assertEquals(5_000L,state.remaining(10_050));assertFalse(state.visible(15_050))
    }
}
