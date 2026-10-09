/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.junit.Assert.*
import org.junit.Test

class UpdatePresentationTest {
    private fun state(stage:String,mode:String="notify",progress:Long=0,total:Long=0)=UpdateSnapshot(state=stage,mode=mode,progress=progress,total=total,displayVersion="9.9.9",releaseKey="store-or-direct-release")
    @Test fun downloadAndVerificationCannotOfferInstall(){
        for(stage in listOf("downloading","verifying","installing","checking")){
            val view=UpdatePresentation.describe(state(stage),false)
            assertFalse(stage,view.actionEnabled);assertNotEquals("Install update",view.action)
        }
        val download=UpdatePresentation.describe(state("downloading","required",10485760,41943040),false)
        assertEquals(25,download.percent);assertTrue(download.detail.contains("10.0 of 40.0 MB"));assertTrue(download.required)
        val verifying=UpdatePresentation.describe(state("verifying","required",100,100),false)
        assertNull(verifying.percent);assertTrue(verifying.detail.contains("before installation"))
    }
    @Test fun activeCallsDeferInstallAndEveryAutomaticPrompt(){
        for(stage in listOf("ready","permission","confirmation")){
            val view=UpdatePresentation.describe(state(stage,"required"),true)
            assertFalse(view.actionEnabled);assertEquals("After your call",view.action);assertTrue(view.detail.contains("Finish your call"))
        }
        assertNull(UpdatePresentation.promptKey(state("available"),true,false,false))
        assertNull(UpdatePresentation.promptKey(state("ready"),false,true,false))
        assertNull(UpdatePresentation.promptKey(state("ready"),false,false,true))
        assertTrue(UpdatePresentation.describe(state("available"),true).actionEnabled) // Downloading does not interrupt a call.
    }
    @Test fun bothDistributionChannelsHaveVisibleVersionAndActions(){
        val available=state("available")
        assertNull(available.release) // Play metadata never pretends to be a verified direct APK manifest.
        assertTrue(UpdatePresentation.describe(available,false).title.contains("9.9.9"))
        assertEquals("Download update",UpdatePresentation.describe(available,false).action)
        assertNotNull(UpdatePresentation.promptKey(available,false,false,false))
        val ready=state("ready","required")
        assertEquals("Install update",UpdatePresentation.describe(ready,false).action)
        assertTrue(UpdatePresentation.describe(ready,false).title.startsWith("Required update"))
        val play=available.copy(actionLabel="Open Google Play",gateTitle="Update your phone in Google Play",gateMessage="Google Play downloads and installs the update.")
        assertEquals("Open Google Play",UpdatePresentation.describe(play,false).action)
        assertFalse(play.gateMessage!!.contains("complete download"))
    }
    @Test fun errorRecoveryAndProgressRemainBounded(){
        assertEquals("Try again",UpdatePresentation.describe(state("error"),false).action)
        assertEquals(100,UpdatePresentation.describe(state("downloading",progress=200,total=100),false).percent)
        assertEquals(0,UpdatePresentation.describe(state("downloading",progress=-1,total=100),false).percent)
        assertNull(UpdatePresentation.describe(state("downloading"),false).percent)
        assertNull(UpdatePresentation.promptKey(state("error"),false,false,false))
    }
}
