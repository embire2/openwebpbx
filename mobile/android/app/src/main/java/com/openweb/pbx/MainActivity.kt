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
import android.media.RingtoneManager
import android.app.NotificationManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.WindowManager
import android.widget.*
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
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
    private lateinit var preferences: PhonePreferences
    private var settingsReturnSection="Keypad"
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
    private var drawnReady = false
    private var drawnProfile:String?=null
    private val requestProfile=ThreadLocal<String?>()
    private var importedIntent=false
    private var storageUnavailable=false
    private val enteredTenantOrigins=mutableMapOf<String,String>()
    private var playbackGeneration = 0
    private var dialledNumber = ""
    private var urgentUpdateBypass = false
    private var updateGated = false
    private lateinit var updatePanel:LinearLayout
    private var updateDetails:AlertDialog?=null
    private var updateDetailsText:TextView?=null
    private var updateDetailsProgress:ProgressBar?=null
    private var openUpdatesRequested=false
    private var availabilityDialog:AlertDialog?=null
    private val shownUpdatePrompts=mutableSetOf<String>()
    private val updates get()=UpdateManager.get(this)
    private val accountChanges = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _,_ ->
        runOnUiThread { refreshConnection() }
    }
    private fun refreshConnection() {
        if(isFinishing || isDestroyed || !::store.isInitialized || storageUnavailable)return
        if((store.read()!=null)!=drawnAccount || drawnProfile!=store.selectedId() || (store.read()?.let{TenantConnection.ready(it)}==true)!=drawnReady) {
            bootstrapped=false;stopPlayback()
            draw()
            if(drawnReady) { ensurePermissions();bootstrap() }
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
    private val dark get() = PhonePreferenceRules.dark(preferences.theme,resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES)
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
        result.contents?.let{confirmSetup(it)}
    }
    private val setupFile=registerForActivityResult(ActivityResultContracts.OpenDocument()){uri->if(uri!=null)importSetup(uri)}
    private fun confirmSetup(raw:String){
        try {
            requireProfileIdle()
            val data=ProfileRules.setup(raw);val server=data.getString("server");val code=data.getString("code")
            if(store.read()?.let{TenantConnection.ready(it)}==true)require(store.profiles().all{TenantConnection.ready(it)}){"Confirm your saved accounts' tenant addresses in Accounts before adding another connection."}
            store.read()?.takeIf{!TenantConnection.ready(it)}?.let{pending->
                require(enteredTenantOrigins[pending.getString("profile_id")]==server){"Enter this account's tenant address before scanning its new QR code."}
            }
            AlertDialog.Builder(this).setTitle("Add this phone account?").setMessage("Connect to ${URI(server).host}${data.optString("extension").takeIf{it.isNotBlank()}?.let{" · Extension $it"} ?: ""}. Only use setup details supplied by your administrator.\n\n$privacySummary")
                .setNegativeButton("Cancel",null).setPositiveButton("Connect"){_,_->enroll(server,code)}.show()
        }catch(e:Exception){message(e.message ?: "That setup file or QR code could not be read")}
    }
    private fun importSetup(uri:Uri){
        try{
            requireProfileIdle();require(uri.scheme=="content"){"Choose the setup file from your phone's file picker"}
            // Email/document providers may fetch the attachment remotely. Keep
            // their bounded read off the calling/UI thread; confirm again after it.
            async({
                val name=contentResolver.query(uri,arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),null,null,null)?.use{cursor->if(cursor.moveToFirst())cursor.getString(0) else null}
                require(name?.endsWith(".openwebpbx",true)==true){"Choose a .openwebpbx setup file"}
                val bytes=contentResolver.openInputStream(uri)?.use{input->val out=java.io.ByteArrayOutputStream();val buffer=ByteArray(2048);while(true){val n=input.read(buffer);if(n<0)break;require(out.size()+n<=ProfileRules.MAX_SETUP_BYTES){"That setup file is too large"};out.write(buffer,0,n)};out.toByteArray()} ?: error("Could not open that file")
                String(bytes,Charsets.UTF_8)
            },{confirmSetup(it)},markRevoked=false)
        }catch(e:Exception){message(e.message ?: "Could not open that setup file")}
    }
    private fun importIntent(){if(intent.action==Intent.ACTION_VIEW && !importedIntent){importedIntent=true;intent.data?.let{importSetup(it)}}}
    override fun onCreate(savedInstanceState: Bundle?) {
        preferences=PhonePreferences(this)
        setTheme(if(dark)android.R.style.Theme_Material_NoActionBar else R.style.AppThemeLight)
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        store = PhoneStore(this)
        try{store.profiles()}catch(_:Exception){storageUnavailable=true;storageRecovery();return}
        section = savedInstanceState?.getString("section") ?: preferences.startupPage
        settingsReturnSection=savedInstanceState?.getString("settings_return") ?: "Keypad"
        onBackPressedDispatcher.addCallback(this){if(section=="Settings"){section=settingsReturnSection;draw()}else{isEnabled=false;onBackPressedDispatcher.onBackPressed();isEnabled=true}}
        shownUpdatePrompts.addAll(savedInstanceState?.getStringArrayList("update_prompts") ?: emptyList())
        openUpdatesRequested=intent.getBooleanExtra("show_updates",false);intent.removeExtra("show_updates")
        draw();updates.schedule();updates.check()
        if(store.read()?.let{TenantConnection.ready(it)}==true) { ensurePermissions(); bootstrap() };importIntent()
    }
    override fun onResume() { super.onResume();if(storageUnavailable)return; updates.foregroundActivity=this; updates.changed={runOnUiThread { if(store.read()!=null && !updates.isInstalling && PhoneService.instance==null && checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)startPhone();updatePhone();updateUi() }}; PhoneService.changed = { runOnUiThread { updatePhone();updateUi() } }; if(section=="Settings")draw();updatePhone();updateUi(); if(store.read()!=null && !updates.isInstalling && checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)startPhone() }
    override fun onPause() { if(storageUnavailable){super.onPause();return};PhoneService.changed = null;updates.changed=null;updates.foregroundActivity=null; super.onPause() }
    override fun onNewIntent(intent:Intent) { super.onNewIntent(intent);setIntent(intent);if(storageUnavailable)return;importedIntent=false;importIntent();if(intent.getBooleanExtra("show_updates",false)){openUpdatesRequested=true;intent.removeExtra("show_updates");updateUi()} }
    override fun onSaveInstanceState(outState: Bundle) { outState.putString("section", section);outState.putString("settings_return",settingsReturnSection);outState.putStringArrayList("update_prompts",ArrayList(shownUpdatePrompts));super.onSaveInstanceState(outState) }
    override fun onDestroy() { availabilityDialog?.dismiss();updateDetails?.dismiss();stopPlayback(); worker.shutdown(); super.onDestroy() }
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
        window.decorView.systemUiVisibility=if(dark)0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        window.statusBarColor=paper;window.navigationBarColor=paper
        val heading=layout(true); heading.gravity=Gravity.CENTER_VERTICAL
        heading.addView(text(getString(R.string.app_name),if(compact)18f else 20f,ink,true).apply { maxLines=2; minimumHeight=dp(if(compact)44 else 52); gravity=Gravity.CENTER_VERTICAL },LinearLayout.LayoutParams(0,-2,1f))
        if(store.read()!=null) heading.addView(button(if(section=="Settings")"Done" else "Settings") { if(section=="Settings"){section=settingsReturnSection;draw()}else settings() })
        root.addView(heading)
        status=text("Your work phone, wherever you are",14f,soft); status.setPadding(dp(12),dp(if(compact)5 else 10),dp(12),dp(if(compact)5 else 10));status.background=rounded(card);val statusRow=layout(true);statusRow.gravity=Gravity.CENTER_VERTICAL;statusRow.addView(status,LinearLayout.LayoutParams(0,-2,1f));if(store.read()!=null)statusRow.addView(button("Status"){availability()},LinearLayout.LayoutParams(dp(78),dp(48)));root.addView(statusRow)
        updatePanel=layout();root.addView(updatePanel)
        callPanel=layout(); root.addView(callPanel)
        val scroll=ScrollView(this).apply { isFillViewport=true }; body=layout(); scroll.addView(body)
        root.addView(scroll,LinearLayout.LayoutParams(-1,0,1f))
        keypadDock=layout(true);root.addView(keypadDock)
        drawnAccount=store.read()!=null;drawnProfile=store.selectedId();drawnReady=store.read()?.let{TenantConnection.ready(it)}==true
        if(!drawnAccount) { welcome(); return }
        if(!TenantConnection.ready(store.read()!!)){tenantAddressGate();return}
        val nav=layout(true)
        val navIcons=mapOf("Keypad" to R.drawable.ic_keypad,"Contacts" to R.drawable.ic_contacts,"Recents" to R.drawable.ic_recents,"Voicemail" to R.drawable.ic_voicemail)
        for(name in navIcons.keys) nav.addView(iconButton(name,navIcons.getValue(name),name==section){ section=name; stopPlayback(); draw() },spaced(height=if(compact)48 else 74))
        root.addView(nav)
        updateGated=updates.shouldGate(PhoneService.instance?.call!=null,urgentUpdateBypass);updatePhone()
        if(updateGated && section!="Settings") { updateGate();updateUi();return }
        when(section) { "Keypad" -> keypad(); "Contacts" -> contacts(); "Recents" -> recents(); "Voicemail" -> voicemail(); "Settings"->settingsPage() };updateUi()
    }
    private fun storageRecovery(){
        root=layout().apply{setPadding(dp(20),dp(40),dp(20),dp(20));setBackgroundColor(paper)};body=layout();root.addView(ScrollView(this).apply{addView(body)});setContentView(root)
        body.addView(text("Saved accounts could not be opened",26f,ink,true))
        body.addView(text("Your encrypted account data has been kept. Try reopening the app. If your phone's security key is unavailable, reset the local accounts and sign in again. Server accounts and records are not deleted; your administrator can revoke old phone connections.",16f,soft))
        body.addView(button("Try again"){recreate()})
        body.addView(button("Reset local accounts"){AlertDialog.Builder(this).setTitle("Reset this phone's saved accounts?").setMessage("This removes local credentials only. You will need your app passwords or new setup codes to reconnect.").setNegativeButton("Cancel",null).setPositiveButton("Reset"){_,_->store.clear();recreate()}.show()})
        policyLinks()
    }
    private fun welcome() {
        body.addView(text("Meet your new\nwork phone.",36f,ink,true))
        body.addView(text("Call your team, reach customers and listen to voicemail in one place.",18f,soft))
        body.addView(text("1. Open Users → Phone Provisioning in your PBX.\n2. Create your Android connection code.\n3. Scan the QR code below.",16f,soft))
        body.addView(button("Scan QR code") { scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan the QR code shown in your PBX").setBeepEnabled(false).setOrientationLocked(false)) })
        body.addView(button("Sign in with an app password"){manualLogin()})
        body.addView(button("Import a setup file"){requireProfileIdle();setupFile.launch(arrayOf("*/*"))})
        body.addView(button("Enter a connection code instead") { manualEnrollment() })
        body.addView(text(privacySummary,14f,soft))
        policyLinks()
        body.addView(button("Privacy and support") { privacy() })
        body.addView(text("Android 9 or newer · Version ${BuildConfig.VERSION_NAME}\nCalls stay connected while the phone notification is running. Reopen the app after restarting your phone or stopping it.",13f,soft))
    }
    private fun tenantAddressGate(){
        val profile=store.read() ?: return;val id=profile.getString("profile_id")
        body.addView(text("Enter your tenant address",28f,ink,true))
        body.addView(text("OpenWebPBX Free Phone now connects only through your tenant's openwebpbx.com address. Every saved account must confirm its address once.",16f,soft))
        body.addView(text("${ProfileRules.label(profile)}\nYour saved account and calling settings have been kept.",15f,soft))
        val host=field("https://company.openwebpbx.com",enteredTenantOrigins[id] ?: "",InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        body.addView(host)
        body.addView(button("Confirm tenant address"){
            try{
                requireProfileIdle();val server=Enrollment.tenant(host.text.toString());if(busy)return@button;busy=true
                async({
                    val proof=TenantConnection.lookup(server)
                    val latest=store.read(id) ?: error("This account was removed")
                    val candidate=TenantConnection.candidate(latest,server,proof)
                    val response=PhoneApi.profile(candidate).json("bootstrap")
                    store.update(id){saved->
                        val completed=TenantConnection.complete(TenantConnection.candidate(saved,server,proof),response)
                        for(key in completed.keys())saved.put(key,completed.get(key))
                        saved.remove("update_policy")
                    };server
                },{origin->enteredTenantOrigins[id]=origin;busy=false;bootstrapped=false;store.read(id)?.let{PushConnection.configure(this,it)};draw();ensurePermissions();bootstrap();updates.check()},{busy=false},scope=id,markRevoked=false)
            }catch(e:Exception){host.error=e.message;busy=false}
        })
        body.addView(button("Enter address and use a new QR code"){
            try{
                requireProfileIdle();val server=Enrollment.tenant(host.text.toString());if(busy)return@button;busy=true
                async({TenantConnection.lookup(server);server},{origin->enteredTenantOrigins[id]=origin;busy=false;scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan your tenant's new connection code").setBeepEnabled(false))},{busy=false},scope=id,markRevoked=false)
            }catch(e:Exception){host.error=e.message;busy=false}
        })
        if(profile.optJSONArray("features")?.let{list->(0 until list.length()).any{list.optString(it)=="app_password"}}==true)body.addView(button("Enter address and sign in with a password"){
            try{
                requireProfileIdle();val server=Enrollment.tenant(host.text.toString());busy=true
                async({TenantConnection.lookup(server);server},{origin->enteredTenantOrigins[id]=origin;busy=false;manualLogin(profile)},{busy=false},scope=id,markRevoked=false)
            }catch(e:Exception){host.error=e.message;busy=false}
        })
        body.addView(button("Accounts"){accounts()})
        policyLinks()
        status.text="Tenant address required · Calling is paused for this account"
    }
    private fun field(hint:String,value:String="",type:Int=InputType.TYPE_CLASS_TEXT) = EditText(this).apply { this.hint=hint; setText(value); inputType=type; setTextColor(ink); setHintTextColor(soft); minHeight=dp(52); setSingleLine(); importantForAutofill=View.IMPORTANT_FOR_AUTOFILL_NO }
    private fun manualEnrollment() {
        requireProfileIdle()
        val fields=layout().apply { setPadding(dp(20),0,dp(20),0) }
        val host=field("https://company.openwebpbx.com",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        val code=field("Connection code",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        fields.addView(host); fields.addView(code); fields.addView(text(privacySummary,13f,soft))
        val dialog=AlertDialog.Builder(this).setTitle("Connect your phone").setView(fields).setNegativeButton("Cancel",null).setPositiveButton("Connect",null).create()
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            try { val s=Enrollment.server(host.text.toString()); val c=Enrollment.code(code.text.toString());store.read()?.takeIf{!TenantConnection.ready(it)}?.let{enteredTenantOrigins[it.getString("profile_id")]=s}; dialog.dismiss(); enroll(s,c) } catch(e:Exception) { code.error=e.message }
        } }; dialog.show()
    }
    private fun requireProfileIdle(){
        check(!busy){"Wait for the current account request to finish."}
        check(ProfileRules.canChange(PhoneService.instance?.calls?.size ?: 0,updates.isInstalling)){"Finish your calls or the app update before changing accounts"}
    }
    private fun enroll(server:String,code:String)=connectAccount(server,"enroll",JSONObject().put("code",code))
    private fun connectAccount(server:String,action:String,body:JSONObject){
        requireProfileIdle();if(busy)return;busy=true;status.text="Connecting your account…"
        async({
            val proof=TenantConnection.lookup(server)
            if(action=="login")require(PhoneApi(server).json("capabilities").optBoolean("app_password")){"Use your administrator's QR code. App-password sign-in needs an updated PBX."}
            val response=ProfileRules.connected(PhoneApi(server).json(action,body.put("device_name","${Build.MANUFACTURER} ${Build.MODEL}").put("platform","android")),server)
            require(response.getJSONObject("account").getString("domain_uuid")==proof.getString("domainUuid")){"This connection belongs to another tenant."}
            response.put("tenant_instance_origin",proof.getString("serverOrigin")).put("tenant_domain_uuid",proof.getString("domainUuid"))
            // Persist outside the Activity callback: rotation cannot consume and lose a one-use code.
            try{
                val duplicates=store.profiles().filter{ProfileRules.sameAccount(it,response) || (!TenantConnection.ready(it) && TenantConnection.sameRestoredAccount(it,response,proof))}
                require(duplicates.size<=1){"More than one saved account matches. Remove an unused copy in Accounts, then try again."}
                val duplicate=duplicates.singleOrNull()
                if(duplicate!=null && !TenantConnection.ready(duplicate))require(enteredTenantOrigins[duplicate.getString("profile_id")]==server){"Select this saved account in Accounts and enter its tenant address before reconnecting it."}
                if(duplicate!=null && !TenantConnection.ready(duplicate)){
                    response.put("profile_id",duplicate.getString("profile_id"));response.put("profile_name",duplicate.optString("profile_name"));duplicate.optJSONArray("pending_calls")?.let{response.put("pending_calls",it)};store.save(response)
                }else store.add(response,select=false)
            }catch(e:Exception){try{PhoneApi.profile(response).json("revoke",JSONObject())}catch(_:Exception){};throw e}
            PushConnection.configure(this,response);response.getString("profile_id")
        },{ id ->busy=false;if(PhoneService.instance?.calls?.isEmpty()!=false)store.select(id);bootstrapped=false;draw();ensurePermissions();bootstrap();updates.check()},{busy=false;updatePhone()},acceptProfileChange=true)
    }
    private fun manualLogin(profile:JSONObject?=null){
        requireProfileIdle()
        val fields=layout().apply{setPadding(dp(20),0,dp(20),0)}
        // Canonical metadata is only an editable suggestion for a new password
        // login. No saved bearer token is sent to this suggested origin.
        val suggested=profile?.optJSONObject("account")?.optString("server")?.takeIf{it.isNotBlank()}?.let{try{Enrollment.server(it)}catch(_:Exception){null}}
        val host=field("Tenant address · company.openwebpbx.com",profile?.optString("profile_id")?.let{enteredTenantOrigins[it]} ?: suggested ?: "",InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        val extension=field("Extension",profile?.getJSONObject("account")?.optString("extension") ?: "",InputType.TYPE_CLASS_NUMBER)
        val password=field("App password",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        fields.addView(text("Enter your tenant name, extension and the app password set by your administrator. Your phone's SIP password is separate.",14f,soft));fields.addView(host);fields.addView(extension);fields.addView(password);fields.addView(text(privacySummary,13f,soft))
        val dialog=AlertDialog.Builder(this).setTitle("Sign in to your phone").setView(ScrollView(this).apply{addView(fields)}).setNegativeButton("Cancel",null).setPositiveButton("Sign in",null).create()
        dialog.setOnShowListener{dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener{
            try{requireProfileIdle();val server=Enrollment.tenant(host.text.toString());val number=extension.text.toString().trim();require(number.matches(Regex("[0-9]{1,16}"))){"Enter your extension"};require(password.text.isNotEmpty()){"Enter your app password"};val secret=password.text.toString();password.text.clear();(profile ?: store.read())?.takeIf{!TenantConnection.ready(it)}?.let{enteredTenantOrigins[it.getString("profile_id")]=server};dialog.dismiss();connectAccount(server,"login",JSONObject().put("extension",number).put("password",secret))}catch(e:Exception){password.error=e.message}
        }};dialog.show()
    }
    private fun accounts(){
        val saved=store.profiles();val contents=layout().apply{setPadding(dp(20),0,dp(20),0)}
        contents.addView(text("All connected accounts can receive calls. Choose which account makes new calls and shows contacts and voicemail.",14f,soft))
        val dialog=AlertDialog.Builder(this).setTitle("Phone accounts").setView(ScrollView(this).apply{addView(contents)}).setNegativeButton("Done",null).create()
        for(profile in saved){val id=profile.getString("profile_id");contents.addView(button((if(id==store.selectedId())"✓ " else "")+ProfileRules.label(profile)){
            requireProfileIdle();store.select(id);PhoneService.instance?.syncProfiles();dialog.dismiss();bootstrapped=false;section="Keypad";draw();bootstrap();updates.check()
        });contents.addView(text(if(!TenantConnection.ready(profile))"Enter tenant address to reconnect" else PhoneService.instance?.profileStatus(id) ?: "Connecting…",13f,soft));contents.addView(button("Edit ${ProfileRules.label(profile)}"){requireProfileIdle();dialog.dismiss();editProfile(id)})}
        contents.addView(button("Add an account"){requireProfileIdle();dialog.dismiss();addAccount()});dialog.show()
    }
    private fun addAccount(){
        requireProfileIdle();require(store.profiles().size<ProfileRules.MAX_PROFILES){"Remove an account before adding another"}
        AlertDialog.Builder(this).setTitle("Add a phone account").setItems(arrayOf("Scan QR code","Sign in with an app password","Import a setup file","Enter a connection code")){_,index->
            when(index){0->scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan your administrator's QR code").setBeepEnabled(false));1->manualLogin();2->setupFile.launch(arrayOf("*/*"));3->manualEnrollment()}
        }.setNegativeButton("Cancel",null).show()
    }
    private fun editProfile(id:String){
        requireProfileIdle();val profile=store.read(id) ?: return
        val fields=layout().apply{setPadding(dp(20),0,dp(20),0)};val name=field("Account name",ProfileRules.label(profile))
        fields.addView(name);fields.addView(text("${profile.getString("server")}\nExtension ${profile.getJSONObject("account").optString("extension")}",14f,soft))
        fields.addView(text("The name is saved only on this phone. To use another tenant or extension, add its account.",13f,soft))
        val dialog=AlertDialog.Builder(this).setTitle("Edit account").setView(fields).setNegativeButton("Cancel",null).setPositiveButton("Save",null).setNeutralButton("Remove",null).create()
        if(profile.optBoolean("needs_login") && TenantConnection.confirmed(profile)){
            fields.addView(button("Sign in again"){dialog.dismiss();manualLogin(profile)})
        }else if(!TenantConnection.confirmed(profile)){
            fields.addView(button("Enter tenant address"){store.select(id);dialog.dismiss();draw()})
            fields.addView(button("Use a new QR code"){requireProfileIdle();dialog.dismiss();scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan your administrator's QR code").setBeepEnabled(false))})
            fields.addView(text("If your administrator gives you a different tenant address, connect it as a new account, then remove this old saved account.",13f,soft))
        }
        dialog.setOnShowListener{
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener{try{requireProfileIdle();val value=name.text.toString().trim();require(value.length in 1..80 && value.none{it.isISOControl()}){"Use an account name between 1 and 80 characters"};store.update(id){it.put("profile_name",value)};dialog.dismiss();draw()}catch(e:Exception){name.error=e.message}}
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener{requireProfileIdle();dialog.dismiss();removeProfile(id)}
        };dialog.show()
    }
    private fun changeAppPassword(){
        requireProfileIdle();val id=store.selectedId() ?: return
        val identity=store.read(id)?.getJSONObject("account") ?: return
        val initialize=!identity.optBoolean("app_password_set",true) && identity.optBoolean("can_initialize_app_password")
        if(!identity.optBoolean("app_password_set",true) && !initialize){message("Ask your administrator to set an app password, or connect with a new QR code before creating one.");return}
        val fields=layout().apply{setPadding(dp(20),0,dp(20),0)}
        val current=field("Current app password",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD);val next=field("New app password",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD);val repeated=field("Repeat new password",type=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        fields.addView(text("This phone stays connected. Other app sessions and unused setup codes for this account will be disconnected. Your SIP password does not change.",14f,soft));if(!initialize)fields.addView(current);fields.addView(next);fields.addView(repeated)
        val dialog=AlertDialog.Builder(this).setTitle(if(initialize)"Create app password" else "Change app password").setView(ScrollView(this).apply{addView(fields)}).setNegativeButton("Cancel",null).setPositiveButton("Change password",null).create()
        dialog.setOnShowListener{dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener{try{
            requireProfileIdle();require(initialize || current.text.isNotEmpty()){"Enter your current app password"};require(ProfileRules.appPassword(next.text.toString())){"Use between 12 and 128 characters for your new password"};require(next.text.toString()==repeated.text.toString()){"The new passwords do not match"}
            val body=JSONObject().put("current_password",current.text.toString()).put("new_password",next.text.toString());current.text.clear();next.text.clear();repeated.text.clear();dialog.dismiss()
            async({api().json("change_password",body)},{store.update(id){it.getJSONObject("account").put("app_password_set",true).put("can_initialize_app_password",false)};message("App password saved. This phone is still connected.");draw()},scope=id,markRevoked=false)
        }catch(e:Exception){repeated.error=e.message}}};dialog.show()
    }
    private fun ensurePermissions() {
        val needed=mutableListOf<String>()
        if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.RECORD_AUDIO)
        if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.POST_NOTIFICATIONS)
        if(Build.VERSION.SDK_INT>=31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)!=PackageManager.PERMISSION_GRANTED) needed.add(Manifest.permission.BLUETOOTH_CONNECT)
        if(needed.isEmpty())startPhone() else permissions.launch(needed.toTypedArray())
    }
    private fun startPhone() { if(store.profiles().any{TenantConnection.ready(it)} && PhoneService.instance==null && !updates.isInstalling) startForegroundService(Intent(this,PhoneService::class.java)); updatePhone() }
    private fun updatePhone() {
        if(!::status.isInitialized || store.read()==null)return
        val phone=PhoneService.instance; val selected=store.read();val account=selected?.optJSONObject("account")
        val connection=if(selected?.optBoolean("needs_login")==true)"Sign in again in Accounts" else phone?.status ?: if(updates.isInstalling)"Phone paused while Android updates" else "Open the phone to connect"
        val extension=account?.optString("extension","") ?: ""
        status.text=if(compact)"${selected?.let{ProfileRules.label(it)}} · $connection" else "${account?.optString("display_name","") ?: ""} · Your extension $extension\n$connection"
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
        val state=if(phone.conferenceOnHold)"On hold" else if(phone.conferenceJoinFailed)"Three-way audio needs retry" else if(phone.conference!=null && !phone.conference!!.isIn)"Connecting three-way audio…" else if(phone.conference!=null)"Three-way call" else when(call.state) { Call.State.IncomingReceived -> "Incoming call"; Call.State.Paused -> "On hold"; Call.State.Pausing -> "Placing on hold…";Call.State.Resuming -> "Resuming…"; Call.State.StreamsRunning -> "Connected"; Call.State.OutgoingRinging -> "Ringing…";Call.State.OutgoingEarlyMedia -> "Connecting…"; else -> "Calling…" }
        if(compact){
            callPanel.setPadding(dp(6),dp(3),dp(6),dp(3))
            callPanel.addView(text("${phone.profileLabel()} · $state · ${phone.callLabel}",15f,ink,true).apply{gravity=Gravity.CENTER;maxLines=1;ellipsize=android.text.TextUtils.TruncateAt.END;setPadding(0,dp(2),0,dp(2))})
            val actions=layout(true)
            if(call.state==Call.State.IncomingReceived){
                actions.addView(iconButton("Decline",R.drawable.ic_hangup,tone=Color.parseColor("#B3263E")){phone.hangup()},spaced(height=48))
                actions.addView(iconButton(if(phone.video.offered(call))"Answer audio" else "Answer",R.drawable.ic_call,tone=Color.parseColor("#16745B")){ensurePermissions();if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)phone.answer()},spaced(height=48))
            }else{
                actions.addView(iconButton(if(phone.muted)"Unmute" else "Mute",if(phone.muted)R.drawable.ic_mic_off else R.drawable.ic_mic,phone.muted){phone.mute()},spaced(height=48))
                actions.addView(iconButton(if(phone.speaker)"Earpiece" else "Speaker",R.drawable.ic_speaker,phone.speaker){phone.speaker()},spaced(height=48))
                actions.addView(iconButton("End call",R.drawable.ic_hangup,tone=Color.parseColor("#B3263E")){phone.hangup()},spaced(height=48))
            }
            callPanel.addView(actions);if(call.state!=Call.State.IncomingReceived)callHold(phone);callExtras(phone);return
        }
        callPanel.addView(text("${phone.profileLabel()} · $state",14f,soft).apply{gravity=Gravity.CENTER})
        callPanel.addView(text(phone.callLabel,28f,ink,true).apply{gravity=Gravity.CENTER})
        val controls=layout(true)
        if(call.state==Call.State.IncomingReceived) {
            controls.addView(iconButton("Decline",R.drawable.ic_hangup,tone=Color.parseColor("#B3263E")){phone.hangup()},spaced(height=82))
            controls.addView(iconButton(if(phone.video.offered(call))"Answer audio" else "Answer",R.drawable.ic_call,tone=Color.parseColor("#16745B")){ensurePermissions();if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)phone.answer()},spaced(height=82))
            callPanel.addView(controls)
        } else {
            controls.addView(iconButton(if(phone.muted)"Unmute" else "Mute",if(phone.muted)R.drawable.ic_mic_off else R.drawable.ic_mic,phone.muted){phone.mute()},spaced())
            controls.addView(iconButton(if(phone.speaker)"Earpiece" else "Speaker",R.drawable.ic_speaker,phone.speaker){phone.speaker()},spaced())
            callPanel.addView(controls)
            callHold(phone)
            callPanel.addView(iconButton("End call",R.drawable.ic_hangup,tone=Color.parseColor("#B3263E")){phone.hangup()},LinearLayout.LayoutParams(-1,dp(70)))
        }
        callExtras(phone)
    }
    private fun callHold(phone:PhoneService) {
        val held=phone.conferenceOnHold || phone.call?.state==Call.State.Paused
        val enabled=phone.canHold()
        callPanel.addView(button(if(held)"Resume Call" else "Call Hold"){phone.hold()}.apply {
            isEnabled=enabled;alpha=if(enabled)1f else .5f
            backgroundTintList=ColorStateList.valueOf(if(held)Color.parseColor("#16745B") else if(dark)Color.parseColor("#38495B") else Color.parseColor("#DCE9F5"))
            setTextColor(if(held)Color.WHITE else ink)
            setCompoundDrawablesRelativeWithIntrinsicBounds(if(held)R.drawable.ic_play else R.drawable.ic_hold,0,0,0)
            compoundDrawableTintList=ColorStateList.valueOf(if(held)Color.WHITE else ink)
            contentDescription=if(held)"Resume Call. Continue speaking with your caller." else "Call Hold. Your caller will hear music until you resume."
        },LinearLayout.LayoutParams(-1,dp(48)))
    }
    private fun callExtras(phone:PhoneService){
        val waiting=phone.waitingCall
        if(waiting!=null && waiting.nativePointer!=phone.call?.nativePointer){
            val row=layout(true)
            row.addView(text("Waiting: ${waiting.remoteAddress.username}",13f,ink,true),LinearLayout.LayoutParams(0,-2,1f))
            row.addView(button("Answer"){phone.answer(waiting)});row.addView(button("Decline"){phone.hangup(waiting)})
            callPanel.addView(row)
        }
        val row=layout(true)
        val joining=phone.conference!=null && !phone.conference!!.isIn
        row.addView(button(if(joining)"Join call audio" else if(phone.conference!=null || phone.conferenceOnHold)"Participants" else "Call options"){if(joining)phone.retryConferenceAudio()else callOptions(phone)},LinearLayout.LayoutParams(0,dp(48),1f))
        if(phone.calls.size==1 && phone.conference==null){
            val current=phone.call
            val incoming=current?.state==Call.State.IncomingReceived
            if(!incoming || phone.video.offered(current))row.addView(button(if(incoming)"Answer video" else if(phone.video.requestPending)"Video requested · View" else if(phone.video.enabled)"Open video" else "Video call"){openVideo(incoming=if(incoming)current else null)},LinearLayout.LayoutParams(0,dp(48),1f))
        }
        if(phone.consultation!=null){
            row.addView(button("Transfer now"){phone.completeTransfer()},LinearLayout.LayoutParams(0,dp(48),1f))
            row.addView(button("Cancel"){phone.cancelConsultation()},LinearLayout.LayoutParams(0,dp(48),1f))
        }else if(phone.calls.size==2 && waiting==null && phone.conference==null && !phone.conferenceOnHold){
            row.addView(button("Switch"){phone.calls.firstOrNull{it.nativePointer!=phone.call?.nativePointer}?.let{phone.switchCall(it)}},LinearLayout.LayoutParams(0,dp(48),1f))
            row.addView(button("Merge"){phone.merge()},LinearLayout.LayoutParams(0,dp(48),1f))
        }
        callPanel.addView(row)
    }
    private fun callOptions(phone:PhoneService){
        if(phone.conference!=null || phone.conferenceOnHold){
            val rows=layout().apply{setPadding(dp(16),0,dp(16),0)}
            for(person in phone.calls){
                rows.addView(text(person.remoteAddress.username ?: "Participant",18f,ink,true))
                val actions=layout(true)
                actions.addView(button(if(person.speakerMuted)"Unmute sound" else "Mute sound"){phone.muteParticipant(person)},LinearLayout.LayoutParams(0,dp(48),1f))
                actions.addView(button("Remove"){phone.hangup(person)},LinearLayout.LayoutParams(0,dp(48),1f));rows.addView(actions)
            }
            AlertDialog.Builder(this).setTitle("Participants").setView(rows).setNegativeButton("Close",null).setPositiveButton("End all calls"){_,_->phone.calls.toList().forEach{phone.hangup(it)}}.show();return
        }
        val labels=if(phone.calls.size==1)arrayOf("Transfer", "Add a call", "Audio device")else arrayOf("Choose conversation", "Merge calls", "Audio device")
        AlertDialog.Builder(this).setTitle("Call options").setItems(labels){_,i->when(i){
            0->if(phone.calls.size==1)destinationDialog("Transfer",true){number,talk->if(talk)phone.consult(number)else phone.blindTransfer(number)}else AlertDialog.Builder(this).setTitle("Choose conversation").setItems(phone.calls.map{it.remoteAddress.username ?: "Caller"}.toTypedArray()){_,j->try{phone.switchCall(phone.calls[j])}catch(e:Exception){message(e.message ?: "Please try again")}}.show()
            1->if(phone.calls.size==1)destinationDialog("Add a call",false){number,_->phone.dial(number,true)}else try{phone.merge()}catch(e:Exception){message(e.message ?: "Please try again")}
            else->audioDevices()
        }}.show()
    }
    private fun destinationDialog(title:String,transfer:Boolean,accept:(String,Boolean)->Unit){
        val phone=PhoneService.instance;val original=phone?.call ?: run{message("That call has ended");return}
        val callId=phone.incomingId(original);val profileId=phone.profileId(original) ?: return
        fun sameCall()=PhoneService.instance?.call?.let{PhoneService.instance?.incomingId(it)==callId && PhoneService.instance?.profileId(it)==profileId}==true
        val rows=layout().apply{setPadding(dp(20),0,dp(20),0)};val number=field("Number or extension",type=InputType.TYPE_CLASS_PHONE)
        rows.addView(number)
        val talk=CheckBox(this).apply{text="Talk to the person first";setTextColor(ink);isChecked=true}
        if(transfer)rows.addView(talk)
        rows.addView(button("Choose from Contacts"){
            if(!sameCall())message("Choose this action again from the current call") else async({api().json("directory")},{response->
                if(sameCall()){val contacts=response.getJSONArray("contacts")
                    AlertDialog.Builder(this).setTitle("Contacts").setItems(Array(contacts.length()){i->val row=contacts.getJSONObject(i);"${row.getString("name")} · ${row.getString("number")}"}){_,i->if(sameCall())number.setText(contacts.getJSONObject(i).getString("number")) else message("That call has changed")}.setNegativeButton("Cancel",null).show()
                }
            },scope=profileId,acceptProfileChange=true)
        })
        val dialog=AlertDialog.Builder(this).setTitle(title).setView(rows).setNegativeButton("Cancel",null).setPositiveButton(if(transfer)"Continue" else "Call",null).create()
        dialog.setOnShowListener{dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener{try{check(sameCall()){"Choose this action again from the current call"};accept(Enrollment.number(number.text.toString()),transfer && talk.isChecked);dialog.dismiss()}catch(e:Exception){number.error=e.message}}};dialog.show()
    }
    private fun availability(){
        availabilityDialog?.dismiss()
        async({api().json("availability")},{response->
            val contents=layout().apply{setPadding(dp(20),0,dp(20),0)}
            contents.addView(text("Status: ${response.getString("status")}",18f,ink,true))
            if(!response.isNull("temporary_until"))contents.addView(text("Until ${friendlyDate(response.getString("temporary_until"))}",14f,soft))
            val statuses=response.getJSONArray("statuses");val statusChoice=Spinner(this).apply{adapter=ArrayAdapter(this@MainActivity,android.R.layout.simple_spinner_dropdown_item,Array(statuses.length()){statuses.getString(it)});setSelection((0 until statuses.length()).firstOrNull{statuses.getString(it)==response.getString("status")} ?: 0)}
            val duration=Spinner(this).apply{adapter=ArrayAdapter(this@MainActivity,android.R.layout.simple_spinner_dropdown_item,arrayOf("Until I change it","15 minutes","30 minutes","1 hour","2 hours","4 hours","8 hours"))}
            statusChoice.contentDescription="My status";duration.contentDescription="For how long"
            contents.addView(text("My status",14f,soft));contents.addView(statusChoice)
            contents.addView(text("For how long",14f,soft));contents.addView(duration)
            contents.addView(button("Save status"){async({api().json("set_status",JSONObject().put("status",statusChoice.selectedItem.toString()).put("minutes",listOf(0,15,30,60,120,240,480)[duration.selectedItemPosition]))},{message("Status updated");availability()})})
            contents.addView(text("Queues",20f,ink,true))
            val queues=response.getJSONArray("queues")
            if(queues.length()==0)contents.addView(text("No queues assigned to you",14f,soft))
            for(i in 0 until queues.length()){
                val queue=queues.getJSONObject(i)
                fun queueText(q:JSONObject)=q.getString("name")+" · "+q.optString("receiving_reason").ifBlank{if(q.optBoolean("receiving"))"Receiving calls" else "Not receiving calls"}
                val toggle=CheckBox(this).apply{text=queueText(queue);setTextColor(ink);isChecked=queue.getBoolean("joined")}
                toggle.setOnCheckedChangeListener{_,joined->if(toggle.isEnabled){toggle.isEnabled=false;async({api().json("queue_status",JSONObject().put("number",queue.getString("number")).put("joined",joined))},{updated->toggle.isEnabled=true;val q=updated.getJSONArray("queues");for(j in 0 until q.length())if(q.getJSONObject(j).getString("number")==queue.getString("number"))toggle.text=queueText(q.getJSONObject(j))},{toggle.isChecked=!joined;toggle.isEnabled=true})}}
                contents.addView(toggle)
            }
            val scroll=ScrollView(this).apply{addView(contents)}
            availabilityDialog=AlertDialog.Builder(this).setTitle("Status and queues").setView(scroll).setNegativeButton("Close",null).setNeutralButton("Refresh"){_,_->availability()}.show()
        })
    }
    private fun friendlyDate(value:String):String=try{val date=java.time.OffsetDateTime.parse(value.replace(" ","T")).toInstant();java.time.format.DateTimeFormatter.ofLocalizedDateTime(java.time.format.FormatStyle.MEDIUM,java.time.format.FormatStyle.SHORT).withZone(java.time.ZoneId.systemDefault()).format(date)}catch(_:Exception){value}
    private fun keypad() {
        if(!compact)body.addView(text("Keypad",22f,ink,true))
        if(PhoneService.instance?.calls?.isEmpty()!=false)body.addView(button("Calling from ${store.read()?.let{ProfileRules.label(it)} ?: "your account"}"){accounts()})
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
                    setOnClickListener{if(preferences.keypadHaptics)performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);if(PhoneService.instance?.call!=null)PhoneService.instance?.dtmf(digit[0]) else number.append(digit)}
                    if(digit=="0")setOnLongClickListener{if(PhoneService.instance?.call==null)number.append("+");true}
                };line.addView(key,spaced(height=if(compact)48 else 62))
            };body.addView(line)
        }
        val actions=keypadDock
        actions.addView(iconButton("Call",R.drawable.ic_call,tone=Color.parseColor("#16745B")){dial(number.text.toString())},spaced(3f,if(compact)48 else 72))
        actions.addView(iconButton("Video",R.drawable.ic_video){startVideo(number.text.toString())},spaced(2f,if(compact)48 else 72))
        actions.addView(iconButton("Delete digit",R.drawable.ic_backspace){if(number.text.isNotEmpty())number.text.delete(number.text.length-1,number.text.length)},spaced(1.3f,if(compact)48 else 72))
        if(!compact)body.addView(text("During a call, use the keypad for menu choices.",13f,soft))
    }
    private fun api():PhoneApi { val a=store.read(requestProfile.get()) ?: error("Connect your phone first"); return PhoneApi.profile(a) }
    private fun <T> async(work:()->T, success:(T)->Unit, failure:()->Unit={},scope:String?=store.selectedId(),acceptProfileChange:Boolean=false,markRevoked:Boolean=true) {
        worker.execute{
            requestProfile.set(scope)
            try{val result=work();runOnUiThread{if(!isFinishing && !isDestroyed && (acceptProfileChange || scope==store.selectedId()))success(result)}}
            catch(e:Exception){runOnUiThread{if(!isFinishing && !isDestroyed){
                if(markRevoked && e is ApiError && e.status==401 && scope!=null && !acceptProfileChange){PushConnection.unregister(this,scope);store.update(scope){it.put("needs_login",true)};PhoneService.instance?.syncProfiles()}
                if(acceptProfileChange || scope==store.selectedId()){failure();message(if(e is ApiError || e is IllegalArgumentException || e is IllegalStateException)e.message ?: "Please try again" else "Could not reach your PBX. Check your connection and try again.");if(e is ApiError && e.status==401)draw()}
            }}}finally{requestProfile.remove()}
        }
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
    private fun openVideo(number:String?=null,incoming:Call?=null){
        val phone=PhoneService.instance
        fun show(){
            val intent=Intent(this,VideoCallActivity::class.java)
            if(number!=null)intent.putExtra("number",number).putExtra("start_video",true)
            if(incoming!=null)intent.putExtra("incoming_id",phone?.incomingId(incoming))
            startActivity(intent)
        }
        val current=phone?.call
        if(number==null && incoming==null && current!=null && !phone.video.enabled && !phone.video.requestPending){
            val peer=current.remoteAddress.username
            async({api().json("directory")},{response->
                val rows=response.getJSONArray("contacts")
                if(phone.call?.nativePointer!=current.nativePointer)return@async
                if((0 until rows.length()).any{rows.getJSONObject(it).optString("id")=="extension:$peer"})show()
                else message("Video calls are available for colleagues listed in Contacts.")
            })
        }else show()
    }
    private fun startVideo(raw:String){
        try{PhoneService.instance?.video?.requireServerVideo() ?: error("Open Settings and choose Check connection first.")}catch(e:Exception){message(e.message ?: "Video is not available yet.");return}
        val number=try{Enrollment.number(raw)}catch(e:Exception){message("Enter a colleague's extension for a video call.");return}
        if(number==store.read()?.optJSONObject("account")?.optString("extension")){message("Choose a colleague's extension for a video call.");return}
        async({api().json("directory")},{response->
            val contacts=response.getJSONArray("contacts")
            if((0 until contacts.length()).any{val row=contacts.getJSONObject(it);row.optString("id")=="extension:$number" && row.optString("number")==number})openVideo(number)
            else message("Video calls are available for colleagues listed in Contacts.")
        })
    }
    private fun item(title:String,subtitle:String,action:()->Unit) {
        val row=layout().apply { background=rounded(card); setPadding(dp(16),dp(12),dp(16),dp(12)); isClickable=true; isFocusable=true; contentDescription="$title, $subtitle"; setOnClickListener{action()} }
        row.addView(text(title,18f,ink,true)); row.addView(text(subtitle,14f,soft)); body.addView(row,LinearLayout.LayoutParams(-1,-2).apply{bottomMargin=dp(10)})
    }
    private fun contacts() {
        body.addView(text("Contacts",28f,ink,true)); body.addView(text("Your company directory",14f,soft))
        fetch("directory","contacts") { list ->
            val ordered=(0 until list.length()).map{list.getJSONObject(it)}.sortedWith(if(preferences.contactSort=="Extension")compareBy<JSONObject>{it.optString("number").toLongOrNull() ?: Long.MAX_VALUE}.thenBy{it.optString("number")}.thenBy{it.optString("name").lowercase(java.util.Locale.ROOT)}else compareBy<JSONObject>{it.optString("name").lowercase(java.util.Locale.ROOT)}.thenBy{it.optString("number")})
            val search=field("Search people or numbers"); body.addView(search); val container=layout(); body.addView(container)
            fun filter(value:String) { container.removeAllViews(); for(row in ordered) { val name=row.optString("name"); val number=row.optString("number"); if(!"$name $number".contains(value,true))continue
                val contactRow=layout(true)
                contactRow.addView(button("$name\n$number${row.optString("status").takeIf{it.isNotBlank()}?.let{" · $it"} ?: ""}"){dial(number)}.apply{gravity=Gravity.START; minHeight=dp(64)},LinearLayout.LayoutParams(0,-2,1f))
                if(row.optString("id")=="extension:$number")contactRow.addView(button("Video"){startVideo(number)}.apply{contentDescription="Video call $name"},LinearLayout.LayoutParams(dp(82),dp(64)))
                container.addView(contactRow)
            } }
            search.addTextChangedListener(object:android.text.TextWatcher{override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int){}; override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int){filter(s.toString())};override fun afterTextChanged(s:android.text.Editable?){} });filter("")
        }
    }
    private fun recents() {
        body.addView(text("Recents",28f,ink,true)); PhoneService.instance?.flushPending()
        body.addView(button("Refresh"){draw()})
        fetch("calls","calls") { list -> for(i in 0 until list.length()) { val row=list.getJSONObject(i); val number=row.optString("number"); val name=row.optString("name").ifBlank{number}; item(name,"${row.optString("direction")} · ${friendlyDate(row.optString("started_at"))} · ${row.optInt("duration")}s"){dial(number)} } }
    }
    private fun voicemail() {
        body.addView(text("Voicemail",28f,ink,true)); body.addView(button("Refresh"){stopPlayback();draw()})
        fetch("voicemail","messages") { list -> for(i in 0 until list.length()) {
            val row=list.getJSONObject(i); val id=row.getString("id"); val title=row.optString("caller_name").ifBlank{row.optString("caller_number","Unknown caller")}
            val cardView=layout().apply { background=rounded(card); setPadding(dp(14),dp(10),dp(14),dp(10)) }
            cardView.addView(text((if(row.optBoolean("read"))"" else "New · ")+title,18f,ink,true));cardView.addView(text("${friendlyDate(row.optString("created_at"))} · ${row.optInt("duration")}s",13f,soft))
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
        if(store.read()==null)return
        if(updateGated){urgentUpdateBypass=true;updates.cancelInstall()}
        settingsReturnSection=section.takeIf{it in PhonePreferenceRules.pages} ?: "Keypad";section="Settings";stopPlayback();draw()
    }
    private fun settingChoice(title:String,values:List<String>,current:String,save:(String)->Unit) {
        AlertDialog.Builder(this).setTitle(title).setSingleChoiceItems(values.toTypedArray(),values.indexOf(current)){dialog,index->save(values[index]);dialog.dismiss();if(title=="Choose theme")recreate()else draw()}.setNegativeButton("Cancel",null).show()
    }
    private val ringtonePicker=registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if(result.resultCode==RESULT_OK)try {
            val uri=if(Build.VERSION.SDK_INT>=33)result.data?.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI,Uri::class.java) else @Suppress("DEPRECATION") result.data?.getParcelableExtra<Uri>(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
            require(uri!=null) { "Choose a ringtone. Silent sounds are not supported." }
            preferences.setRingtone(uri);PhoneService.instance?.applyPersonalPreferences();draw()
            message(if(PhoneService.instance?.call==null)"Ringtone saved" else "Ringtone saved for your next incoming call")
        }catch(e:Exception){message(e.message ?: "That ringtone is unavailable. Choose another sound.")}
    }
    private fun pickRingtone() {
        val intent=Intent(RingtoneManager.ACTION_RINGTONE_PICKER).putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE,RingtoneManager.TYPE_RINGTONE)
            .putExtra(RingtoneManager.EXTRA_RINGTONE_TITLE,"Choose ringtone").putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT,false)
            .putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT,true).putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI,preferences.ringtoneUri() ?: Settings.System.DEFAULT_RINGTONE_URI)
        try{ringtonePicker.launch(intent)}catch(_:Exception){message("This phone has no ringtone picker. The system ringtone remains selected.")}
    }
    private fun androidSettings(intent:Intent) { try{startActivity(intent)}catch(_:Exception){message("This setting is not available on this device.")} }
    private fun settingsPage() {
        val account=store.read() ?: return
        val identity=account.getJSONObject("account")
        body.addView(text("Settings",28f,ink,true));body.addView(text("Make this phone your own",14f,soft))
        body.addView(text("Your phone",20f,ink,true))
        item("Accounts", "${store.profiles().size} saved · Choose, add, edit or remove an account"){accounts()}
        if(account.optJSONArray("features")?.let{list->(0 until list.length()).any{list.optString(it)=="app_password"}}==true)item(if(!identity.optBoolean("app_password_set",true))"Create app password" else "Change app password","Manage the selected account’s app password"){changeAppPassword()}
        body.addView(text("${identity.optString("display_name")} · Extension ${identity.optString("extension")}\n${account.getString("server")}\nVersion ${BuildConfig.VERSION_NAME}",14f,soft))
        item("Choose theme",preferences.theme){settingChoice("Choose theme",PhonePreferenceRules.themes,preferences.theme){preferences.theme=it}}
        item("Ringtone",preferences.ringtoneName()){pickRingtone()}
        item("Keypad vibration",if(preferences.keypadHaptics)"On · Uses your phone’s touch feedback" else "Off"){preferences.keypadHaptics=!preferences.keypadHaptics;draw()}
        item("Start page",preferences.startupPage){settingChoice("Start page",PhonePreferenceRules.pages,preferences.startupPage){preferences.startupPage=it}}
        item("Sort contacts",preferences.contactSort){settingChoice("Sort contacts",PhonePreferenceRules.sorting,preferences.contactSort){preferences.contactSort=it}}
        body.addView(text("Calling",20f,ink,true))
        item("Status and queues","Choose availability, temporary status and your queues"){availability()}
        item("Audio device","Choose from the connected speaker, earpiece or headset"){audioDevices()}
        item("Check connection","Check your PBX and incoming wake-up connection"){connectionCheck()}
        body.addView(text("Your ringtone follows Android’s volume and Do Not Disturb settings. During a call, Call Hold plays music to the caller until you press Resume Call.",14f,soft))
        body.addView(text("Android permissions",20f,ink,true))
        val mic=checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED
        item("Microphone access",if(mic)"Allowed · Ready for calls" else "Allow access to make and answer calls"){if(!mic)ensurePermissions()else androidSettings(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:$packageName")))}
        val manager=getSystemService(NotificationManager::class.java)
        val alerts=manager.areNotificationsEnabled() && (manager.getNotificationChannel("calls")?.importance ?: NotificationManager.IMPORTANCE_HIGH)>NotificationManager.IMPORTANCE_NONE
        item("Incoming call alerts",if(alerts)"Allowed · Keep alerts enabled for incoming calls" else "Blocked · Enable alerts so you can answer incoming calls"){
            if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)permissions.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
            else androidSettings(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,packageName).putExtra(Settings.EXTRA_CHANNEL_ID,"calls"))
        }
        val unrestricted=getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        item("Battery optimization",if(unrestricted)"Unrestricted · Background calls are allowed" else "Allow background use for reliable incoming calls"){androidSettings(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))}
        body.addView(text("Keep the connection notification running. Reopen OpenWebPBX Free Phone after restarting your phone or stopping the app. Incoming wake-up depends on your administrator’s setup.",14f,soft))
        body.addView(text("Updates and support",20f,ink,true))
        item("App updates","Check for updates · Your administrator manages update requirements"){updateDialog()}
        policyLinks()
        item("Privacy and support","Privacy, help and deleting your account"){privacy()}
        item("Source and licenses","Open source under AGPL-3.0-or-later"){licenses()}
        item("Reset personal settings","Restore theme, ringtone and display choices; stay connected"){
            AlertDialog.Builder(this).setTitle("Reset personal settings?").setMessage("Your account, calls and administrator’s update rules remain saved.").setNegativeButton("Cancel",null).setPositiveButton("Reset"){_,_->preferences.reset();PhoneService.instance?.applyPersonalPreferences();recreate()}.show()
        }
        body.addView(button("Remove this account"){disconnect()}.apply{isEnabled=PhoneService.instance?.call==null})
    }
    private fun connectionCheck() {
        async({api().json("bootstrap")},{
            val phone=PhoneService.instance
            val pushDetail=when(store.read()?.optString("push_state")){"ready"->"Incoming wake-up is connected.";"connecting"->"Incoming wake-up is still connecting.";"unavailable"->"Incoming wake-up is unavailable on this phone. Keep the connection notification running and ask your administrator to check setup.";else->"Incoming wake-up is not configured. Keep the connection notification running."}
            val detail=when {checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED -> "Your PBX is reachable. Allow microphone access to make calls."
                phone?.status=="Ready for calls" -> "Your PBX is reachable and your phone is connected. If a number will not connect, ask your administrator to check that number’s calling rule and provider."
                else -> "Your PBX is reachable. Reconnecting the phone now…"}
            if(phone?.call==null && phone?.status!="Ready for calls") {if(phone==null)ensurePermissions()else phone.reconnect()}
            AlertDialog.Builder(this).setTitle("Connection check").setMessage("$detail\n\n$pushDetail").setPositiveButton("Done",null).show()
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
    private val privacySummary = "Your organisation’s PBX receives your device name, connection details and call history. During calls it carries your microphone audio, including while the app is in the background. Your administrator controls recordings and retention. The camera scans your connection QR code and, only when you choose video, shares live pictures through your PBX with the other caller. Leaving the video screen or locking your phone stops the camera; audio can continue. If your administrator enables incoming wake-up, Google Play Services delivers encrypted alerts and an optional Cloudflare relay forwards them. Call audio and phone passwords are not sent through that notification channel."
    private fun policyLinks(){
        body.addView(button("Terms of use"){openPublicPage("terms")})
        body.addView(button("Privacy policy"){openPublicPage("privacy")})
        body.addView(button("Delete account / request data deletion"){openPublicPage("delete")})
    }
    private fun privacy() {
        AlertDialog.Builder(this).setTitle("Privacy and support").setMessage("$privacySummary\n\nNo advertising or advertising tracking. Settings → Disconnect removes this phone’s connection and local account data. To request deletion of your PBX account or server records, contact your administrator or follow the data removal instructions.")
            .setPositiveButton("Privacy policy") { _,_ -> openPublicPage("privacy") }
            .setNeutralButton("Remove my data") { _,_ -> openPublicPage("delete") }
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
        if(store.read()?.let{TenantConnection.ready(it)}!=true)return
        if(bootstrapped)return;bootstrapped=true
        val profileId=store.selectedId() ?: return
        async({api().json("bootstrap")},{ response ->
            store.update(profileId) { saved ->
            response.optJSONObject("push")?.let{saved.put("push",it)}
            saved.put("features",response.optJSONArray("features") ?: org.json.JSONArray())
            response.optJSONObject("account")?.let{saved.put("account",it)}
            response.optJSONObject("sip")?.let{fresh->val old=saved.getJSONObject("sip");for(key in fresh.keys())if(key!="password" || fresh.optString(key).isNotBlank())old.put(key,fresh.get(key))}
            };store.read(profileId)?.let{PushConnection.configure(this,it)};updatePhone()
        })
    }
    private fun audioDevices() {
        if(Build.VERSION.SDK_INT>=31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)!=PackageManager.PERMISSION_GRANTED) { permissions.launch(arrayOf(Manifest.permission.BLUETOOTH_CONNECT)); return }
        val devices=PhoneService.instance?.audioDevices() ?: emptyList()
        AlertDialog.Builder(this).setTitle("Audio device").setItems(devices.map{it.deviceName}.toTypedArray()){_,index->PhoneService.instance?.audioDevice(devices[index])}.setNegativeButton("Cancel",null).show()
    }
    private fun disconnect(){store.selectedId()?.let{removeProfile(it)}}
    private fun removeProfile(id:String){
        requireProfileIdle();val profile=store.read(id) ?: return
        if(!TenantConnection.ready(profile)){offerLocalRemoval(id);return}
        AlertDialog.Builder(this).setTitle("Remove this phone account?").setMessage("Remove ${ProfileRules.label(profile)} from this phone. Other saved accounts stay connected. This does not delete your PBX account or server records. You can sign in again or use a new setup code.")
            .setNegativeButton("Cancel",null).setPositiveButton("Remove"){_,_->
                try{
                    requireProfileIdle();val phone=PhoneService.instance;phone?.beginProfileChange(id)
                    async({
                        try{
                            try{PhoneApi.profile(profile).json("revoke",JSONObject())}catch(e:ApiError){if(e.status !in listOf(401,403))throw e}
                            PushConnection.unregister(this,id);store.remove(id);true
                        }catch(_:java.io.IOException){false
                        }finally{android.os.Handler(android.os.Looper.getMainLooper()).post{phone?.endProfileChange(id)}}
                    },{removed->
                        if(removed)afterProfileRemoved() else offerLocalRemoval(id)
                    },scope=id,acceptProfileChange=true)
                }catch(e:Exception){message(e.message ?: "Could not remove this account")}
            }.show()
    }
    private fun afterProfileRemoved(){
        if(store.profiles().isEmpty() && PhoneService.instance?.calls?.isEmpty()!=false)stopService(Intent(this,PhoneService::class.java))
        stopPlayback();bootstrapped=false;draw();updates.check()
    }
    private fun offerLocalRemoval(id:String){
        val profile=store.read(id) ?: return
        AlertDialog.Builder(this).setTitle(if(TenantConnection.ready(profile))"Could not reach this account's server" else "Remove this unconfirmed account?")
            .setMessage("Remove ${ProfileRules.label(profile)} only from this phone? Its saved connection and local call history will be deleted. Other accounts stay connected.\n\nYour PBX may still list this device. Ask your administrator to revoke it when the server is available. This does not delete your PBX account or server records.")
            .setNegativeButton("Keep account",null).setPositiveButton("Remove from this phone anyway"){_,_->
                try{
                    requireProfileIdle();val phone=PhoneService.instance;phone?.beginProfileChange(id)
                    async({try{PushConnection.unregister(this,id);store.remove(id)}finally{android.os.Handler(android.os.Looper.getMainLooper()).post{phone?.endProfileChange(id)}}},{afterProfileRemoved()},scope=id,acceptProfileChange=true)
                }catch(e:Exception){message(e.message ?: "Could not remove this account")}
            }.show()
    }
}
