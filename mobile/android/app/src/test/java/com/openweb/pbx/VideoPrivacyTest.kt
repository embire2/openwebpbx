/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.junit.Assert.*
import org.junit.Test

class VideoPrivacyTest {
    @Test fun onlyVisibleUnlockedPermissionGrantedInteractiveScreenMayCapture(){
        for(visible in listOf(false,true))for(unlocked in listOf(false,true))for(interactive in listOf(false,true))for(permission in listOf(false,true))
            assertEquals("Camera privacy: $visible/$unlocked/$interactive/$permission",visible && unlocked && interactive && permission,VideoPrivacy.mayCapture(visible,unlocked,interactive,permission))
    }
    @Test fun inactiveOrRejectedVideoIsNotAnIncomingCameraRequest(){
        for(direction in org.linphone.core.MediaDirection.values()){
            assertFalse(VideoPrivacy.activeVideoOffer(false,direction))
            assertEquals(direction in listOf(org.linphone.core.MediaDirection.SendRecv,org.linphone.core.MediaDirection.SendOnly,org.linphone.core.MediaDirection.RecvOnly),VideoPrivacy.activeVideoOffer(true,direction))
        }
        assertFalse(VideoPrivacy.activeVideoOffer(true,null))
    }
    @Test fun switchingCameraDoesNotOfferSdkSyntheticSources(){
        assertFalse(VideoPrivacy.cameraDevice("StaticImage: Static picture"))
        assertFalse(VideoPrivacy.cameraDevice("Mire: synthetic video"))
        assertTrue(VideoPrivacy.cameraDevice("Android Camera2: Front facing camera id: 1"))
        assertTrue(VideoPrivacy.cameraDevice("Android Camera2: Back facing camera id: 0"))
    }
}
