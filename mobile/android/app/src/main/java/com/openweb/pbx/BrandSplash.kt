/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/** A native content overlay, not a second Activity or a delay on service startup. */
class BrandSplash(private val activity:Activity) {
    private val state=LaunchSplashState()
    private val handler=Handler(Looper.getMainLooper())
    private var overlay:View?=null
    private var covered:View?=null
    private var coveredAccessibility=View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
    private var firstFrame:ViewTreeObserver.OnPreDrawListener?=null
    private val finish=Runnable { dismiss() }
    companion object {
        private const val SAVED="brand_splash_saved"
        private const val WAITING="brand_splash_frame"
        private const val DEADLINE="brand_splash_deadline"
        fun launcher(intent:Intent)=intent.action==Intent.ACTION_MAIN && intent.hasCategory(Intent.CATEGORY_LAUNCHER)
    }
    fun open(intent:Intent,saved:Bundle?,interrupted:Boolean) {
        val previous=if(saved?.getBoolean(SAVED)==true)LaunchSplashState.Saved(saved.getBoolean(WAITING),saved.getLong(DEADLINE))else null
        state.open(launcher(intent),SystemClock.elapsedRealtime(),previous,interrupted)
    }
    fun save(out:Bundle){val value=state.save();out.putBoolean(SAVED,true);out.putBoolean(WAITING,value.waitingForFrame);out.putLong(DEADLINE,value.deadlineMillis)}
    fun reopen(intent:Intent,interrupted:Boolean) {
        if(interrupted){dismiss();return}
        if(!state.visible(SystemClock.elapsedRealtime()))state.open(launcher(intent),SystemClock.elapsedRealtime())
        attach()
    }
    fun attach() {
        val now=SystemClock.elapsedRealtime()
        if(!state.visible(now)){dismiss();return}
        val content=activity.findViewById<ViewGroup>(android.R.id.content) ?: return
        if(overlay?.parent===content)return
        removeOverlay()
        covered=content.getChildAt(0)?.also{coveredAccessibility=it.importantForAccessibility;it.importantForAccessibility=View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS}
        val density=activity.resources.displayMetrics.density
        fun dp(value:Int)=(value*density).toInt()
        val panel=FrameLayout(activity).apply {
            id=R.id.brand_splash
            isClickable=true;isFocusable=true;isFocusableInTouchMode=true
            background=GradientDrawable(GradientDrawable.Orientation.TL_BR,intArrayOf(Color.WHITE,Color.rgb(229,244,255)))
        }
        val branding=LinearLayout(activity).apply{orientation=LinearLayout.VERTICAL;gravity=Gravity.CENTER;setPadding(dp(24),dp(24),dp(24),dp(24))}
        branding.addView(ImageView(activity).apply {
            setImageResource(R.drawable.openwebpbx_logo);scaleType=ImageView.ScaleType.FIT_CENTER;adjustViewBounds=true
            contentDescription="OpenWebPBX business communications logo"
        },LinearLayout.LayoutParams(-1,minOf(dp(170),maxOf(dp(80),activity.resources.displayMetrics.heightPixels/3))))
        branding.addView(TextView(activity).apply {
            text="Free Phone";textSize=25f;setTextColor(Color.rgb(19,67,99));setTypeface(typeface,Typeface.BOLD);gravity=Gravity.CENTER
            setPadding(0,dp(12),0,0)
        },LinearLayout.LayoutParams(-1,-2))
        panel.addView(branding,FrameLayout.LayoutParams(minOf(activity.resources.displayMetrics.widthPixels,dp(608)),-2,Gravity.CENTER))
        content.addView(panel,FrameLayout.LayoutParams(-1,-1));overlay=panel;panel.requestFocus()
        val callback=object:ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw():Boolean {
                if(panel.viewTreeObserver.isAlive)panel.viewTreeObserver.removeOnPreDrawListener(this)
                firstFrame=null;state.firstFrame(SystemClock.elapsedRealtime())
                handler.postDelayed(finish,state.remaining(SystemClock.elapsedRealtime()))
                return true
            }
        }
        firstFrame=callback;panel.viewTreeObserver.addOnPreDrawListener(callback)
    }
    fun dismiss(){state.cancel();removeOverlay()}
    fun close(){removeOverlay()}
    private fun removeOverlay() {
        handler.removeCallbacks(finish)
        overlay?.let { view ->
            firstFrame?.let{if(view.viewTreeObserver.isAlive)view.viewTreeObserver.removeOnPreDrawListener(it)}
            (view.parent as? ViewGroup)?.removeView(view)
        }
        firstFrame=null;overlay=null
        covered?.importantForAccessibility=coveredAccessibility;covered=null
    }
}
