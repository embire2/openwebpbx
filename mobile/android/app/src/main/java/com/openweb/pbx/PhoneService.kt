/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.os.*
import android.net.*
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
    private data class Session(val phone:Call, val id:String=UUID.randomUUID().toString(), val started:String=Instant.now().toString(), val incoming:Boolean, var answered:Boolean=false, var endedLocally:Boolean=false)
    private val sessions=linkedMapOf<Long,Session>()
    val calls:List<Call> get()=sessions.values.map{it.phone}
    val waitingCall:Call? get()=calls.firstOrNull{it.state==Call.State.IncomingReceived}
    var consultation:Call?=null; private set
    var conference:Conference?=null; private set
    var transferring=false; private set
    var conferenceOnHold=false; private set
    var conferenceJoinFailed=false; private set
    private var heldConferenceCalls=emptySet<Long>()
    private val manuallyHeldCalls=mutableSetOf<Long>()
    private var afterPause:(()->Unit)?=null
    private var retrySeconds=2
    private var lastNetworkLoss=0L
    private val reconnectTask=Runnable{if(!destroying && networkAvailable()){core?.refreshRegisters();status="Reconnecting…";publish()}}
    private val lostCallTask=Runnable{if(!networkAvailable() && calls.isNotEmpty()){lastCallMessage="The connection was lost. Please call again.";calls.toList().forEach{it.terminate()}}}
    private val networkChanged=Runnable{
        val available=networkAvailable()
        core?.isNetworkReachable=available
        if(available){main.removeCallbacks(lostCallTask);core?.refreshRegisters();status="Reconnecting…";flushPending()}
        else{lastNetworkLoss=SystemClock.elapsedRealtime();status="No network connection";main.removeCallbacks(reconnectTask);main.postDelayed(lostCallTask,30000)}
        publish()
    }
    private val networks by lazy{getSystemService(ConnectivityManager::class.java)}
    private val networkCallback=object:ConnectivityManager.NetworkCallback(){
        override fun onAvailable(network:Network)=scheduleNetwork()
        override fun onLost(network:Network)=scheduleNetwork()
        override fun onCapabilitiesChanged(network:Network,caps:NetworkCapabilities)=scheduleNetwork()
    }
    private fun scheduleNetwork(){main.removeCallbacks(networkChanged);main.postDelayed(networkChanged,1000)}
    private fun networkAvailable():Boolean {
        val network=networks.activeNetwork ?: return false
        val capabilities=networks.getNetworkCapabilities(network) ?: return false
        // A private LAN/VPN PBX can be reachable without Android's public
        // Internet probe. Trusted SIP registration still gates every call.
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)
    }
    var muted = false; private set
    var speaker = false; private set
    var core: Core? = null; private set
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var account: JSONObject? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var proximity: CallProximity? = null
    private var destroying = false
    private val refreshAudioRoute = Runnable { syncCallAudio(); if (!destroying) publish() }
    private val callAudioListener = object: CallListenerStub() {
        override fun onAudioDeviceChanged(current: Call, audioDevice: AudioDevice) {
            if (call?.nativePointer == current.nativePointer && !destroying) { syncCallAudio(); publish() }
        }
    }
    private val api: PhoneApi? get() = account?.let { PhoneApi(it.getString("server"), it.getString("token")) }

    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate(); instance = this
        proximity = CallProximity(AndroidProximityPlatform(getSystemService(PowerManager::class.java)))
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("connection", "Phone connection", NotificationManager.IMPORTANCE_LOW))
        manager.createNotificationChannel(NotificationChannel("calls", "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply { lockscreenVisibility = Notification.VISIBILITY_PRIVATE })
        connectionForeground()
        networks.registerDefaultNetworkCallback(networkCallback)
        try { connect() } catch (_: Exception) { status = "Could not connect. Reopen the app to try again."; publish() }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if(intent?.action=="decline")calls.firstOrNull{sessions[it.nativePointer]?.id==intent.getStringExtra("call_id") && it.state==Call.State.IncomingReceived}?.decline(Reason.Declined)
        if(intent?.action=="hangup")hangup()
        return START_STICKY // Android may restart the user's ongoing phone connection; force-stop still requires reopening.
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
        c.maxCalls=2; c.registerOnlyWhenNetworkIsUp=true
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
        applyPersonalPreferences()
        c.config.setBool("sip", "use_rfc2833", true)
        c.config.setBool("sip", "use_info", false)
        c.config.setBool("rtp", "symmetric", true)
        c.addListener(object: CoreListenerStub() {
            override fun onCallCreated(core:Core,created:Call) {
                // Core adds an incoming call before notifying its ringing state.
                // Recheck saved sounds here so a deleted sound uses the default,
                // without restarting the SDK's ringer or any active call audio.
                core.ring=PhonePreferences(this@PhoneService).ringtoneUri()?.toString()
            }
            override fun onAccountRegistrationStateChanged(core: Core, a: Account, state: RegistrationState, message: String) {
                status = when(state) { RegistrationState.Ok -> "Ready for calls"; RegistrationState.Progress -> "Connecting…"; RegistrationState.Failed -> "Connection unavailable — check your network"; else -> "Disconnected" }
                if(state==RegistrationState.Ok){main.removeCallbacks(reconnectTask);retrySeconds=2;flushPending()}
                else if(state==RegistrationState.Failed && networkAvailable()){main.removeCallbacks(reconnectTask);main.postDelayed(reconnectTask,retrySeconds*1000L);retrySeconds=(retrySeconds*2).coerceAtMost(30)}
                publish()
            }
            override fun onTransferStateChanged(core:Core,current:Call,state:Call.State){
                if(state==Call.State.Error){transferring=false;lastCallMessage="Transfer failed. Your original call is still available.";if(current.state==Call.State.Paused)current.resume();select(current);publish()}
                else if(state==Call.State.Connected){transferring=false;lastCallMessage="Call transferred";publish()}
            }
            override fun onCallStateChanged(core: Core, current: Call, state: Call.State, message: String) {
                if(state==Call.State.IncomingReceived || state==Call.State.OutgoingInit){
                    val saved=PhoneStore(this@PhoneService).read()
                    if(state==Call.State.IncomingReceived && saved!=null && saved.optLong("declined_push_until")>System.currentTimeMillis() && saved.optString("declined_push_call")==current.remoteParams?.getCustomHeader("X-OpenWeb-Push-ID")){current.decline(Reason.Declined);return}
                    if(UpdateManager.get(this@PhoneService).isInstalling || (sessions.size>=2 && !sessions.containsKey(current.nativePointer))){current.decline(Reason.Busy);return}
                    if(!sessions.containsKey(current.nativePointer)){
                        if(sessions.isEmpty())lastNetworkLoss=0
                        sessions[current.nativePointer]=Session(current,incoming=state==Call.State.IncomingReceived)
                        current.addListener(callAudioListener)
                        lastCallMessage=""
                    }
                    if(call==null || state==Call.State.OutgoingInit)select(current)
                }
                val row=sessions[current.nativePointer] ?: return
                if(state==Call.State.Paused){val next=afterPause;afterPause=null;next?.invoke()}
                if(state==Call.State.StreamsRunning){row.answered=true;if(!conferenceOnHold)manuallyHeldCalls.remove(current.nativePointer);microphoneForeground();acquireCallLock();if(conferenceOnHold && current.nativePointer in heldConferenceCalls)current.pause()}
                if(state==Call.State.End || state==Call.State.Error || state==Call.State.Released){
                    sessions.remove(current.nativePointer)
                    manuallyHeldCalls.remove(current.nativePointer)
                    cancelIncoming(row.id)
                    recordCall(row,current.duration)
                    current.removeListener(callAudioListener)
                    if(consultation?.nativePointer==current.nativePointer || consultation!=null && current.nativePointer!=consultation?.nativePointer && !transferring)consultation=null
                    if(call?.nativePointer==current.nativePointer){
                        lastCallMessage=if(!row.endedLocally && lastNetworkLoss>0 && SystemClock.elapsedRealtime()-lastNetworkLoss<60000)"The connection was lost. Please call again." else if(!row.incoming && !row.answered && !row.endedLocally)CallFeedback.failure(current.errorInfo.protocolCode) else if(row.incoming && !row.answered)"Missed call" else "Call ended"
                        select(calls.firstOrNull())
                        call?.takeIf{it.state==Call.State.Paused && it.nativePointer !in manuallyHeldCalls && conference==null && !conferenceOnHold && !transferring}?.resume()
                    }
                    if(calls.isEmpty()){afterPause=null;transferring=false;conference=null;conferenceOnHold=false;conferenceJoinFailed=false;heldConferenceCalls=emptySet();manuallyHeldCalls.clear();consultation=null;core.isMicEnabled=true;releaseCallLock();applyPersonalPreferences();connectionForeground()}
                    else if(conference?.participantCount==0){conference?.terminate();conference=null}
                }
                if(state==Call.State.IncomingReceived){val stored=PhoneStore(this@PhoneService).read();if(stored!=null && stored.optString("push_pending_call").isNotBlank() && stored.optString("push_pending_call")==current.remoteParams?.getCustomHeader("X-OpenWeb-Push-ID"))PushConnection.cancel(this@PhoneService,stored.optString("push_pending_id"));notifyIncoming(current)}
                if(state==Call.State.StreamsRunning)cancelIncoming(row.id)
                syncCallAudio();publish()
            }
            override fun onAudioDeviceChanged(core: Core, audioDevice: AudioDevice) {
                syncCallAudio(); if (!destroying) publish()
            }
            override fun onAudioDevicesListUpdated(core: Core) {
                syncCallAudio()
                // Device discovery can notify just before the SDK chooses its new route.
                main.removeCallbacks(refreshAudioRoute)
                if (!destroying) main.post(refreshAudioRoute)
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
        .setSmallIcon(com.openweb.pbx.R.drawable.ic_phone).setContentTitle(getString(R.string.app_name))
        .setContentText(if (call != null) "Call in progress" else status)
        .setOngoing(true).setVisibility(Notification.VISIBILITY_PRIVATE)
        .setContentIntent(openIntent()).build()
    private fun openIntent(): PendingIntent = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun notifyIncoming(incoming:Call){
        val id=sessions[incoming.nativePointer]?.id ?: return
        val answer=PendingIntent.getActivity(this,id.hashCode(),Intent(this,IncomingCallActivity::class.java).putExtra("call_id",id).putExtra("answer",true),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val decline=PendingIntent.getService(this,id.hashCode(),Intent(this,PhoneService::class.java).setAction("decline").putExtra("call_id",id),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val person=Person.Builder().setName(incoming.remoteAddress.displayName ?: incoming.remoteAddress.username ?: "Incoming call").build()
        val note=Notification.Builder(this,"calls").setSmallIcon(R.drawable.ic_phone)
            .setContentTitle(if(calls.size>1)"Call waiting" else "Incoming call").setContentText(person.name)
            .setCategory(Notification.CATEGORY_CALL).setVisibility(Notification.VISIBILITY_PRIVATE).setOngoing(true)
            .setContentIntent(answer).setTimeoutAfter(60000)
        if(Build.VERSION.SDK_INT>=31)note.setStyle(Notification.CallStyle.forIncomingCall(person,decline,answer))
        else{note.addAction(Notification.Action.Builder(null,"Answer",answer).build());note.addAction(Notification.Action.Builder(null,"Decline",decline).build())}
        val ringing=PendingIntent.getActivity(this,(id+"ring").hashCode(),Intent(this,IncomingCallActivity::class.java).putExtra("call_id",id),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val manager=getSystemService(NotificationManager::class.java)
        if(Build.VERSION.SDK_INT<34 || manager.canUseFullScreenIntent())note.setFullScreenIntent(ringing,true)
        getSystemService(NotificationManager::class.java).notify("call:$id",11,note.build())
    }
    private fun cancelIncoming(id:String){getSystemService(NotificationManager::class.java).cancel("call:$id",11)}
    fun incomingById(id:String):Call?=sessions.values.firstOrNull{it.id==id && it.phone.state==Call.State.IncomingReceived}?.phone
    private fun select(selected:Call?){call=selected;callLabel=selected?.remoteAddress?.username ?: "";muted=selected?.microphoneMuted ?: false;syncCallAudio()}
    private fun pauseThen(action:()->Unit){
        val active=call
        if(active==null || active.state==Call.State.Paused){action();return}
        check(active.state==Call.State.StreamsRunning || active.state==Call.State.Connected){"Wait for your current call to connect"}
        check(afterPause==null){"Please wait for the call to go on hold"}
        afterPause=action
        if(active.pause()!=0){afterPause=null;error("Could not put your call on hold")}
        main.postDelayed({if(afterPause!=null){afterPause=null;lastCallMessage="Could not put your call on hold. Try again.";if(active.state==Call.State.Paused)active.resume();publish()}},4000)
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
    private fun syncCallAudio() {
        if (destroying) { proximity?.close(); return }
        val active = call
        val output = active?.outputAudioDevice?.type
        speaker = output == AudioDevice.Type.Speaker
        proximity?.update(!conferenceOnHold && CallProximityPolicy.enabled(sessions[active?.nativePointer]?.answered==true, active?.state, output))
    }
    fun dial(raw: String, second:Boolean=false) {
        check(!UpdateManager.get(this).isInstalling) { "Finish or cancel the update before making a call" }
        check(call==null || second && calls.size==1 && conference==null && !conferenceOnHold) { "Finish one of your calls first" }
        val number = Enrollment.number(raw); val c = core ?: error("Phone is still connecting")
        check(c.defaultAccount?.state == RegistrationState.Ok) { "Wait until the phone is ready for calls" }
        lastDialled = number; lastCallMessage = ""
        microphoneForeground()
        val domain = account!!.getJSONObject("sip").getString("domain")
        val params = c.createCallParams(null)!!; params.isVideoEnabled = false; params.mediaEncryption = MediaEncryption.SRTP
        val invite={
            val result=c.inviteAddressWithParams(Factory.instance().createAddress("sip:$number@$domain")!!,params)
            if(result==null){lastCallMessage="The second call could not start";call?.takeIf{it.state==Call.State.Paused}?.resume();publish()}
        }
        if(second)pauseThen(invite)else invite()
    }
    fun answer(incoming:Call?=waitingCall){
        val c=core ?: return;val next=incoming ?: return
        check(next.state==Call.State.IncomingReceived){"That call is no longer ringing"}
        microphoneForeground()
        val accept:()->Unit={
            val params=c.createCallParams(next)!!;params.isVideoEnabled=false;params.mediaEncryption=MediaEncryption.SRTP
            if(next.acceptWithParams(params)==0){select(next);sessions[next.nativePointer]?.let{cancelIncoming(it.id)}}
            else{lastCallMessage="Could not answer. Your original call is still available.";call?.takeIf{it.state==Call.State.Paused}?.resume();publish()}
        }
        if(call!=null && call?.nativePointer!=next.nativePointer)pauseThen(accept)else accept()
    }
    fun hangup(target:Call?=call){target?.let{sessions[it.nativePointer]?.endedLocally=true;if(it.state==Call.State.IncomingReceived)it.decline(Reason.Declined)else it.terminate()}}
    fun switchCall(target:Call){
        check(conference==null && !conferenceOnHold){"Resume your three-way call first"}
        if(target.state==Call.State.IncomingReceived){answer(target);return}
        if(target.nativePointer==call?.nativePointer)return
        pauseThen{select(target);if(target.state==Call.State.Paused)target.resume();publish()}
    }
    fun blindTransfer(raw:String){
        val active=call ?: error("No current call")
        check(calls.size==1 && active.state in listOf(Call.State.StreamsRunning,Call.State.Paused)){"Wait for your call to connect"}
        val address=Factory.instance().createAddress("sip:${Enrollment.number(raw)}@${account!!.getJSONObject("sip").getString("domain")}")!!
        check(active.transferTo(address)==0){"Could not start the transfer"};transferring=true;publish()
    }
    fun consult(raw:String){consultation=call ?: error("No current call");try{dial(raw,true)}catch(e:Exception){consultation=null;throw e}}
    fun completeTransfer(){
        val original=consultation ?: error("Start a transfer first");val target=call ?: error("Choose the second call")
        check(target.nativePointer!=original.nativePointer && target.state==Call.State.StreamsRunning){"Wait for the other person to answer"}
        check(original.transferToAnother(target)==0){"Could not transfer. Cancel to return to your original call"}
        transferring=true;publish()
    }
    fun cancelConsultation(){val original=consultation ?: return;consultation=null;calls.filter{it.nativePointer!=original.nativePointer}.forEach{hangup(it)};select(original);if(original.state==Call.State.Paused)original.resume();publish()}
    fun merge(){
        val c=core ?: error("Phone unavailable");check(calls.size==2 && calls.all{sessions[it.nativePointer]?.answered==true}){"Both people must answer before merging"}
        check(consultation==null){"Cancel the transfer before merging calls"}
        val params=c.createConferenceParams(null)!!;params.isAudioEnabled=true;params.isVideoEnabled=false;params.isLocalParticipantEnabled=true;params.isOneParticipantConferenceEnabled=true
        check(calls.all{it.state in listOf(Call.State.StreamsRunning,Call.State.Paused)}){"Wait for both calls to finish connecting"}
        c.config.setString("misc","conference_type","local")
        val joined=c.createConferenceWithParams(params) ?: error("Could not create the three-way call")
        val added=mutableListOf<Call>()
        // The pinned SDK's batch C wrapper returns a boolean in a status API.
        // The individual addParticipant wrapper consistently returns zero for success.
        for(participant in calls.toList()){
            if(joined.addParticipant(participant)!=0){
                added.forEach{c.removeFromConference(it)};if(!conferenceOnHold)call?.takeIf{it.state==Call.State.Paused}?.resume()
                error("Could not merge. Choose a conversation to continue")
            }
            added.add(participant)
        }
        conference=joined;conferenceOnHold=false;conferenceJoinFailed=false;heldConferenceCalls=emptySet();manuallyHeldCalls.clear()
        // Active-leg addition enters before starting media. Both held legs instead
        // queue their resumes; enter now, before those queued updates lock audio.
        enterConference(joined)
        publish()
    }
    private fun enterConference(group:Conference,attempt:Int=0) {
        if(destroying || conference!==group || conferenceOnHold || calls.isEmpty())return
        if(!group.isIn)group.enter()
        if(!group.isIn && attempt<40)main.postDelayed({enterConference(group,attempt+1)},200)
        else {conferenceJoinFailed=!group.isIn;syncCallAudio();publish()}
    }
    fun retryConferenceAudio() { conference?.let{conferenceJoinFailed=false;enterConference(it);publish()} }
    fun muteParticipant(target:Call){target.speakerMuted=!target.speakerMuted;publish()}
    fun dismissCallMessage() { lastCallMessage=""; publish() }
    fun reconnect() {
        check(call==null) { "Finish your call before reconnecting" }
        core?.refreshRegisters(); status="Connecting…"; publish()
    }
    fun mute() { muted=!muted; if(conference!=null)conference?.microphoneMuted=muted else call?.microphoneMuted=muted; publish() }
    fun canHold():Boolean {
        if(transferring || afterPause!=null)return false
        return if(conferenceOnHold)calls.isNotEmpty() && calls.all{it.state==Call.State.Paused}
        else if(conference!=null)conference!!.isIn && calls.isNotEmpty() && calls.all{it.state==Call.State.StreamsRunning}
        else call?.state in listOf(Call.State.StreamsRunning,Call.State.Paused,Call.State.PausedByRemote)
    }
    fun hold() {
        check(canHold()) { "Wait until your call is connected" }
        val active=call ?: error("No current call")
        if(conferenceOnHold) {
            if(calls.size>1)merge()
            else {check(active.resume()==0){"Could not resume. Your caller is still on hold."};conferenceOnHold=false;heldConferenceCalls=emptySet();manuallyHeldCalls.remove(active.nativePointer)}
        } else if(conference!=null) {
            val c=core ?: error("Phone unavailable")
            val group=conference!!
            check(group.leave()==0) { "Could not place the three-way call on hold. Please try again." }
            heldConferenceCalls=calls.map{it.nativePointer}.toSet();conferenceOnHold=true;conferenceJoinFailed=false;conference=null
            // Leaving the local participant alone keeps remote people talking. Removing
            // each call pauses its SIP leg so the PBX sends hold music to each caller.
            calls.toList().forEach{c.removeFromConference(it);if(it.state==Call.State.StreamsRunning)it.pause()}
        } else if(active.state==Call.State.Paused){check(active.resume()==0){"Could not resume. Your caller is still on hold."};manuallyHeldCalls.remove(active.nativePointer)}
        else {check(active.pause()==0){"Could not place this call on hold. Please try again."};manuallyHeldCalls.add(active.nativePointer)}
        syncCallAudio();publish()
    }
    fun applyPersonalPreferences() {
        if(calls.isNotEmpty())return
        core?.ring=PhonePreferences(this).ringtoneUri()?.toString()
    }
    fun dtmf(digit: Char) { if (digit in "0123456789*#") call?.sendDtmf(digit) }
    fun speaker() {
        val c = core ?: return
        val type = if(speaker) AudioDevice.Type.Earpiece else AudioDevice.Type.Speaker
        val device = c.audioDevices.firstOrNull { it.type == type } ?: error(if(speaker) "This device has no earpiece. Choose an audio device in Settings." else "A speaker is not available on this device.")
        c.outputAudioDevice = device; conference?.outputAudioDevice=device;calls.forEach{it.outputAudioDevice=device}; syncCallAudio()
        publish()
    }
    fun audioDevices(): List<AudioDevice> = core?.extendedAudioDevices?.filter { it.hasCapability(AudioDevice.Capabilities.CapabilityPlay) } ?: emptyList()
    fun audioDevice(device: AudioDevice) { core?.outputAudioDevice = device;conference?.outputAudioDevice=device;calls.forEach{it.outputAudioDevice=device};syncCallAudio(); publish() }
    private fun recordCall(session:Session,duration: Int) {
        val callId=session.id;val callLabel=session.phone.remoteAddress.username ?: "";val incoming=session.incoming;val answered=session.answered;val startedAt=session.started
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
    override fun onDestroy() {
        destroying = true; proximity?.close(); main.removeCallbacks(refreshAudioRoute)
        sessions.values.forEach{it.phone.removeListener(callAudioListener);cancelIncoming(it.id)}
        networks.unregisterNetworkCallback(networkCallback);main.removeCallbacksAndMessages(null)
        core?.stop(); core = null; call = null; instance = null; changed?.invoke()
        releaseCallLock(); worker.shutdown(); getSystemService(NotificationManager::class.java).cancel(11)
        super.onDestroy()
    }
}
