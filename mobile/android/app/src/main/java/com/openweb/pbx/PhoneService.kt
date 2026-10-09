/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.os.*
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import org.linphone.core.*
import java.security.KeyStore
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors

class PhoneService: Service() {
    companion object { var instance: PhoneService? = null; private set; var changed: (() -> Unit)? = null }
    var status = "Connecting…"; private set
    var call: Call? = null; private set
    var callLabel = ""; private set
    var lastCallMessage = ""; private set
    var lastDialled = ""; private set
    private var endedLocally = false
    var muted = false; private set
    var speaker = false; private set
    var core: Core? = null; private set
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var callId = ""
    private var startedAt = ""
    private var incoming = false
    private var answered = false
    private var account: JSONObject? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val api: PhoneApi? get() = account?.let { PhoneApi(it.getString("server"), it.getString("token")) }

    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate(); instance = this
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("connection", "Phone connection", NotificationManager.IMPORTANCE_LOW))
        manager.createNotificationChannel(NotificationChannel("calls", "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply { lockscreenVisibility = Notification.VISIBILITY_PRIVATE })
        connectionForeground()
        try { connect() } catch (_: Exception) { status = "Could not connect. Reopen the app to try again."; publish() }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "hangup") call?.terminate()
        return START_NOT_STICKY // A user must reopen the app after Android stops it; no fake push promise.
    }
    private fun connect() {
        account = PhoneStore(this).read() ?: run { stopSelf(); return }
        val sip = account!!.getJSONObject("sip")
        require(sip.getString("transport").equals("tls", true) && sip.getString("media_encryption").equals("srtp", true))
        val factory = Factory.instance()
        // In-memory configuration prevents the SIP password being persisted by liblinphone.
        val config = factory.createConfigFromString("[sip]\nstore_auth_info=0\n[storage]\nbackend=null\n")
        val c = factory.createCoreWithConfig(config, applicationContext); core = c
        c.isAutoIterateEnabled = true
        c.setUserAgent("OpenWebPBX-Android", BuildConfig.VERSION_NAME)
        c.verifyServerCertificates(true); c.verifyServerCn(true)
        val systemTrust = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
        val pem = StringBuilder()
        for (alias in systemTrust.aliases()) {
            if (!alias.startsWith("system:")) continue
            pem.append("-----BEGIN CERTIFICATE-----\n").append(Base64.encodeToString(systemTrust.getCertificate(alias).encoded, Base64.NO_WRAP).chunked(64).joinToString("\n")).append("\n-----END CERTIFICATE-----\n")
        }
        if (pem.isNotEmpty()) c.setRootCaData(pem.toString())
        c.mediaEncryption = MediaEncryption.SRTP; c.isMediaEncryptionMandatory = true
        c.isVideoCaptureEnabled = false; c.isVideoDisplayEnabled = false
        c.isEchoCancellationEnabled = true
        // The SDK owns ringing and audio focus together. A second app ringtone
        // would compete with its call audio focus when an incoming call answers.
        c.isNativeRingingEnabled = true
        c.config.setBool("sip", "use_rfc2833", true)
        c.config.setBool("sip", "use_info", false)
        c.config.setBool("rtp", "symmetric", true)
        c.addListener(object: CoreListenerStub() {
            override fun onAccountRegistrationStateChanged(core: Core, a: Account, state: RegistrationState, message: String) {
                status = when(state) { RegistrationState.Ok -> "Ready for calls"; RegistrationState.Progress -> "Connecting…"; RegistrationState.Failed -> "Connection unavailable — check your network"; else -> "Disconnected" }
                publish()
            }
            override fun onCallStateChanged(core: Core, current: Call, state: Call.State, message: String) {
                if (state == Call.State.IncomingReceived || state == Call.State.OutgoingInit) {
                    if(UpdateManager.get(this@PhoneService).isInstalling) { current.decline(Reason.Busy); return }
                    if (call != null && call?.nativePointer != current.nativePointer) { current.decline(Reason.Busy); return }
                    lastCallMessage = ""; endedLocally = false
                    call = current; callId = UUID.randomUUID().toString(); startedAt = Instant.now().toString()
                    incoming = state == Call.State.IncomingReceived; answered = false; muted = false; speaker = false
                    callLabel = current.remoteAddress.username ?: "Unknown caller"
                }
                if (call?.nativePointer != current.nativePointer) return
                if (state == Call.State.StreamsRunning) { speaker = current.outputAudioDevice?.type == AudioDevice.Type.Speaker; answered = true; microphoneForeground(); acquireCallLock() }
                if (state == Call.State.End || state == Call.State.Error) {
                    lastCallMessage = if (!incoming && !answered && !endedLocally) CallFeedback.failure(current.errorInfo.protocolCode) else if(incoming && !answered) "Missed call" else "Call ended"
                    recordCall(current.duration)
                    call = null; callLabel = ""; core.isMicEnabled = true; releaseCallLock()
                    getSystemService(NotificationManager::class.java).cancel(11)
                    connectionForeground()
                }
                if (state == Call.State.IncomingReceived) notifyIncoming()
                publish()
            }
        })
        c.start()
        val transports = c.transports
        transports.udpPort = 0; transports.tcpPort = 0; transports.tlsPort = -1
        c.transports = transports
        val domain = sip.getString("domain"); val username = sip.getString("username")
        val auth = sip.optString("auth_username", username)
        c.addAuthInfo(factory.createAuthInfo(username, auth, sip.getString("password"), null, domain, domain))
        val params = c.createAccountParams()
        params.identityAddress = factory.createAddress("sip:$username@$domain")
        val server = factory.createAddress("sip:${sip.getString("server")}:${sip.optInt("port",5061)};transport=tls")!!
        params.serverAddress = server; params.setRoutesAddresses(arrayOf(server)); params.isOutboundProxyEnabled = true
        params.isRegisterEnabled = true; params.expires = 300
        val a = c.createAccount(params); c.addAccount(a); c.defaultAccount = a
        flushPending()
    }
    private fun notification(): Notification = Notification.Builder(this, "connection")
        .setSmallIcon(com.openweb.pbx.R.drawable.ic_phone).setContentTitle("OpenWeb PBX")
        .setContentText(if (call != null) "Call in progress" else status)
        .setOngoing(true).setVisibility(Notification.VISIBILITY_PRIVATE)
        .setContentIntent(openIntent()).build()
    private fun openIntent(): PendingIntent = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun notifyIncoming() {
        val decline = PendingIntent.getService(this, 2, Intent(this, PhoneService::class.java).setAction("hangup"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val note = Notification.Builder(this, "calls").setSmallIcon(com.openweb.pbx.R.drawable.ic_phone)
            .setContentTitle("Incoming call").setContentText(callLabel).setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setOngoing(true).setContentIntent(openIntent())
            .addAction(Notification.Action.Builder(null, "Open to answer", openIntent()).build())
            .addAction(Notification.Action.Builder(null, "Decline", decline).build()).build()
        getSystemService(NotificationManager::class.java).notify(11, note)
    }
    private fun publish() { getSystemService(NotificationManager::class.java).notify(10, notification()); changed?.invoke() }
    private fun connectionForeground() {
        if(Build.VERSION.SDK_INT >=29) startForeground(10, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE) else startForeground(10,notification())
    }
    private fun microphoneForeground() {
        if(Build.VERSION.SDK_INT >=30) startForeground(10, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
    }
    private fun acquireCallLock() {
        if (wakeLock == null) wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OpenWebPBX:call").apply { acquire(4 * 60 * 60 * 1000L) }
    }
    private fun releaseCallLock() { wakeLock?.let { if(it.isHeld) it.release() }; wakeLock = null }
    fun dial(raw: String) {
        check(!UpdateManager.get(this).isInstalling) { "Finish or cancel the update before making a call" }
        check(call == null) { "Finish your current call first" }
        val number = Enrollment.number(raw); val c = core ?: error("Phone is still connecting")
        check(c.defaultAccount?.state == RegistrationState.Ok) { "Wait until the phone is ready for calls" }
        lastDialled = number; lastCallMessage = ""
        microphoneForeground()
        val domain = account!!.getJSONObject("sip").getString("domain")
        val params = c.createCallParams(null)!!; params.isVideoEnabled = false; params.mediaEncryption = MediaEncryption.SRTP
        check(c.inviteAddressWithParams(Factory.instance().createAddress("sip:$number@$domain")!!, params) != null) { "The call could not start" }
    }
    fun answer() {
        val c = core ?: return; val active = call ?: return
        microphoneForeground()
        val params = c.createCallParams(active)!!; params.isVideoEnabled = false; params.mediaEncryption = MediaEncryption.SRTP
        active.acceptWithParams(params); getSystemService(NotificationManager::class.java).cancel(11)
    }
    fun hangup() { endedLocally = true; call?.terminate() }
    fun dismissCallMessage() { lastCallMessage=""; publish() }
    fun reconnect() {
        check(call==null) { "Finish your call before reconnecting" }
        core?.refreshRegisters(); status="Connecting…"; publish()
    }
    fun mute() { muted = !muted; core?.isMicEnabled = !muted; publish() }
    fun hold() { if(call?.state == Call.State.Paused) call?.resume() else call?.pause(); publish() }
    fun dtmf(digit: Char) { if (digit in "0123456789*#") call?.sendDtmf(digit) }
    fun speaker() {
        val c = core ?: return
        val type = if(speaker) AudioDevice.Type.Earpiece else AudioDevice.Type.Speaker
        val device = c.audioDevices.firstOrNull { it.type == type } ?: error(if(speaker) "This device has no earpiece. Choose an audio device in Settings." else "A speaker is not available on this device.")
        c.outputAudioDevice = device; call?.outputAudioDevice = device; speaker = !speaker
        publish()
    }
    fun audioDevices(): List<AudioDevice> = core?.extendedAudioDevices?.filter { it.hasCapability(AudioDevice.Capabilities.CapabilityPlay) } ?: emptyList()
    fun audioDevice(device: AudioDevice) { core?.outputAudioDevice = device; call?.outputAudioDevice = device; speaker = device.type == AudioDevice.Type.Speaker; publish() }
    private fun recordCall(duration: Int) {
        val row = JSONObject().put("id",callId).put("number",callLabel.takeIf { it.matches(Regex("[+*#0-9]{1,32}")) } ?: "").put("direction", if(incoming && !answered) "missed" else if(incoming) "incoming" else "outgoing").put("started_at",startedAt).put("duration",duration).put("answered",answered)
        val store = PhoneStore(this); store.update { saved ->
        val pending = saved.optJSONArray("pending_calls") ?: JSONArray(); pending.put(row)
        // Bound offline history while preserving the newest records.
        val bounded = JSONArray(); for(i in maxOf(0,pending.length()-200) until pending.length()) bounded.put(pending.get(i))
        saved.put("pending_calls",bounded)
        }; flushPending()
    }
    fun flushPending() {
        worker.execute {
            try {
                val store = PhoneStore(this); val pending = store.read()?.optJSONArray("pending_calls") ?: return@execute
                val sent = mutableSetOf<String>()
                for(i in 0 until pending.length()) {
                    val row = pending.getJSONObject(i)
                    try { api?.json("call_log",row) ?: break; sent.add(row.getString("id")) }
                    catch(e: ApiError) { if(e.status==400 || e.status==422)sent.add(row.getString("id")) else throw e }
                }
                main.post {
                    store.update { saved ->
                    val current = saved.optJSONArray("pending_calls") ?: JSONArray(); val remaining = JSONArray()
                    for(i in 0 until current.length()) if(!sent.contains(current.getJSONObject(i).getString("id"))) remaining.put(current.get(i))
                    saved.put("pending_calls",remaining)
                    }
                }
            } catch (_: Exception) { /* Retry next refresh; never log credentials or call data. */ }
        }
    }
    override fun onDestroy() { core?.stop(); core = null; instance = null; changed?.invoke(); releaseCallLock(); worker.shutdown(); getSystemService(NotificationManager::class.java).cancel(11); super.onDestroy() }
}
