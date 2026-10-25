/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

/** Branding uses elapsed time only. It never controls calling, authentication or updates. */
class LaunchSplashState {
    data class Saved(val waitingForFrame:Boolean, val deadlineMillis:Long)
    companion object { const val DURATION_MILLIS=5_000L }
    private var waitingForFrame=false
    private var deadlineMillis=0L

    fun open(launcher:Boolean, now:Long, restored:Saved?=null, interrupted:Boolean=false) {
        cancel()
        if(!launcher || interrupted)return
        if(restored==null){waitingForFrame=true;return}
        waitingForFrame=restored.waitingForFrame
        // Process restoration after a reboot must not reuse a different elapsed-time epoch.
        if(!waitingForFrame && restored.deadlineMillis>now && restored.deadlineMillis-now<=DURATION_MILLIS)
            deadlineMillis=restored.deadlineMillis
    }
    fun firstFrame(now:Long){if(waitingForFrame){waitingForFrame=false;deadlineMillis=now+DURATION_MILLIS}}
    fun visible(now:Long)=waitingForFrame || deadlineMillis>now
    fun remaining(now:Long)=if(waitingForFrame)DURATION_MILLIS else (deadlineMillis-now).coerceAtLeast(0)
    fun save()=Saved(waitingForFrame,deadlineMillis)
    fun cancel(){waitingForFrame=false;deadlineMillis=0L}
}
