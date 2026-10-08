/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx
import android.app.Application
import org.linphone.core.Factory
import org.linphone.core.LogLevel
import org.linphone.core.LogCollectionState
class PhoneApplication: Application() {
    override fun onCreate() {
        super.onCreate()
        Factory.instance().apply {
            enableLogCollection(LogCollectionState.Disabled)
            enableLogcatLogs(false)
            loggingService.setLogLevel(LogLevel.Fatal)
            loggingService.setStackTraceDumpsEnabled(false)
        }
    }
}
