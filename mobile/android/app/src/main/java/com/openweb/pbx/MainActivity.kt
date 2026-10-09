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
import android.graphics.drawable.RippleDrawable
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
    private lateinit var keypadDock:LinearLayout
    private var section = "Keypad"
    private var dataGeneration = 0
    private var player: MediaPlayer? = null
    private var audioFile: File? = null
    private var busy = false
    private var bootstrapped = false
    private var drawnAccount = false
    private var playbackGeneration = 0
    private var dialledNumber = ""
    private var urgentUpdateBypass = false
    private var updateGated = false
    private lateinit var updatePanel:LinearLayout
    private val updates get()=UpdateManager.get(this)
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
    private val compact get()=resources.displayMetrics.heightPixels/resources.displayMetrics.density<720
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
        draw();updates.schedule();updates.check()
        if(store.read() != null) { ensurePermissions(); bootstrap() }
    }
    override fun onResume() { super.onResume(); updates.foregroundActivity=this; updates.changed={runOnUiThread { if(store.read()!=null && !updates.isInstalling && PhoneService.instance==null && checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)startPhone();updatePhone();updateUi() }}; PhoneService.changed = { runOnUiThread { updatePhone();updateUi() } }; updatePhone();updateUi(); if(store.read()!=null && !updates.isInstalling && checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)startPhone() }
    override fun onPause() { PhoneService.changed = null;updates.changed=null;updates.foregroundActivity=null; super.onPause() }
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
    private fun iconButton(label:String,icon:Int,selected:Boolean=false,tone:Int?=null,action:()->Unit):LinearLayout = layout().apply {
        gravity=Gravity.CENTER; minimumHeight=dp(if(compact)58 else 72);isClickable=true;isFocusable=true;contentDescription=label
        val fill=tone ?: if(selected)Color.parseColor("#16745B") else card;val foreground=if(tone!=null || selected)Color.WHITE else ink
        background=RippleDrawable(ColorStateList.valueOf(Color.parseColor("#33777777")),rounded(fill),null)
        setPadding(dp(6),dp(if(compact)5 else 10),dp(6),dp(if(compact)5 else 10))
        addView(ImageView(this@MainActivity).apply{setImageResource(icon);imageTintList=ColorStateList.valueOf(foreground);importantForAccessibility=View.IMPORTANT_FOR_ACCESSIBILITY_NO},LinearLayout.LayoutParams(dp(26),dp(26)))
        addView(text(label,12f,foreground,true).apply{gravity=Gravity.CENTER;maxLines=2})
        setOnClickListener{try{action()}catch(e:Exception){message(e.message ?: "Please try again")}}
    }
    private fun spaced(weight:Float=1f,height:Int=78)=LinearLayout.LayoutParams(0,dp(height),weight).apply{setMargins(dp(4),dp(4),dp(4),dp(4))}
    private fun message(value:String) { Toast.makeText(this,value,Toast.LENGTH_LONG).show() }
    private fun draw() {
        if(isFinishing)return
        dataGeneration++
        root = layout().apply { setBackgroundColor(paper); setPadding(dp(20),dp(12),dp(20),dp(12)) }
        root.setOnApplyWindowInsetsListener { view,insets -> view.setPadding(dp(20),insets.systemWindowInsetTop+dp(12),dp(20),insets.systemWindowInsetBottom+dp(12)); insets }
        setContentView(root)
        val heading=layout(true); heading.gravity=Gravity.CENTER_VERTICAL
        heading.addView(text("OpenWeb PBX",24f,ink,true),LinearLayout.LayoutParams(0,dp(if(compact)44 else 52),1f))
        if(store.read()!=null) heading.addView(button("Settings") { settings() })
        root.addView(heading)
        status=text("Your work phone, wherever you are",14f,soft); status.setPadding(dp(12),dp(if(compact)5 else 10),dp(12),dp(if(compact)5 else 10));status.background=rounded(card);root.addView(status)
        updatePanel=layout();root.addView(updatePanel)
        callPanel=layout(); root.addView(callPanel)
        val scroll=ScrollView(this).apply { isFillViewport=true }; body=layout(); scroll.addView(body)
        root.addView(scroll,LinearLayout.LayoutParams(-1,0,1f))
        keypadDock=layout(true);root.addView(keypadDock)
        drawnAccount=store.read()!=null
        if(!drawnAccount) { welcome(); return }
        val nav=layout(true)
        val navIcons=mapOf("Keypad" to R.drawable.ic_keypad,"Contacts" to R.drawable.ic_contacts,"Recents" to R.drawable.ic_recents,"Voicemail" to R.drawable.ic_voicemail)
        for(name in navIcons.keys) nav.addView(iconButton(name,navIcons.getValue(name),name==section){ section=name; stopPlayback(); draw() },spaced(height=if(compact)60 else 74))
        root.addView(nav)
        updateGated=updates.shouldGate(PhoneService.instance?.call!=null,urgentUpdateBypass);updatePhone()
        if(updateGated) { updateGate();updateUi();return }
        when(section) { "Keypad" -> keypad(); "Contacts" -> contacts(); "Recents" -> recents(); "Voicemail" -> voicemail() };updateUi()
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
    private fun startPhone() { if(store.read()!=null && PhoneService.instance==null && !updates.isInstalling) startForegroundService(Intent(this,PhoneService::class.java)); updatePhone() }
    private fun updatePhone() {
        if(!::status.isInitialized || store.read()==null)return
        val phone=PhoneService.instance; val account=store.read()?.optJSONObject("account")
        status.text="${account?.optString("display_name","") ?: ""} · Your extension ${account?.optString("extension","") ?: ""}\n${phone?.status ?: if(updates.isInstalling)"Phone paused while Android updates" else "Open the phone to connect"}"
        callPanel.removeAllViews();callPanel.setPadding(0,0,0,0);callPanel.background=null
        val call=phone?.call
        keypadDock.visibility=if(call==null && (section=="Keypad" || updateGated))View.VISIBLE else View.GONE
        if(call==null) {
            if(phone?.lastCallMessage?.isNotEmpty()==true) {
                callPanel.setPadding(dp(12),dp(12),dp(12),dp(12));callPanel.background=rounded(card)
                callPanel.addView(text(phone.lastCallMessage,15f,ink,true))
                val actions=layout(true)
                if(phone.lastDialled.isNotBlank())actions.addView(button("Call again"){dial(phone.lastDialled)},LinearLayout.LayoutParams(0,dp(50),1f))
                actions.addView(button("Dismiss"){phone.dismissCallMessage()},LinearLayout.LayoutParams(0,dp(50),1f));callPanel.addView(actions)
            }
            return
        }
        stopPlayback();callPanel.background=rounded(card); callPanel.setPadding(dp(12),dp(10),dp(12),dp(10))
        val state=when(call.state) { Call.State.IncomingReceived -> "Incoming call"; Call.State.Paused -> "On hold"; Call.State.Pausing -> "Placing on hold…";Call.State.Resuming -> "Resuming…"; Call.State.StreamsRunning -> "Connected"; Call.State.OutgoingRinging -> "Ringing…";Call.State.OutgoingEarlyMedia -> "Connecting…"; else -> "Calling…" }
        callPanel.addView(text(state,14f,soft).apply{gravity=Gravity.CENTER})
        callPanel.addView(text(phone.callLabel,28f,ink,true).apply{gravity=Gravity.CENTER})
        val controls=layout(true)
        if(call.state==Call.State.IncomingReceived) {
            controls.addView(iconButton("Decline",R.drawable.ic_hangup,tone=Color.parseColor("#B3263E")){phone.hangup()},spaced(height=82))
            controls.addView(iconButton("Answer",R.drawable.ic_call,tone=Color.parseColor("#16745B")){ensurePermissions();if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)phone.answer()},spaced(height=82))
            callPanel.addView(controls)
        } else {
            controls.addView(iconButton(if(phone.muted)"Unmute" else "Mute",if(phone.muted)R.drawable.ic_mic_off else R.drawable.ic_mic,phone.muted){phone.mute()},spaced())
            controls.addView(iconButton(if(call.state==Call.State.Paused)"Resume" else "Hold",if(call.state==Call.State.Paused)R.drawable.ic_play else R.drawable.ic_hold,call.state==Call.State.Paused){phone.hold()},spaced())
            controls.addView(iconButton(if(phone.speaker)"Earpiece" else "Speaker",R.drawable.ic_speaker,phone.speaker){phone.speaker()},spaced())
            callPanel.addView(controls)
            callPanel.addView(iconButton("End call",R.drawable.ic_hangup,tone=Color.parseColor("#B3263E")){phone.hangup()},LinearLayout.LayoutParams(-1,dp(70)))
        }
    }
    private fun keypad() {
        if(!compact)body.addView(text("Keypad",22f,ink,true))
        val number=field("Number or extension",dialledNumber,type=InputType.TYPE_CLASS_PHONE).apply { textSize=28f; gravity=Gravity.CENTER; contentDescription="Number or extension" }
        number.addTextChangedListener(object:android.text.TextWatcher{override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int){};override fun afterTextChanged(s:android.text.Editable?){};override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int){dialledNumber=s.toString()}})
        body.addView(number)
        val letters=mapOf("2" to "ABC","3" to "DEF","4" to "GHI","5" to "JKL","6" to "MNO","7" to "PQRS","8" to "TUV","9" to "WXYZ","0" to "+")
        for(row in listOf(listOf("1","2","3"),listOf("4","5","6"),listOf("7","8","9"),listOf("*","0","#"))) {
            val line=layout(true)
            for(digit in row) {
                val key=layout().apply { gravity=Gravity.CENTER;isClickable=true;isFocusable=true;contentDescription=digit;background=RippleDrawable(ColorStateList.valueOf(Color.parseColor("#33777777")),rounded(card),null)
                    addView(text(digit,27f,ink).apply{gravity=Gravity.CENTER;setPadding(0,0,0,0)})
                    addView(text(letters[digit] ?: "",10f,soft,true).apply{gravity=Gravity.CENTER;setPadding(0,0,0,0)})
                    setOnClickListener{if(PhoneService.instance?.call!=null)PhoneService.instance?.dtmf(digit[0]) else number.append(digit)}
                    if(digit=="0")setOnLongClickListener{if(PhoneService.instance?.call==null)number.append("+");true}
                };line.addView(key,spaced(height=if(compact)48 else 62))
            };body.addView(line)
        }
        val actions=keypadDock
        actions.addView(iconButton("Call",R.drawable.ic_call,tone=Color.parseColor("#16745B")){dial(number.text.toString())},spaced(3f,if(compact)60 else 72))
        actions.addView(iconButton("Delete digit",R.drawable.ic_backspace){if(number.text.isNotEmpty())number.text.delete(number.text.length-1,number.text.length)},spaced(1.3f,if(compact)60 else 72))
        if(!compact)body.addView(text("During a call, use the keypad for menu choices.",13f,soft))
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
    private fun dial(number:String) {
        try {
            val own=store.read()?.optJSONObject("account")?.optString("extension")
            if(number.trim()==own && PhoneService.instance?.call==null) {
                AlertDialog.Builder(this).setTitle("This is your own extension").setMessage("Calling yourself follows your own forwarding or voicemail settings. To speak to a colleague, choose their extension in Contacts.")
                    .setNegativeButton("Cancel",null).setPositiveButton("Call anyway"){_,_->try{PhoneService.instance?.dial(number) ?: error("Your phone is not connected yet")}catch(e:Exception){message(e.message ?: "The call could not start")}}.show();return
            }
            PhoneService.instance?.dial(number) ?: error("Your phone is not connected yet. Open Settings and choose Check connection.")
        } catch(e:Exception){message(e.message ?: "The call could not start")}
    }
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
        AlertDialog.Builder(this).setTitle("Your phone").setMessage(contents).setPositiveButton("Done",null).setNeutralButton("More"){_,_->AlertDialog.Builder(this).setItems(arrayOf("Check connection", "App updates", "Audio device", "Source and licenses")){_,index->when(index){0->connectionCheck();1->updateDialog();2->audioDevices();else->licenses()}}.show()}.setNegativeButton("Disconnect"){_,_->disconnect()}.show()
    }
    private fun connectionCheck() {
        async({api().json("bootstrap")},{
            val phone=PhoneService.instance
            val detail=when {checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED -> "Your PBX is reachable. Allow microphone access to make calls."
                phone?.status=="Ready for calls" -> "Your PBX is reachable and your phone is connected. If a number will not connect, ask your administrator to check that number’s calling rule and provider."
                else -> "Your PBX is reachable. Reconnecting the phone now…"}
            if(phone?.call==null) {if(phone==null)ensurePermissions()else phone.reconnect()}
            AlertDialog.Builder(this).setTitle("Connection check").setMessage(detail).setPositiveButton("Done",null).show()
        })
    }
    private fun updateUi() {
        if(!::updatePanel.isInitialized)return
        if(!urgentUpdateBypass && updates.automaticInstallAllowed() && updates.foregroundActivity===this && PhoneService.instance?.call==null)updates.install(this)
        val gate=updates.shouldGate(PhoneService.instance?.call!=null,urgentUpdateBypass)
        if(gate!=updateGated && store.read()!=null){draw();return}
        updatePanel.removeAllViews()
        if(updates.snapshot.state in listOf("idle","current") || gate)return
        val label=when(updates.snapshot.state){"error"->"Updates unavailable · Try again";"checking"->"Checking for updates…";"downloading"->"Downloading phone update…";"ready"->"Phone update ready · Install";"available"->"Phone update available · View";"confirmation","installing"->"Finish Android update · View";else->"App updates · View"}
        updatePanel.addView(button(label){updateDialog()}.apply{textSize=13f;minHeight=dp(32);minimumHeight=dp(32);maxLines=1})
    }
    private fun updateGate() {
        val release=updates.snapshot.release
        body.addView(text("Your phone update is ready",30f,ink,true))
        body.addView(text("Your organisation requires version ${release?.version ?: "the latest version"}. The complete download has been checked. Your account and settings will be kept.",17f,soft))
        body.addView(button("Install update"){updates.continueInstall(this)})
        body.addView(text("Android may ask you to allow installation or confirm the update. After installation, use Open or the OpenWeb PBX notification to reconnect.",14f,soft))
        keypadDock.visibility=View.VISIBLE
        keypadDock.addView(button("Use phone for an urgent call"){urgentUpdateBypass=true;updates.cancelInstall();section="Keypad";draw()},LinearLayout.LayoutParams(-1,dp(56)))
        body.addView(button("Check again"){updates.check()})
        body.addView(button("Connection and account settings"){settings()})
    }
    private fun updateDialog() {
        val state=updates.snapshot
        val message="Version ${BuildConfig.VERSION_NAME}\n\n${state.message}\n\n${if(state.mode=="required")"Your organisation requires available, verified phone updates." else if(state.mode=="download")"Updates download automatically; you choose when to install." else "You choose when to download and install updates."}\n\nAndroid may ask for installation permission or confirmation. After installation, choose Open or tap the phone notification. Your account is kept."
        val dialog=AlertDialog.Builder(this).setTitle("App updates").setMessage(message).setNegativeButton("Close",null)
        when(state.state) {
            "ready","permission","confirmation" -> dialog.setPositiveButton("Install update"){_,_->updates.continueInstall(this)}
            "available" -> dialog.setPositiveButton("Download update"){_,_->updates.check(true)}
            "installing" -> dialog.setPositiveButton("Check installation"){_,_->updates.continueInstall(this)}
            else -> dialog.setPositiveButton("Check again"){_,_->updates.check()}
        }
        if(updates.isInstalling)dialog.setNeutralButton("Cancel update"){_,_->updates.cancelInstall();startPhone()}
        dialog.show()
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
