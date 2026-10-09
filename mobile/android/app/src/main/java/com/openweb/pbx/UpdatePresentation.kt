/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import java.util.Locale

data class UpdateViewState(val title:String,val detail:String,val action:String,val actionEnabled:Boolean,val showProgress:Boolean,val percent:Int?,val required:Boolean)

/** UI copy and actions never grant installation permission or bypass verification. */
object UpdatePresentation {
    fun describe(state:UpdateSnapshot,activeCall:Boolean):UpdateViewState {
        val version=state.displayVersion?.let{" $it"} ?: ""
        val required=state.mode=="required"
        val percent=if(state.total>0)((state.progress.coerceIn(0,state.total)*100)/state.total).toInt() else null
        val ready=state.state in listOf("ready","permission","confirmation")
        val title=when(state.state){
            "store"->"Google Play updates"
            "available"->if(required)"Required update$version" else "New update$version"
            "downloading"->if(required)"Downloading required update$version" else "Downloading update$version"
            "verifying"->"Checking the complete download"
            "ready"->if(required)"Required update ready$version" else "Update ready$version"
            "permission","confirmation"->"Finish installing update$version"
            "installing"->"Installing update$version"
            "error"->"Update needs attention"
            "unsupported"->"Update needs your administrator"
            "checking"->"Checking for updates…"
            "installed","current"->"Your phone is up to date"
            else->"App updates"
        }
        val detail=when {
            activeCall && ready->"Your update is ready. Finish your call to install it."
            state.state=="downloading" && state.total>0->"${megabytes(state.progress.coerceIn(0,state.total))} of ${megabytes(state.total)} MB · $percent%"
            state.state=="verifying"->"Downloaded. Checking the complete update before installation."
            state.state=="ready"->"Downloaded and verified. Your account and settings will be kept."
            else->state.message
        }
        val action=state.actionLabel ?: when(state.state){
            "available"->"Download update"
            "ready","permission","confirmation"->if(activeCall)"After your call" else "Install update"
            "downloading"->"Downloading…"
            "verifying"->"Checking download…"
            "installing"->"Installing…"
            "checking"->"Checking…"
            "error"->"Try again"
            else->"Check for updates"
        }
        return UpdateViewState(title,detail,action,state.state !in listOf("downloading","verifying","installing","checking") && !(activeCall&&ready),state.state in listOf("downloading","verifying","installing","checking"),if(state.state=="downloading")percent else null,required)
    }
    fun promptKey(state:UpdateSnapshot,activeCall:Boolean,gate:Boolean,urgent:Boolean):String? {
        if(activeCall||gate||urgent||state.releaseKey==null||state.state !in listOf("available","ready"))return null
        return "${state.releaseKey}:${state.state}"
    }
    private fun megabytes(bytes:Long)=String.format(Locale.ROOT,"%.1f",bytes/1048576.0)
}
