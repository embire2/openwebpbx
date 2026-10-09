/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.app.*
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.*
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import org.json.JSONObject
import java.io.*
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipFile
import javax.net.ssl.HttpsURLConnection

internal interface UpdateTransport { fun open(url:String):InputStream }
internal class ReleaseHttp:UpdateTransport {
    override fun open(url:String):InputStream {
        var address=url
        repeat(6) {
            require(UpdateRules.trustedUrl(address))
            val connection=URL(address).openConnection() as HttpsURLConnection
            connection.connectTimeout=15000;connection.readTimeout=20000;connection.instanceFollowRedirects=false
            connection.setRequestProperty("User-Agent","OpenWebPBX-Android/${BuildConfig.VERSION_NAME}")
            val code=connection.responseCode
            if(code in listOf(301,302,303,307,308)) {
                val location=connection.getHeaderField("Location") ?: throw IOException("Missing release location")
                address=URL(URL(address),location).toString();connection.disconnect()
            } else {
                if(code!=200){connection.disconnect();throw IOException("Release unavailable")}
                return object:FilterInputStream(connection.inputStream){override fun close(){try{super.close()}finally{connection.disconnect()}}}
            }
        }
        throw IOException("Too many release redirects")
    }
}

data class UpdateSnapshot(val state:String="idle",val message:String="Updates have not been checked yet.",val release:AndroidRelease?=null,val mode:String="notify",val progress:Long=0,val total:Long=0)

/** All installation inputs are private, verified, and rechecked immediately before committing. */
class UpdateManager internal constructor(private val context:Context,private val network:UpdateTransport=ReleaseHttp()) {
    companion object {
        private var singleton:UpdateManager?=null
        @Synchronized fun get(context:Context):UpdateManager = singleton ?: UpdateManager(context.applicationContext).also{singleton=it}
        const val JOB=10401
        const val NOTIFICATION=104
    }
    private val prefs=context.getSharedPreferences("application_updates",Context.MODE_PRIVATE)
    private val directory=File(context.filesDir,"application-updates").apply{mkdirs()}
    private val apk=File(directory,"ready.apk")
    private val manifest=File(directory,"ready-manifest.json")
    private val key=context.assets.open("release-public.pem").bufferedReader().use{it.readText()}
    private val worker=Executors.newSingleThreadExecutor()
    private val busy=AtomicBoolean(false)
    private val stopped=AtomicBoolean(false)
    private val installationGeneration=AtomicInteger()
    private val main=Handler(Looper.getMainLooper())
    @Volatile var snapshot=UpdateSnapshot();private set
    @Volatile private var ready:AndroidRelease?=null
    @Volatile private var policyTrusted=false
    @Volatile private var checkSucceeded=false
    @Volatile var isInstalling=prefs.contains("session_id");private set
    var changed:(()->Unit)?=null
    private var serverVersion="1.0.3"
    private var accountBound=false
    private var mode="notify"
    private var confirmation:Intent?=null
    var foregroundActivity:Activity?=null
    private val installed get()=context.packageManager.getPackageInfo(context.packageName,0)
    fun schedule() {
        val scheduler=context.getSystemService(JobScheduler::class.java)
        scheduler.schedule(JobInfo.Builder(JOB,ComponentName(context,UpdateJob::class.java)).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPeriodic(12*60*60*1000L).setPersisted(true).build())
    }
    private fun set(state:String,message:String,release:AndroidRelease?=snapshot.release,progress:Long=0,total:Long=0) {
        snapshot=UpdateSnapshot(state,message,release,mode,progress,total)
        prefs.edit().putString("state",state).putString("message",message).apply()
        main.post{changed?.invoke()}
    }
    fun supported(release:AndroidRelease)=Build.VERSION.SDK_INT>=release.minimumSdk && (!accountBound || UpdateRules.compare(serverVersion,release.minimumServer)>=0)
    fun shouldGate(activeCall:Boolean,urgent:Boolean)=UpdateRules.gate(mode=="required" && policyTrusted,ready?.let{it.expires>System.currentTimeMillis()}==true,ready?.let{supported(it)}==true,checkSucceeded,activeCall,urgent) && !isInstalling
    fun automaticInstallAllowed()=mode=="required" && ready?.let{it.expires>System.currentTimeMillis() && supported(it)}==true && checkSucceeded && policyTrusted && prefs.getString("attempted_hash",null)!=ready?.sha256 && context.packageManager.canRequestPackageInstalls()
    fun check(download:Boolean=false,finished:(()->Unit)?=null) {
        if(!busy.compareAndSet(false,true)){finished?.invoke();return}
        stopped.set(false)
        worker.execute {
            try {
                reconcile()
                if(isInstalling)return@execute
                set("checking","Checking for updates…")
                val account=PhoneStore(context).read();accountBound=account!=null;policyTrusted=false;mode="notify";serverVersion="1.0.3"
                if(account!=null) {
                    try {
                        val policy=PhoneApi(account.getString("server"),account.getString("token")).json("updates")
                        require(policy.getInt("schema")==1 && policy.getString("channel")=="stable" && policy.getString("feed_url")==UpdateRules.FEED)
                        mode=policy.getString("mode");require(mode in listOf("notify","download","required"));serverVersion=policy.getString("server_version");UpdateRules.version(serverVersion);policyTrusted=true
                    }catch(e:ApiError){if(e.status!=404)throw e} // 1.0.3 has no policy endpoint; it cannot meet newer server minimums.
                }
                val envelope=network.open(UpdateRules.FEED).use{String(readBounded(it,UpdateRules.MAX_ENVELOPE.toLong()),Charsets.UTF_8)}
                val release=ReleaseManifest.parse(envelope,key)
                UpdateRules.sequence(release.sequence,release.digest,prefs.getLong("highest_sequence",0),prefs.getString("highest_digest","") ?: "")
                prefs.edit().putLong("highest_sequence",release.sequence).putString("highest_digest",release.digest).putLong("checked_at",System.currentTimeMillis()).commit()
                checkSucceeded=true
                if(release.versionCode<=installed.longVersionCode || UpdateRules.compare(release.version,installed.versionName ?: "0.0.0")<=0) {
                    ready=null;set("current","You have the latest available version.",null);return@execute
                }
                if(!supported(release)) {
                    ready=null;set("unsupported",if(Build.VERSION.SDK_INT<release.minimumSdk)"This update needs a newer Android version. Your current phone remains available." else "Your administrator needs to update the PBX before this phone update can be installed.",release);return@execute
                }
                if(ready?.sha256==release.sha256 && apk.isFile) { verifyApk(apk,release);ready=release;set("ready","Update ${release.version} is downloaded and verified.",release);notifyUpdate();return@execute }
                ready=null;set("available","Update ${release.version} is available.",release)
                if(download || mode in listOf("download","required")) download(release)
                else notifyUpdate()
            }catch(_:Exception){checkSucceeded=false;set("error","Updates could not be checked or verified. Your current phone is still available. Try again.")}
            finally{busy.set(false);finished?.invoke()}
        }
    }
    private fun download(release:AndroidRelease) {
        val temporary=File(directory,"download.part")
        try {
            require(directory.usableSpace>release.bytes*2+8*1024*1024)
            set("downloading","Downloading update ${release.version}…",release,0,release.bytes)
            var count=0L;var last=0L
            network.open(release.url).use{input->FileOutputStream(temporary).use{out->
                val buffer=ByteArray(65536)
                while(true){if(stopped.get() || Thread.currentThread().isInterrupted)throw InterruptedIOException();val n=input.read(buffer);if(n<0)break;count+=n;require(count<=release.bytes);out.write(buffer,0,n)
                    if(count-last>=1024*1024){last=count;set("downloading","Downloading update ${release.version}…",release,count,release.bytes)}
                };out.fd.sync()
            }}
            require(count==release.bytes);verifyApk(temporary,release)
            java.nio.file.Files.move(temporary.toPath(),apk.toPath(),java.nio.file.StandardCopyOption.REPLACE_EXISTING,java.nio.file.StandardCopyOption.ATOMIC_MOVE)
            val next=File(directory,"manifest.part");next.writeText(release.envelope);java.nio.file.Files.move(next.toPath(),manifest.toPath(),java.nio.file.StandardCopyOption.REPLACE_EXISTING,java.nio.file.StandardCopyOption.ATOMIC_MOVE)
            ready=release;set("ready","Update ${release.version} is downloaded and verified.",release,release.bytes,release.bytes);notifyUpdate()
        } finally {temporary.delete()}
    }
    internal fun verifyApk(file:File,release:AndroidRelease) {
        require(file.length()==release.bytes && release.bytes<=UpdateRules.MAX_APK)
        val hash=MessageDigest.getInstance("SHA-256");file.inputStream().use{input->val buffer=ByteArray(65536);while(true){val n=input.read(buffer);if(n<0)break;hash.update(buffer,0,n)}}
        require(hash.digest().joinToString(""){"%02x".format(it)}==release.sha256)
        ZipFile(file).use{zip->val seen=HashSet<String>();val names=zip.entries();while(names.hasMoreElements()){val n=names.nextElement().name;require(!n.startsWith('/') && n.split('/').none{it==".."} && seen.add(n))};require(Build.SUPPORTED_ABIS.any{abi->seen.any{it.startsWith("lib/$abi/")}})}
        val info=context.packageManager.getPackageArchiveInfo(file.path,PackageManager.GET_SIGNING_CERTIFICATES) ?: error("Invalid application")
        require(info.packageName==UpdateRules.PACKAGE && info.longVersionCode==release.versionCode && info.versionName==release.version)
        require(info.applicationInfo!!.minSdkVersion==release.minimumSdk && info.applicationInfo!!.minSdkVersion<=Build.VERSION.SDK_INT)
        val signers=info.signingInfo!!.apkContentsSigners;require(signers.size==1 && UpdateRules.sha256(signers[0].toByteArray())==UpdateRules.CERTIFICATE)
        val current=context.packageManager.getPackageInfo(context.packageName,PackageManager.GET_SIGNING_CERTIFICATES).signingInfo!!.apkContentsSigners
        require(current.size==1 && current[0]==signers[0])
        require(info.longVersionCode>installed.longVersionCode && UpdateRules.compare(info.versionName!!,installed.versionName ?: "0.0.0")>0)
    }
    fun stopCheck() { stopped.set(true) }
    private fun cachedRelease():AndroidRelease {
        val release=ReleaseManifest.parse(manifest.readText(),key)
        UpdateRules.sequence(release.sequence,release.digest,prefs.getLong("highest_sequence",0),prefs.getString("highest_digest","") ?: "")
        return release
    }
    private fun reconcile() {
        if(prefs.getLong("target_version",0)<=installed.longVersionCode && prefs.contains("target_version")) { complete();return }
        val sessionId=prefs.getInt("session_id",-1)
        if(sessionId>=0) {
            val session=context.packageManager.packageInstaller.getSessionInfo(sessionId)
            if(session==null) { isInstalling=false;prefs.edit().remove("session_id").remove("nonce").remove("target_version").apply() }
            else { isInstalling=true;set("confirmation","Finish Android’s update confirmation, or cancel and retry the update.") }
        }
        if(manifest.isFile && apk.isFile) try { val release=cachedRelease();verifyApk(apk,release);ready=release }catch(_:Exception){ready=null;apk.delete();manifest.delete()}
    }
    fun install(activity:Activity) {
        if(PhoneService.instance?.call!=null){set("ready","Finish your call first. The verified update will wait.");return}
        val release=ready ?: run{check(true);return}
        if(!context.packageManager.canRequestPackageInstalls()) {
            set("permission","Allow Android to install updates from OpenWeb PBX, then return here and choose Install update.",release)
            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:${context.packageName}")));return
        }
        if(!busy.compareAndSet(false,true))return
        val generation=installationGeneration.incrementAndGet()
        worker.execute {
            var staged=-1
            try {
                val verified=cachedRelease();require(verified.sha256==release.sha256 && supported(verified));verifyApk(apk,verified)
                val installer=context.packageManager.packageInstaller
                val old=prefs.getInt("session_id",-1);if(old>=0)try{installer.abandonSession(old)}catch(_:Exception){}
                val params=PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(context.packageName);params.setSize(verified.bytes)
                if(Build.VERSION.SDK_INT>=31)params.setRequireUserAction(if(mode=="required")PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED else PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                val id=installer.createSession(params);staged=id
                installer.openSession(id).use{session->
                    session.openWrite("base.apk",0,verified.bytes).use{output->apk.inputStream().use{it.copyTo(output)};session.fsync(output)}
                }
                // Staging and cryptographic checks run away from the UI; a call can continue throughout.
                main.post {
                    try {
                        if(generation!=installationGeneration.get() || activity.isFinishing || activity.isDestroyed || foregroundActivity!==activity || PhoneService.instance?.call!=null){installer.abandonSession(id);set("ready","The update is ready and will wait until you return and finish your call.",verified);return@post}
                        commit(verified,id)
                    }catch(_:Exception){try{installer.abandonSession(id)}catch(_:Exception){};isInstalling=false;set("error","Android could not start the update. Your account is safe. Try again.")}
                    finally{busy.set(false)}
                }
            }catch(_:Exception){if(staged>=0)try{context.packageManager.packageInstaller.abandonSession(staged)}catch(_:Exception){};busy.set(false);isInstalling=false;ready=null;checkSucceeded=false;set("error","The downloaded update could not be verified. Your current phone is still available. Check again.")}
        }
    }
    private fun commit(release:AndroidRelease,id:Int) {
        check(PhoneService.instance?.call==null)
        UpdateRules.sequence(release.sequence,release.digest,prefs.getLong("highest_sequence",0),prefs.getString("highest_digest","") ?: "")
        check(release.expires>System.currentTimeMillis())
        val installer=context.packageManager.packageInstaller;val nonce=UUID.randomUUID().toString()
        installer.openSession(id).use{session->
            // On the main thread, block new calls before stopping the service. No existing call is interrupted.
            isInstalling=true;prefs.edit().putInt("session_id",id).putString("nonce",nonce).putLong("target_version",release.versionCode).putString("attempted_hash",release.sha256).commit()
            context.stopService(Intent(context,PhoneService::class.java))
            set("installing","Android is installing the update. Your account will be kept.",release)
            val status=Intent(context,UpdateStatusReceiver::class.java).setAction("com.openweb.pbx.UPDATE_STATUS").setData(Uri.parse("openwebpbx-update://session/$id/$nonce"))
            val flags=PendingIntent.FLAG_UPDATE_CURRENT or if(Build.VERSION.SDK_INT>=31)PendingIntent.FLAG_MUTABLE else 0
            session.commit(PendingIntent.getBroadcast(context,id,status,flags).intentSender)
        }
    }
    internal fun installResult(intent:Intent) {
        val id=prefs.getInt("session_id",-1);val nonce=prefs.getString("nonce",null) ?: return
        if(intent.data.toString()!="openwebpbx-update://session/$id/$nonce" || intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID,-1)!=id)return
        when(intent.getIntExtra(PackageInstaller.EXTRA_STATUS,PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION") val action=intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                confirmation=action;isInstalling=true;set("confirmation","Android needs your confirmation to install the update. Your account will be kept.")
                val visible=foregroundActivity
                if(visible!=null && !visible.isFinishing && PhoneService.instance?.call==null)try{visible.startActivity(action);confirmation=null}catch(_:Exception){notifyUpdate()}
                else notifyUpdate()
            }
            PackageInstaller.STATUS_SUCCESS -> complete()
            else -> {isInstalling=false;confirmation=null;prefs.edit().remove("session_id").remove("nonce").remove("target_version").apply();set("ready","The update was not installed. Your current version and account are safe. You can try again.");notifyUpdate()}
        }
    }
    fun continueInstall(activity:Activity) {
        if(PhoneService.instance?.call!=null)return
        val action=confirmation
        if(action!=null){activity.startActivity(action);confirmation=null}
        else {isInstalling=false;install(activity)}
    }
    fun cancelInstall() {
        installationGeneration.incrementAndGet()
        ready?.let{prefs.edit().putString("attempted_hash",it.sha256).apply()}
        val id=prefs.getInt("session_id",-1);if(id>=0)try{context.packageManager.packageInstaller.abandonSession(id)}catch(_:Exception){}
        isInstalling=false;confirmation=null;prefs.edit().remove("session_id").remove("nonce").remove("target_version").apply();set("ready","Installation paused. Your current phone is available; the verified download is kept.")
    }
    internal fun complete() {
        isInstalling=false;confirmation=null;ready=null;apk.delete();manifest.delete();prefs.edit().remove("session_id").remove("nonce").remove("target_version").putLong("last_installed",installed.longVersionCode).apply()
        set("installed","OpenWeb PBX ${installed.versionName} is installed. Open the phone to reconnect.",null);notifyUpdate();schedule()
        val visible=foregroundActivity
        if(visible!=null && !visible.isFinishing)visible.startActivity(Intent(visible,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        // A background receiver does not bypass Android's activity-launch or microphone restrictions.
    }
    private fun notifyUpdate() {
        val manager=context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("updates","App updates",NotificationManager.IMPORTANCE_DEFAULT))
        val open=PendingIntent.getActivity(context,NOTIFICATION,Intent(context,MainActivity::class.java).putExtra("show_updates",true),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        try{manager.notify(NOTIFICATION,Notification.Builder(context,"updates").setSmallIcon(R.drawable.ic_phone).setContentTitle("OpenWeb PBX update").setContentText(snapshot.message).setContentIntent(open).setAutoCancel(true).build())}catch(_:SecurityException){}
    }
    private fun readBounded(input:InputStream,limit:Long):ByteArray { val out=ByteArrayOutputStream();val buffer=ByteArray(8192);while(true){val n=input.read(buffer);if(n<0)break;require(out.size()+n<=limit);out.write(buffer,0,n)};return out.toByteArray() }
}
