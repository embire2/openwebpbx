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
    private var keypadNumber:EditText?=null
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
    private var updateDetails:AlertDialog?=null
    private var updateDetailsText:TextView?=null
    private var updateDetailsProgress:ProgressBar?=null
    private var openUpdatesRequested=false
    private val shownUpdatePrompts=mutableSetOf<String>()
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
            AlertDialog.Builder(this).setTitle("Connect your phone?").setMessage("Connect to ${URI(server).host}. Only scan codes provided by your PBX administrator.\n\n$privacySummary")
                .setNegativeButton("Cancel",null).setPositiveButton("Connect") { _, _ -> enroll(server,code) }.show()
        } catch(e: Exception) { message(e.message ?: "That QR code could not be read") }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        store = PhoneStore(this); section = savedInstanceState?.getString("section") ?: "Keypad"
        shownUpdatePrompts.addAll(savedInstanceState?.getStringArrayList("update_prompts") ?: emptyList())
        openUpdatesRequested=intent.getBooleanExtra("show_updates",false);intent.removeExtra("show_updates")
        draw();updates.schedule();updates.check()
        if(store.read() != null) { ensurePermissions(); bootstrap() }
    }
    override fun onResume() { super.onResume(); updates.foregroundActivity=this; updates.changed={runOnUiThread { if(store.read()!=null && !updates.isInstalling && PhoneService.instance==null && checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)startPhone();updatePhone();updateUi() }}; PhoneService.changed = { runOnUiThread { updatePhone();updateUi() } }; updatePhone();updateUi(); if(store.read()!=null && !updates.isInstalling && checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)startPhone() }
    override fun onPause() { PhoneService.changed = null;updates.changed=null;updates.foregroundActivity=null; super.onPause() }
    override fun onNewIntent(intent:Intent) { super.onNewIntent(intent);setIntent(intent);if(intent.getBooleanExtra("show_updates",false)){openUpdatesRequested=true;intent.removeExtra("show_updates");updateUi()} }
    override fun onSaveInstanceState(outState: Bundle) { outState.putString("section", section);outState.putStringArrayList("update_prompts",ArrayList(shownUpdatePrompts));super.onSaveInstanceState(outState) }
    override fun onDestroy() { updateDetails?.dismiss();stopPlayback(); worker.shutdown(); super.onDestroy() }
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
        gravity=Gravity.CENTER; minimumHeight=dp(if(compact)48 else 72);isClickable=true;isFocusable=true;contentDescription=label
        val fill=tone ?: if(selected)Color.parseColor("#16745B") else card;val foreground=if(tone!=null || selected)Color.WHITE else ink
        background=RippleDrawable(ColorStateList.valueOf(Color.parseColor("#33777777")),rounded(fill),null)
        setPadding(dp(6),dp(if(compact)2 else 10),dp(6),dp(if(compact)2 else 10))
        addView(ImageView(this@MainActivity).apply{setImageResource(icon);imageTintList=ColorStateList.valueOf(foreground);importantForAccessibility=View.IMPORTANT_FOR_ACCESSIBILITY_NO},LinearLayout.LayoutParams(dp(if(compact)22 else 26),dp(if(compact)22 else 26)))
        addView(text(label,12f,foreground,true).apply{gravity=Gravity.CENTER;maxLines=if(compact)1 else 2;if(compact)setPadding(0,0,0,0)})
        setOnClickListener{try{action()}catch(e:Exception){message(e.message ?: "Please try again")}}
    }
    private fun spaced(weight:Float=1f,height:Int=78)=LinearLayout.LayoutParams(0,dp(height),weight).apply{setMargins(dp(if(compact)2 else 4),dp(if(compact)2 else 4),dp(if(compact)2 else 4),dp(if(compact)2 else 4))}
    private fun message(value:String) { Toast.makeText(this,value,Toast.LENGTH_LONG).show() }
    private fun draw() {
        if(isFinishing)return
        dataGeneration++
        keypadNumber=null
        root = layout().apply { setBackgroundColor(paper); setPadding(dp(if(compact)16 else 20),dp(if(compact)6 else 12),dp(if(compact)16 else 20),dp(if(compact)6 else 12)) }
        root.setOnApplyWindowInsetsListener { view,insets -> view.setPadding(dp(if(compact)16 else 20),insets.systemWindowInsetTop+dp(if(compact)6 else 12),dp(if(compact)16 else 20),insets.systemWindowInsetBottom+dp(if(compact)6 else 12)); insets }
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
        for(name in navIcons.keys) nav.addView(iconButton(name,navIcons.getValue(name),name==section){ section=name; stopPlayback(); draw() },spaced(height=if(compact)48 else 74))
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
        body.addView(text(privacySummary,14f,soft))
        body.addView(button("Privacy and support") { privacy() })
        body.addView(text("Android 9 or newer · Version ${BuildConfig.VERSION_NAME}\nCalls stay connected while the phone notification is running. Reopen the app after restarting your phone or stopping it.",13f,soft))
    }
    private fun field(hint:String,value:String="",type:Int=InputType.TYPE_CLASS_TEXT) = EditText(this).apply { this.hint=hint; setText(value); inputType=type; setTextColor(ink); setHintTextColor(soft); minHeight=dp(52); setSingleLine(); importantForAutofill=View.IMPORTANT_FOR_AUTOFILL_NO }
    private fun manualEnrollment() {
        val fields=layout().apply { setPadding(dp(20),0,dp(20),0) }
        val host=field("https://your-pbx.example.com",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        val code=field("Connection code",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        fields.addView(host); fields.addView(code); fields.addView(text(privacySummary,13f,soft))
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
        val connection=phone?.status ?: if(updates.isInstalling)"Phone paused while Android updates" else "Open the phone to connect"
        val extension=account?.optString("extension","") ?: ""
        status.text=if(compact)"$extension · $connection" else "${account?.optString("display_name","") ?: ""} · Your extension $extension\n$connection"
        status.contentDescription="${account?.optString("display_name","") ?: ""}, extension $extension, $connection"
        if(compact){status.maxLines=1;status.ellipsize=android.text.TextUtils.TruncateAt.END}
        callPanel.removeAllViews();callPanel.setPadding(0,0,0,0);callPanel.background=null
        val call=phone?.call
        keypadNumber?.visibility=if(compact && call!=null)View.GONE else View.VISIBLE
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
        if(compact){
            callPanel.setPadding(dp(6),dp(3),dp(6),dp(3))
            callPanel.addView(text("$state · ${phone.callLabel}",15f,ink,true).apply{gravity=Gravity.CENTER;maxLines=1;ellipsize=android.text.TextUtils.TruncateAt.END;setPadding(0,dp(2),0,dp(2))})
            val actions=layout(true)
            if(call.state==Call.State.IncomingReceived){
                actions.addView(iconButton("Decline",R.drawable.ic_hangup,tone=Color.parseColor("#B3263E")){phone.hangup()},spaced(height=48))
                actions.addView(iconButton("Answer",R.drawable.ic_call,tone=Color.parseColor("#16745B")){ensurePermissions();if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)phone.answer()},spaced(height=48))
            }else{
                actions.addView(iconButton(if(phone.muted)"Unmute" else "Mute",if(phone.muted)R.drawable.ic_mic_off else R.drawable.ic_mic,phone.muted){phone.mute()},spaced(height=48))
                actions.addView(iconButton(if(call.state==Call.State.Paused)"Resume" else "Hold",if(call.state==Call.State.Paused)R.drawable.ic_play else R.drawable.ic_hold,call.state==Call.State.Paused){phone.hold()},spaced(height=48))
                actions.addView(iconButton(if(phone.speaker)"Earpiece" else "Speaker",R.drawable.ic_speaker,phone.speaker){phone.speaker()},spaced(height=48))
                actions.addView(iconButton("End call",R.drawable.ic_hangup,tone=Color.parseColor("#B3263E")){phone.hangup()},spaced(height=48))
            }
            callPanel.addView(actions);return
        }
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
        keypadNumber=number;number.visibility=if(compact && PhoneService.instance?.call!=null)View.GONE else View.VISIBLE
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
        actions.addView(iconButton("Call",R.drawable.ic_call,tone=Color.parseColor("#16745B")){dial(number.text.toString())},spaced(3f,if(compact)48 else 72))
        actions.addView(iconButton("Delete digit",R.drawable.ic_backspace){if(number.text.isNotEmpty())number.text.delete(number.text.length-1,number.text.length)},spaced(1.3f,if(compact)48 else 72))
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
        AlertDialog.Builder(this).setTitle("Your phone").setMessage(contents).setPositiveButton("Done",null).setNeutralButton("More"){_,_->AlertDialog.Builder(this).setItems(arrayOf("Check connection", "App updates", "Audio device", "Privacy and support", "Source and licenses")){_,index->when(index){0->connectionCheck();1->updateDialog();2->audioDevices();3->privacy();else->licenses()}}.show()}.setNegativeButton("Disconnect"){_,_->disconnect()}.show()
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
        val activeCall=PhoneService.instance?.call!=null
        if(activeCall)updateDetails?.dismiss()
        val gate=updates.shouldGate(activeCall,urgentUpdateBypass)
        if(gate!=updateGated && store.read()!=null){draw();return}
        updatePanel.removeAllViews()
        val state=updates.snapshot;val view=UpdatePresentation.describe(state,activeCall)
        updatePanel.visibility=if(state.state in listOf("idle","current") || gate)View.GONE else View.VISIBLE
        if(updatePanel.visibility==View.VISIBLE){
            val fill=Color.parseColor(if(view.required){if(dark)"#44351D" else "#FFF0CC"}else if(dark)"#163B32" else "#DDF3EA")
            updatePanel.background=rounded(fill);updatePanel.setPadding(dp(12),dp(7),dp(12),dp(7))
            updatePanel.layoutParams=LinearLayout.LayoutParams(-1,-2).apply{setMargins(0,dp(8),0,dp(4))}
            updatePanel.contentDescription="App update: ${view.title}"
            if(activeCall){
                // Keep the answer and hang-up controls visible on small screens.
                updatePanel.addView(text(if(view.required)"Required update · After your call" else view.title,14f,ink,true))
                updatePanel.isClickable=true;updatePanel.setOnClickListener{openUpdatesRequested=true;message("The update will wait until your call ends.")}
            }else if(compact && drawnAccount){
                updatePanel.setPadding(dp(8),dp(4),dp(8),dp(4))
                updatePanel.layoutParams=LinearLayout.LayoutParams(-1,-2).apply{setMargins(0,dp(5),0,dp(3))}
                updatePanel.isClickable=true;updatePanel.setOnClickListener{updateDialog()}
                val row=layout(true).apply{gravity=Gravity.CENTER_VERTICAL};val summary=layout()
                val label=when(state.state){"downloading"->"${if(view.required)"Required update" else "Update"} ${state.displayVersion ?: ""}";"ready","permission","confirmation"->if(view.required)"Required update ready" else "Update ready";else->view.title}
                summary.addView(text(label,13f,ink,true).apply{maxLines=1;ellipsize=android.text.TextUtils.TruncateAt.END;setPadding(0,0,0,0)})
                summary.addView(text(view.detail,12f,soft).apply{maxLines=1;ellipsize=android.text.TextUtils.TruncateAt.END;setPadding(0,0,0,0)})
                if(view.showProgress)summary.addView(updateProgress(view),LinearLayout.LayoutParams(-1,dp(4)).apply{setMargins(0,dp(3),dp(6),0)})
                row.addView(summary,LinearLayout.LayoutParams(0,-2,1f))
                val action=if(view.actionEnabled)updateActionButton(view.copy(action=when(state.state){"available"->if(state.actionLabel==null)"Download" else "Google Play";"ready","permission","confirmation"->"Install";"store"->"Google Play";else->"Details"})).apply{setOnClickListener{if(state.state in listOf("available","ready","permission","confirmation","store"))performUpdateAction()else updateDialog()}}else button("Details"){updateDialog()}
                action.textSize=12f;action.setPadding(dp(4),0,dp(4),0);row.addView(action,LinearLayout.LayoutParams(dp(88),dp(48)).apply{setMargins(dp(6),0,0,0)})
                updatePanel.addView(row)
            }else{
                updatePanel.isClickable=false;updatePanel.setOnClickListener(null)
                updatePanel.addView(text(view.title,17f,ink,true))
                updatePanel.addView(text(view.detail,13f,soft))
                if(view.showProgress)updatePanel.addView(updateProgress(view),LinearLayout.LayoutParams(-1,dp(8)).apply{setMargins(0,dp(4),0,dp(6))})
                val actions=layout(true)
                actions.addView(updateActionButton(view),LinearLayout.LayoutParams(0,dp(48),1.4f))
                actions.addView(button("Details"){updateDialog()},LinearLayout.LayoutParams(0,dp(48),1f).apply{setMargins(dp(8),0,0,0)})
                updatePanel.addView(actions)
            }
        }
        refreshUpdateDialog()
        if(updates.foregroundActivity!==this || isFinishing || isDestroyed || activeCall)return
        val prompt=UpdatePresentation.promptKey(state,activeCall,gate,urgentUpdateBypass)
        if(openUpdatesRequested){openUpdatesRequested=false;updateDialog()}
        else if(prompt!=null && shownUpdatePrompts.add(prompt))updateDialog()
    }
    private fun updateProgress(view:UpdateViewState)=ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal).apply{
        max=100;isIndeterminate=view.percent==null;progress=view.percent?:0
        progressTintList=ColorStateList.valueOf(green);indeterminateTintList=ColorStateList.valueOf(green)
        contentDescription=if(view.percent==null)view.detail else "Update download ${view.percent} percent"
    }
    private fun updateActionButton(view:UpdateViewState)=button(view.action){performUpdateAction()}.apply{
        backgroundTintList=ColorStateList.valueOf(Color.parseColor("#16745B"));setTextColor(Color.WHITE);isEnabled=view.actionEnabled;alpha=if(isEnabled)1f else .65f
    }
    private fun performUpdateAction(){
        if(updates.snapshot.actionLabel=="Open Google Play"){updates.check(true);updateDialog();return}
        when(updates.snapshot.state){
            "available","store"->{updates.check(true);updateDialog()}
            "ready","permission","confirmation"->{if(PhoneService.instance?.call==null){updateDetails?.dismiss();updates.continueInstall(this)}}
            "downloading","verifying","installing","checking"->Unit
            else->{updates.check();updateDialog()}
        }
    }
    private fun updateGate() {
        val state=updates.snapshot
        body.addView(text("UPDATE REQUIRED",14f,green,true))
        body.addView(text(state.gateTitle,30f,ink,true))
        body.addView(text(state.gateMessage ?: "Your organisation requires version ${state.displayVersion ?: "the latest version"}. The complete download is ready. Your account and settings will be kept.",17f,soft))
        body.addView(updateActionButton(UpdatePresentation.describe(state,false)))
        body.addView(text(updates.installationHelp,14f,soft))
        keypadDock.visibility=View.VISIBLE
        keypadDock.addView(button("Use phone for an urgent call"){urgentUpdateBypass=true;updates.cancelInstall();section="Keypad";draw()},LinearLayout.LayoutParams(-1,dp(56)))
        body.addView(button("Check again"){updates.check()})
        body.addView(button("Connection and account settings"){settings()})
    }
    private fun updateDialog() {
        if(isFinishing || isDestroyed)return
        if(PhoneService.instance?.call!=null){openUpdatesRequested=true;return}
        if(updateDetails?.isShowing==true){refreshUpdateDialog();return}
        UpdatePresentation.promptKey(updates.snapshot,false,false,urgentUpdateBypass)?.let{shownUpdatePrompts.add(it)}
        val contents=layout().apply{setPadding(dp(24),dp(8),dp(24),dp(8))}
        updateDetailsText=text("",15f,ink);contents.addView(updateDetailsText)
        updateDetailsProgress=updateProgress(UpdatePresentation.describe(updates.snapshot,false));contents.addView(updateDetailsProgress,LinearLayout.LayoutParams(-1,dp(12)))
        val scroll=ScrollView(this).apply{addView(contents)}
        val dialog=AlertDialog.Builder(this).setTitle("App updates").setView(scroll).setNegativeButton("Close",null).setPositiveButton("Check for updates",null).setNeutralButton("Cancel installation",null).create()
        updateDetails=dialog
        dialog.setOnDismissListener{if(updateDetails===dialog){updateDetails=null;updateDetailsText=null;updateDetailsProgress=null}}
        dialog.setOnShowListener{
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener{performUpdateAction()}
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener{updates.cancelInstall();startPhone();refreshUpdateDialog()}
            refreshUpdateDialog()
        }
        dialog.show()
    }
    private fun refreshUpdateDialog(){
        val dialog=updateDetails?:return;if(!dialog.isShowing)return
        val state=updates.snapshot;val view=UpdatePresentation.describe(state,PhoneService.instance?.call!=null)
        dialog.setTitle(view.title)
        updateDetailsText?.text="Installed version ${BuildConfig.VERSION_NAME}\n\n${view.detail}\n\n${state.policyMessage ?: if(view.required)"Required by your organisation. The update downloads first and waits for any call to finish." else if(state.mode=="download")"Updates download automatically; you choose when to install." else "You choose when to download and install updates."}\n\n${updates.installationHelp}"
        updateDetailsProgress?.apply{visibility=if(view.showProgress)View.VISIBLE else View.GONE;isIndeterminate=view.percent==null;progress=view.percent?:0;contentDescription=if(view.percent==null)view.detail else "Update download ${view.percent} percent"}
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.apply{text=view.action;isEnabled=view.actionEnabled}
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL)?.visibility=if(updates.isInstalling)View.VISIBLE else View.GONE
    }
    private val privacySummary = "Your organisation’s PBX receives your device name, connection details and call history. During calls it carries your microphone audio, including while the app is in the background. Your administrator controls recordings and retention. The camera is used only to scan your connection QR code."
    private fun privacy() {
        AlertDialog.Builder(this).setTitle("Privacy and support").setMessage("$privacySummary\n\nNo advertising or advertising tracking. Settings → Disconnect removes this phone’s connection and local account data. To request deletion of your PBX account or server records, contact your administrator or follow the data removal instructions.")
            .setPositiveButton("Privacy policy") { _,_ -> openPublicPage("privacy.html") }
            .setNeutralButton("Remove my data") { _,_ -> openPublicPage("data-removal.html") }
            .setNegativeButton("Support") { _,_ -> openPublicPage("support.html") }.show()
    }
    private fun openPublicPage(page: String) {
        startActivity(Intent(Intent.ACTION_VIEW,android.net.Uri.parse("https://openwebpbx.com/$page")))
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
