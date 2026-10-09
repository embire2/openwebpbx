/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/** Store distribution never downloads executable code or invokes an APK installer. */
class UpdateManager internal constructor(private val context:Context) {
    companion object {
        private var singleton:UpdateManager?=null
        @Synchronized fun get(context:Context)=singleton ?: UpdateManager(context.applicationContext).also{singleton=it}
        const val JOB=10702
        const val NOTIFICATION=107
        const val STORE_URL="https://play.google.com/store/apps/details?id=com.openweb.pbx"
    }
    private val prefs=context.getSharedPreferences("play_application_updates",Context.MODE_PRIVATE)
    // Share the monotonic trust floor when moving between distribution variants.
    private val trust=context.getSharedPreferences("application_updates",Context.MODE_PRIVATE)
    private val key=context.assets.open("release-public.pem").bufferedReader().use{it.readText()}
    private val worker=Executors.newSingleThreadExecutor()
    private val busy=AtomicBoolean(false)
    private val stopped=AtomicBoolean(false)
    private val main=Handler(Looper.getMainLooper())
    @Volatile var snapshot=UpdateSnapshot();private set
    @Volatile private var available:PlayRelease?=null
    @Volatile private var mode="notify"
    @Volatile private var serverVersion:String?=null
    @Volatile private var policyChecked=0L
    @Volatile private var policyAccount=""
    val isInstalling=false
    var changed:(()->Unit)?=null
    var foregroundActivity:Activity?=null
    val installationHelp="Google Play downloads and installs this edition. Finish your call before opening its update page, then choose Open in Google Play when installation finishes. Your account is kept."
    private val installed get()=context.packageManager.getPackageInfo(context.packageName,0)

    init {
        // A same-signature direct-to-store replacement keeps its account and trust
        // floor, but must not leave the old direct download job/notification active.
        context.getSystemService(JobScheduler::class.java).cancel(10401)
        context.getSystemService(NotificationManager::class.java).cancel(104)
        val directory=File(context.filesDir,"application-updates")
        if(directory.canonicalFile.parentFile==context.filesDir.canonicalFile) {
            for(name in listOf("ready.apk","ready-manifest.json","download.part","manifest.part")) {
                val file=File(directory,name)
                if(file.isFile && file.canonicalFile.parentFile==directory.canonicalFile)file.delete()
            }
        }
        restore()
        if(snapshot.state=="idle")set("store","Google Play manages updates for this edition. Open its store page to check availability.")
    }
    fun schedule() {
        context.getSystemService(JobScheduler::class.java).schedule(JobInfo.Builder(JOB,ComponentName(context,PlayUpdateJob::class.java)).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPeriodic(12*60*60*1000L).setPersisted(true).build())
    }
    private fun identity():String {
        val account=PhoneStore(context).read() ?: return ""
        return UpdateRules.sha256((account.getString("server")+"\u0000"+account.getString("token")).toByteArray(Charsets.UTF_8))
    }
    private fun policyTrusted()=PlayReleaseRules.policyFresh(policyChecked,System.currentTimeMillis(),policyAccount,identity())
    private fun freshCandidate():PlayRelease?=available?.takeIf{it.expires>System.currentTimeMillis() && PlayReleaseRules.newer(it,installed.versionName ?: "0.0.0",installed.longVersionCode)}
    private fun supported(release:PlayRelease)=PlayReleaseRules.supported(release,Build.VERSION.SDK_INT,serverVersion)
    fun shouldGate(activeCall:Boolean,urgent:Boolean)=UpdateRules.gate(mode=="required" && policyTrusted(),freshCandidate()!=null,freshCandidate()?.let{supported(it)}==true,true,activeCall,urgent)
    fun automaticInstallAllowed()=false // Google Play and its user control installation.
    private fun set(state:String,message:String) {
        val candidate=freshCandidate()
        val trustedMode=if(policyTrusted())mode else "notify"
        snapshot=UpdateSnapshot(state,message,mode=trustedMode,displayVersion=candidate?.version,releaseKey=candidate?.let{"play:${it.versionCode}:${it.version}"},actionLabel=if(state in listOf("store","available","current","error"))"Open Google Play" else null,
            gateTitle="Update your phone in Google Play",gateMessage=candidate?.let{"Your organisation requires version ${it.version}. Open Google Play to download and install it, then reopen this app. Urgent calling remains available."},
            policyMessage="Google Play controls download and installation. This app waits for your call to finish before opening Google Play; it cannot control a store update once you leave the app.")
        main.post{changed?.invoke()}
        if(state=="available")notifyUpdate() else if(state in listOf("current","store"))context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION)
    }
    private fun restore() {
        try {
            val envelope=prefs.getString("envelope",null) ?: return
            val feed=PlayReleaseManifest.parse(envelope,key)
            UpdateRules.sequence(feed.verified.sequence,feed.verified.digest,trust.getLong("highest_sequence",0),trust.getString("highest_digest","") ?: "")
            available=feed.release
            policyChecked=prefs.getLong("policy_checked",0);policyAccount=prefs.getString("policy_account","") ?: ""
            mode=prefs.getString("mode","notify") ?: "notify";serverVersion=prefs.getString("server_version",null)
            require(mode in listOf("notify","download","required"));serverVersion?.let{UpdateRules.version(it)}
            present()
        }catch(_:Exception){available=null;mode="notify";policyAccount="";set("store","Check Google Play for updates to this edition.")}
    }
    private fun present() {
        val candidate=freshCandidate()
        when {
            available==null->set("store","Check Google Play for updates to this edition. A website release does not mean it is published in Google Play yet.")
            candidate==null->set("current","You have the latest published Google Play version listed by OpenWeb PBX.")
            !supported(candidate)->set("unsupported",if(Build.VERSION.SDK_INT<candidate.minimumSdk)"The published update needs a newer Android version. Your current phone remains available." else "Your administrator needs to update the PBX before this phone update can be used.")
            else->set("available","Version ${candidate.version} is published in Google Play. Open its page to download and install the update.")
        }
    }
    fun check(download:Boolean=false,finished:(()->Unit)?=null) {
        if(download){main.post{foregroundActivity?.let{install(it)}};finished?.invoke();return}
        if(!busy.compareAndSet(false,true)){finished?.invoke();return}
        stopped.set(false)
        worker.execute {
            try {
                set("checking","Checking published Google Play updates…")
                val account=PhoneStore(context).read();val accountId=identity()
                var nextMode="notify";var nextServer:String?=null;var nextChecked=0L
                if(account!=null)try {
                    val policy=PhoneApi(account.getString("server"),account.getString("token")).json("updates")
                    require(policy.getInt("schema")==1 && policy.getString("channel")=="stable" && policy.getString("feed_url")==UpdateRules.FEED)
                    nextMode=policy.getString("mode");require(nextMode in listOf("notify","download","required"))
                    nextServer=policy.getString("server_version");UpdateRules.version(nextServer);nextChecked=System.currentTimeMillis()
                }catch(e:ApiError){if(e.status!=404)throw e;nextServer="1.0.3"}
                val envelope=readFeed();val feed=PlayReleaseManifest.parse(envelope,key)
                if(stopped.get())return@execute
                require(accountId==identity())
                UpdateRules.sequence(feed.verified.sequence,feed.verified.digest,trust.getLong("highest_sequence",0),trust.getString("highest_digest","") ?: "")
                kotlin.check(trust.edit().putLong("highest_sequence",feed.verified.sequence).putString("highest_digest",feed.verified.digest).commit())
                kotlin.check(prefs.edit().putString("envelope",envelope).putString("mode",nextMode).putString("server_version",nextServer).putLong("policy_checked",nextChecked).putString("policy_account",accountId).commit())
                available=feed.release;mode=nextMode;serverVersion=nextServer;policyChecked=nextChecked;policyAccount=accountId;present()
            }catch(e:Exception){
                if(e is ApiError && e.status in listOf(401,403)){policyAccount="";prefs.edit().remove("policy_account").apply()}
                if(!policyTrusted()){mode="notify";policyAccount=""}
                set("error","Published updates could not be checked. Try again, or check Google Play. Your account is kept.")
            }finally{busy.set(false);finished?.invoke()}
        }
    }
    fun install(activity:Activity) {
        if(PhoneService.instance?.call!=null){set(if(freshCandidate()==null)"store" else "available","Finish your call before opening Google Play.");return}
        if(activity.isFinishing || activity.isDestroyed)return
        val intent=Intent(Intent.ACTION_VIEW,Uri.parse(STORE_URL)).setPackage("com.android.vending")
        try {activity.startActivity(intent)}catch(_:ActivityNotFoundException){
            try{activity.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse(STORE_URL)))}catch(_:ActivityNotFoundException){set("error","Google Play could not be opened. Open its website or install the Play Store, then try again.")}
        }
    }
    fun continueInstall(activity:Activity)=install(activity)
    fun cancelInstall(){present()} // A store-managed installation cannot be cancelled from this app.
    fun stopCheck(){stopped.set(true)}
    private fun readFeed():String {
        var address=UpdateRules.FEED
        repeat(6) {
            require(UpdateRules.trustedUrl(address))
            val c=URL(address).openConnection() as HttpsURLConnection
            c.connectTimeout=15000;c.readTimeout=20000;c.instanceFollowRedirects=false
            c.setRequestProperty("User-Agent","OpenWebPBX-Android-Play/${BuildConfig.VERSION_NAME}")
            try {
                if(c.responseCode in listOf(301,302,303,307,308)){address=URL(URL(address),c.getHeaderField("Location") ?: throw IOException("Missing release location")).toString()}
                else {
                    if(c.responseCode!=200 || c.contentLengthLong>UpdateRules.MAX_ENVELOPE)throw IOException("Release unavailable")
                    return c.inputStream.use { input->val out=ByteArrayOutputStream();val buffer=ByteArray(8192);while(true){val n=input.read(buffer);if(n<0)break;require(out.size()+n<=UpdateRules.MAX_ENVELOPE);out.write(buffer,0,n)};String(out.toByteArray(),Charsets.UTF_8) }
                }
            }finally{c.disconnect()}
        }
        throw IOException("Too many release redirects")
    }
    private fun notifyUpdate() {
        val manager=context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("updates","App updates",NotificationManager.IMPORTANCE_DEFAULT))
        val open=PendingIntent.getActivity(context,NOTIFICATION,Intent(context,MainActivity::class.java).putExtra("show_updates",true).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notice=Notification.Builder(context,"updates").setSmallIcon(R.drawable.ic_phone).setContentTitle(if(snapshot.mode=="required")"Required update in Google Play" else "Update in Google Play").setContentText(snapshot.message).setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(true).build()
        try{manager.notify(NOTIFICATION,notice)}catch(_:SecurityException){}
    }
}
