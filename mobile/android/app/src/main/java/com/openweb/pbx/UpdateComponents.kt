/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx
import android.app.job.JobParameters
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class UpdateJob:JobService() {
    override fun onStartJob(params:JobParameters):Boolean {UpdateManager.get(this).check{jobFinished(params,false)};return true}
    override fun onStopJob(params:JobParameters):Boolean {UpdateManager.get(this).stopCheck();return true}
}
class UpdateStatusReceiver:BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {UpdateManager.get(context).installResult(intent)}
}
class UpdateReplacedReceiver:BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {if(intent.action==Intent.ACTION_MY_PACKAGE_REPLACED)UpdateManager.get(context).complete()}
}
