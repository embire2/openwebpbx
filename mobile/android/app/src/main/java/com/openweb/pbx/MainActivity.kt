/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.Manifest
import android.app.AlertDialog
import android.content.Intent
import android.content.res.ColorStateList
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.*
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import org.json.JSONArray
import org.json.JSONObject
import org.linphone.core.Call
import java.io.File
import java.net.URI
import java.util.concurrent.Executors

class MainActivity: ComponentActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var store: PhoneStore
    private lateinit var root: LinearLayout
    private lateinit var body: LinearLayout
    private lateinit var status: TextView
    private lateinit var callPanel: LinearLayout
    private var section = "Keypad"
    private var dataGeneration = 0
    private var player: MediaPlayer? = null
    private var audioFile: File? = null
    private var busy = false
    private var bootstrapped = false
    private var drawnAccount = false
    private var playbackGeneration = 0
    private val accountChanges = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _,_ ->
        runOnUiThread { refreshConnection() }
    }
    private fun refreshConnection() {
        if(isFinishing || isDestroyed || !::store.isInitialized)return
        if((store.read()!=null)!=drawnAccount) {
            draw()
            if(drawnAccount) { ensurePermissions();bootstrap() }
        }
    }
    override fun onStart() {
        super.onStart()
        getSharedPreferences("private_account",MODE_PRIVATE).registerOnSharedPreferenceChangeListener(accountChanges)
        refreshConnection()
    }
    override fun onStop() {
        getSharedPreferences("private_account",MODE_PRIVATE).unregisterOnSharedPreferenceChangeListener(accountChanges)
        stopPlayback();super.onStop()
    }
    private val dark get() = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    private val ink get() = Color.parseColor(if(dark) "#F2F5F8" else "#142E39")
    private val soft get() = Color.parseColor(if(dark) "#AFBFCA" else "#516571")
    private val paper get() = Color.parseColor(if(dark) "#0D1921" else "#F2F7F7")
    private val card get() = Color.parseColor(if(dark) "#1A2C36" else "#FFFFFF")
    private val green get() = Color.parseColor(if(dark) "#49CDA2" else "#16745B")
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if(checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) startPhone()
        else message("Allow microphone access to make and answer calls. You can still view contacts and voicemail.")
        draw()
    }
    private val scanner = registerForActivityResult(ScanContract()) { result ->
        if(result.contents != null) try {
            val qr = JSONObject(result.contents)
            require(qr.optString("type") == "openwebpbx" && qr.optInt("version") == 1) { "This is not an OpenWeb PBX connection code" }
            val server = Enrollment.server(qr.getString("server")); val code = Enrollment.code(qr.getString("code"))
            AlertDialog.Builder(this).setTitle("Connect your phone?").setMessage("Connect to ${URI(server).host}. Only scan codes provided by your PBX administrator.")
                .setNegativeButton("Cancel",null).setPositiveButton("Connect") { _, _ -> enroll(server,code) }.show()
        } catch(e: Exception) { message(e.message ?: "That QR code could not be read") }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        store = PhoneStore(this); section = savedInstanceState?.getString("section") ?: "Keypad"
        draw()
        if(store.read() != null) { ensurePermissions(); bootstrap() }
    }
    override fun onResume() { super.onResume(); PhoneService.changed = { runOnUiThread { updatePhone() } }; updatePhone() }
    override fun onPause() { PhoneService.changed = null; super.onPause() }
    override fun onSaveInstanceState(outState: Bundle) { outState.putString("section", section); super.onSaveInstanceState(outState) }
    override fun onDestroy() { stopPlayback(); worker.shutdown(); super.onDestroy() }
    private fun dp(value:Int) = (value * resources.displayMetrics.density).toInt()
    private fun text(value: String, size: Float=16f, color:Int=ink, bold:Boolean=false) = TextView(this).apply { text=value; textSize=size; setTextColor(color); if(bold)setTypeface(typeface,Typeface.BOLD); setPadding(0,dp(5),0,dp(5)) }
    private fun layout(horizontal:Boolean=false) = LinearLayout(this).apply { orientation=if(horizontal)LinearLayout.HORIZONTAL else LinearLayout.VERTICAL }
    private fun rounded(color:Int) = GradientDrawable().apply { setColor(color); cornerRadius=dp(18).toFloat() }
    private fun button(label:String, action:()->Unit) = Button(this).apply { text=label; isAllCaps=false; textSize=15f
        val important=label in listOf("Call","Scan QR code","Answer")
        val ending=label=="End call"
        backgroundTintList=ColorStateList.valueOf(if(important)Color.parseColor("#16745B") else if(ending)Color.parseColor("#AA283A") else card)
        setTextColor(if(important || ending)Color.WHITE else ink); minHeight=dp(48); setOnClickListener { try { action() } catch(e:Exception) { message(e.message ?: "Please try again") } } }
    private fun message(value:String) { Toast.makeText(this,value,Toast.LENGTH_LONG).show() }
    private fun draw() {
        if(isFinishing)return
        dataGeneration++
        root = layout().apply { setBackgroundColor(paper); setPadding(dp(20),dp(12),dp(20),dp(12)) }
        root.setOnApplyWindowInsetsListener { view,insets -> view.setPadding(dp(20),insets.systemWindowInsetTop+dp(12),dp(20),insets.systemWindowInsetBottom+dp(12)); insets }
        setContentView(root)
        val heading=layout(true); heading.gravity=Gravity.CENTER_VERTICAL
        heading.addView(text("OpenWeb PBX",24f,ink,true),LinearLayout.LayoutParams(0,dp(52),1f))
        if(store.read()!=null) heading.addView(button("Settings") { settings() })
        root.addView(heading)
        status=text("Your work phone, wherever you are",14f,soft); root.addView(status)
        callPanel=layout(); root.addView(callPanel)
        val scroll=ScrollView(this).apply { isFillViewport=true }; body=layout(); scroll.addView(body)
        root.addView(scroll,LinearLayout.LayoutParams(-1,0,1f))
        drawnAccount=store.read()!=null
        if(!drawnAccount) { welcome(); return }
        val nav=layout(true)
        for(name in listOf("Keypad","Contacts","Recents","Voicemail")) nav.addView(button(name){ section=name; stopPlayback(); draw() }.apply { textSize=12f; setTextColor(if(name==section)green else soft) },LinearLayout.LayoutParams(0,dp(60),1f))
        root.addView(nav); updatePhone()
        when(section) { "Keypad" -> keypad(); "Contacts" -> contacts(); "Recents" -> recents(); "Voicemail" -> voicemail() }
    }
    private fun welcome() {
        body.addView(text("Meet your new\nwork phone.",36f,ink,true))
        body.addView(text("Call your team, reach customers and listen to voicemail in one place.",18f,soft))
        body.addView(text("1. Open Users → Phone Provisioning in your PBX.\n2. Create your Android connection code.\n3. Scan the QR code below.",16f,soft))
        body.addView(button("Scan QR code") { scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan the QR code shown in your PBX").setBeepEnabled(false).setOrientationLocked(false)) })
        body.addView(button("Enter a connection code instead") { manualEnrollment() })
        body.addView(text("Android 9 or newer · Version ${BuildConfig.VERSION_NAME}\nCalls stay connected while the phone notification is running. Reopen the app after restarting your phone or stopping it.",13f,soft))
    }
    private fun field(hint:String,value:String="",type:Int=InputType.TYPE_CLASS_TEXT) = EditText(this).apply { this.hint=hint; setText(value); inputType=type; setTextColor(ink); setHintTextColor(soft); minHeight=dp(52); setSingleLine(); importantForAutofill=View.IMPORTANT_FOR_AUTOFILL_NO }
    private fun manualEnrollment() {
        val fields=layout().apply { setPadding(dp(20),0,dp(20),0) }
        val host=field("https://your-pbx.example.com",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        val code=field("Connection code",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        fields.addView(host); fields.addView(code)
        val dialog=AlertDialog.Builder(this).setTitle("Connect your phone").setView(fields).setNegativeButton("Cancel",null).setPositiveButton("Connect",null).create()
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            try { val s=Enrollment.server(host.text.toString()); val c=Enrollment.code(code.text.toString()); dialog.dismiss(); enroll(s,c) } catch(e:Exception) { code.error=e.message }
        } }; dialog.show()
    }
    private fun enroll(server:String, code:String) {
        if(busy)return; busy=true; status.text="Connecting your phone…"
        async({
            val response=PhoneApi(server).json("enroll",JSONObject().put("code",code).put("device_name","${Build.MANUFACTURER} ${Build.MODEL}").put("platform","android"))
            require(response.getString("token").length>=32) { "The PBX returned an invalid phone connection" }
            val sip=response.getJSONObject("sip")
            require(sip.getString("transport").equals("tls",true) && sip.getString("media_encryption").equals("srtp",true)) { "Your PBX needs secure phone connections enabled" }
            response.getJSONObject("account").getString("extension")
            response.put("server",server)
            // A one-use code must retain its validated credentials even if this Activity is replaced.
            store.save(response);response
        }, { _ -> busy=false; draw(); ensurePermissions() }, { busy=false; status.text="Your work phone, wherever you are" })
    }
    private fun ensurePermissions() {
        val needed=mutableListOf<String>()
        if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.RECORD_AUDIO)
        if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.POST_NOTIFICATIONS)
        if(Build.VERSION.SDK_INT>=31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)!=PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.BLUETOOTH_CONNECT)
        if(needed.isEmpty())startPhone() else permissions.launch(needed.toTypedArray())
    }
    private fun startPhone() { if(store.read()!=null && PhoneService.instance==null) startForegroundService(Intent(this,PhoneService::class.java)); updatePhone() }
    private fun updatePhone() {
        if(!::status.isInitialized || store.read()==null)return
        val phone=PhoneService.instance; val account=store.read()?.optJSONObject("account")
        status.text="${account?.optString("display_name","") ?: ""} · ${account?.optString("extension","") ?: ""}\n${phone?.status ?: "Open the phone to connect"}"
        callPanel.removeAllViews()
        val call=phone?.call ?: return
        stopPlayback()
        callPanel.background=rounded(card); callPanel.setPadding(dp(14),dp(10),dp(14),dp(10))
        val state=when(call.state) { Call.State.IncomingReceived -> "Incoming call"; Call.State.Paused -> "On hold"; Call.State.StreamsRunning -> "Connected"; Call.State.OutgoingRinging -> "Ringing…"; else -> "Calling…" }
        callPanel.addView(text("$state · ${phone.callLabel}",22f,ink,true))
        val controls=layout(true)
        if(call.state==Call.State.IncomingReceived) controls.addView(button("Answer"){ ensurePermissions(); if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)phone.answer() },LinearLayout.LayoutParams(0,dp(50),1f))
        else {
            controls.addView(button(if(phone.muted)"Unmute" else "Mute"){phone.mute()},LinearLayout.LayoutParams(0,dp(50),1f))
            controls.addView(button(if(call.state==Call.State.Paused)"Resume" else "Hold"){phone.hold()},LinearLayout.LayoutParams(0,dp(50),1f))
            controls.addView(button(if(phone.speaker)"Earpiece" else "Speaker"){phone.speaker()},LinearLayout.LayoutParams(0,dp(50),1f))
        }
        callPanel.addView(controls); callPanel.addView(button("End call"){phone.hangup()})
    }
    private fun keypad() {
        body.addView(text("Keypad",28f,ink,true))
        val number=field("Number or extension",type=InputType.TYPE_CLASS_PHONE).apply { textSize=28f; gravity=Gravity.CENTER; contentDescription="Number or extension" }
        body.addView(number)
        for(row in listOf(listOf("1","2","3"),listOf("4","5","6"),listOf("7","8","9"),listOf("*","0","#"))) {
            val line=layout(true)
            for(digit in row)line.addView(button(digit){ if(PhoneService.instance?.call!=null) PhoneService.instance?.dtmf(digit[0]) else number.append(digit) }.apply { textSize=26f },LinearLayout.LayoutParams(0,dp(62),1f))
            body.addView(line)
        }
        body.addView(button("Call") { val phone=PhoneService.instance ?: error("Open the app and wait for the phone to connect"); phone.dial(number.text.toString()) })
        body.addView(button("Delete digit") { if(number.text.isNotEmpty())number.text.delete(number.text.length-1,number.text.length) })
        body.addView(text("During a call, use the keypad for menu choices.\nCalls follow your company's calling rules.",13f,soft))
    }
    private fun api():PhoneApi { val a=store.read() ?: error("Connect your phone first"); return PhoneApi(a.getString("server"),a.getString("token")) }
    private fun <T> async(work:()->T, success:(T)->Unit, failure:()->Unit={}) {
        worker.execute { try { val result=work(); runOnUiThread { if(!isFinishing && !isDestroyed)success(result) } } catch(e:Exception) {
            runOnUiThread { if(!isFinishing && !isDestroyed) { failure(); if(e is ApiError && e.status==401 && store.read()!=null){stopService(Intent(this,PhoneService::class.java));store.clear();draw()}; message(if(e is ApiError || e is IllegalArgumentException)e.message ?: "Please try again" else "Could not reach your PBX. Check your connection and try again.") } }
        } }
    }
    private fun fetch(action:String,key:String,render:(JSONArray)->Unit) {
        val generation=dataGeneration; val progress=text("Loading…",16f,soft); body.addView(progress)
        async({api().json(action)}, { response -> if(generation==dataGeneration) { body.removeView(progress); val items=response.optJSONArray(key) ?: JSONArray(); if(items.length()==0)body.addView(text("Nothing here yet",16f,soft)) else render(items) } }, {if(generation==dataGeneration) {progress.text="Could not load this page"; body.addView(button("Try again"){draw()})}})
    }
    private fun dial(number:String) { try { PhoneService.instance?.dial(number) ?: error("Your phone is not connected yet") } catch(e:Exception){message(e.message ?: "The call could not start")} }
    private fun item(title:String,subtitle:String,action:()->Unit) {
        val row=layout().apply { background=rounded(card); setPadding(dp(16),dp(12),dp(16),dp(12)); isClickable=true; isFocusable=true; contentDescription="$title, $subtitle"; setOnClickListener{action()} }
        row.addView(text(title,18f,ink,true)); row.addView(text(subtitle,14f,soft)); body.addView(row,LinearLayout.LayoutParams(-1,-2).apply{bottomMargin=dp(10)})
    }
    private fun contacts() {
        body.addView(text("Contacts",28f,ink,true)); body.addView(text("Your company directory",14f,soft))
        fetch("directory","contacts") { list ->
            val search=field("Search people or numbers"); body.addView(search); val container=layout(); body.addView(container)
            fun filter(value:String) { container.removeAllViews(); for(i in 0 until list.length()) { val row=list.getJSONObject(i); val name=row.optString("name"); val number=row.optString("number"); if(!"$name $number".contains(value,true))continue
                container.addView(button("$name\n$number"){dial(number)}.apply{gravity=Gravity.START; minHeight=dp(64)})
            } }
            search.addTextChangedListener(object:android.text.TextWatcher{override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int){}; override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int){filter(s.toString())};override fun afterTextChanged(s:android.text.Editable?){} });filter("")
        }
    }
    private fun recents() {
        body.addView(text("Recents",28f,ink,true)); PhoneService.instance?.flushPending()
        body.addView(button("Refresh"){draw()})
        fetch("calls","calls") { list -> for(i in 0 until list.length()) { val row=list.getJSONObject(i); val number=row.optString("number"); val name=row.optString("name").ifBlank{number}; item(name,"${row.optString("direction")} · ${row.optString("started_at")} · ${row.optInt("duration")}s"){dial(number)} } }
    }
    private fun voicemail() {
        body.addView(text("Voicemail",28f,ink,true)); body.addView(button("Refresh"){stopPlayback();draw()})
        fetch("voicemail","messages") { list -> for(i in 0 until list.length()) {
            val row=list.getJSONObject(i); val id=row.getString("id"); val title=row.optString("caller_name").ifBlank{row.optString("caller_number","Unknown caller")}
            val cardView=layout().apply { background=rounded(card); setPadding(dp(14),dp(10),dp(14),dp(10)) }
            cardView.addView(text((if(row.optBoolean("read"))"" else "New · ")+title,18f,ink,true));cardView.addView(text("${row.optString("created_at")} · ${row.optInt("duration")}s",13f,soft))
            val buttons=layout(true)
            buttons.addView(button("Play"){playVoicemail(id)},LinearLayout.LayoutParams(0,dp(50),1f))
            buttons.addView(button("Mark read"){async({api().json("voicemail_read",JSONObject().put("id",id))},{draw()})},LinearLayout.LayoutParams(0,dp(50),1f))
            buttons.addView(button("Delete"){ AlertDialog.Builder(this).setTitle("Delete this voicemail?").setMessage("This removes it from your mailbox.").setNegativeButton("Cancel",null).setPositiveButton("Delete"){_,_->stopPlayback();async({api().json("voicemail_delete",JSONObject().put("id",id))},{draw()})}.show() },LinearLayout.LayoutParams(0,dp(50),1f))
            cardView.addView(buttons); body.addView(cardView,LinearLayout.LayoutParams(-1,-2).apply{bottomMargin=dp(10)})
        } }
        body.addView(button("Stop playback"){stopPlayback()})
    }
    private fun playVoicemail(id:String) {
        stopPlayback(); val generation=playbackGeneration;message("Loading voicemail…")
        async({api().voicemail(id)}, { bytes ->
            if(generation!=playbackGeneration || section!="Voicemail" || PhoneService.instance?.call!=null)return@async
            try { val file=File.createTempFile("voicemail-",".wav",cacheDir);file.writeBytes(bytes);audioFile=file
                player=MediaPlayer().apply {
                    setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    setDataSource(file.path);setOnCompletionListener{stopPlayback()}
                    setOnPreparedListener { media -> if(player===media && generation==playbackGeneration && section=="Voicemail" && PhoneService.instance?.call==null) { media.start();async({api().json("voicemail_read",JSONObject().put("id",id))},{message("Playing voicemail")}) } }
                    setOnErrorListener { _,_,_ -> stopPlayback();message("This voicemail could not be played");true }
                    prepareAsync()
                }
            }catch(_:Exception){stopPlayback();message("This voicemail could not be played")}
        })
    }
    private fun stopPlayback() { playbackGeneration++;player?.release();player=null;audioFile?.delete();audioFile=null }
    private fun settings() {
        val a=store.read() ?: return
        val contents="${a.getJSONObject("account").optString("display_name")}\nExtension ${a.getJSONObject("account").optString("extension")}\n${a.getString("server")}\n\nVersion ${BuildConfig.VERSION_NAME}\n\nKeep the connection notification running for incoming calls. Android may stop background apps; reopen OpenWeb PBX after a restart or force-stop. Push wake-up, chat and video are not included in this release.\n\nOpen source under AGPL-3.0-or-later. Powered by Linphone SDK 5.5.23 and ZXing. Source and notices: github.com/embire2/openwebpbx/tree/customization/mobile/android"
        AlertDialog.Builder(this).setTitle("Your phone").setMessage(contents).setPositiveButton("Done",null).setNeutralButton("More"){_,_->AlertDialog.Builder(this).setItems(arrayOf("Audio device", "Source and licenses")){_,index->if(index==0)audioDevices()else licenses()}.show()}.setNegativeButton("Disconnect"){_,_->disconnect()}.show()
    }
    private fun licenses() {
        val notices=assets.open("THIRD_PARTY_NOTICES.md").bufferedReader().use{it.readText()}
        AlertDialog.Builder(this).setTitle("Open source licenses").setMessage(notices).setNegativeButton("Close",null).setPositiveButton("Source code"){_,_->startActivity(Intent(Intent.ACTION_VIEW,android.net.Uri.parse("https://github.com/embire2/openwebpbx/tree/customization/mobile/android")))}.show()
    }
    private fun bootstrap() {
        if(bootstrapped)return;bootstrapped=true
        async({api().json("bootstrap")},{ response ->
            store.update { saved ->
            response.optJSONObject("account")?.let{saved.put("account",it)}
            response.optJSONObject("sip")?.let{fresh->val old=saved.getJSONObject("sip");for(key in fresh.keys())if(key!="password" || fresh.optString(key).isNotBlank())old.put(key,fresh.get(key))}
            };updatePhone()
        })
    }
    private fun audioDevices() {
        if(Build.VERSION.SDK_INT>=31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)!=PackageManager.PERMISSION_GRANTED) { permissions.launch(arrayOf(Manifest.permission.BLUETOOTH_CONNECT)); return }
        val devices=PhoneService.instance?.audioDevices() ?: emptyList()
        AlertDialog.Builder(this).setTitle("Audio device").setItems(devices.map{it.deviceName}.toTypedArray()){_,index->PhoneService.instance?.audioDevice(devices[index])}.setNegativeButton("Cancel",null).show()
    }
    private fun disconnect() {
        AlertDialog.Builder(this).setTitle("Disconnect this phone?").setMessage("You will need a new QR code to reconnect.").setNegativeButton("Cancel",null).setPositiveButton("Disconnect"){_,_->
            async({
                try { api().json("revoke",JSONObject()) }
                catch(e:ApiError) { if(e.status!=401)throw e;JSONObject() }
            },{stopService(Intent(this,PhoneService::class.java));store.clear();stopPlayback();draw()})
        }.show()
    }
}
