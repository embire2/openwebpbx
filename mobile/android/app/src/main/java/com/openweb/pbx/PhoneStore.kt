/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import org.json.JSONArray
import java.util.UUID
import java.net.URI
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object Enrollment {
    fun server(value: String): String {
        val uri = URI(value.trim())
        val host=uri.host?.lowercase(java.util.Locale.ROOT).orEmpty()
        require(uri.scheme.equals("https",true) && host.endsWith(".openwebpbx.com") &&
            host.removeSuffix(".openwebpbx.com").matches(Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")) &&
            !host.startsWith("xn--") && uri.userInfo == null && uri.query == null && uri.fragment == null &&
            (uri.path.isNullOrEmpty() || uri.path == "/") && uri.port in listOf(-1,443)) {
            "Enter your tenant address, for example https://company.openwebpbx.com. Other domains are not supported."
        }
        return "https://$host"
    }
    fun tenant(value: String): String {
        val raw=value.trim()
        val host=if(raw.matches(Regex("[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]|[a-zA-Z0-9]")))"$raw.openwebpbx.com" else raw
        return server(if(host.contains("://"))host else "https://$host")
    }
    fun code(value: String): String {
        val code = value.trim()
        require(code.length in 16..256 && code.matches(Regex("[A-Za-z0-9_-]+"))) { "The connection code is not valid. Ask your administrator for a new QR code." }
        return code
    }
    fun number(value: String): String {
        val number = value.replace(" ", "").replace("-", "").replace("(", "").replace(")", "")
        require(number.matches(Regex("[+*#0-9]{1,32}"))) { "Enter a phone number or extension" }
        return number
    }
}

/** Only AES-GCM ciphertext lives in SharedPreferences; keys remain in Android Keystore. */
class PhoneStore(context: Context) {
    companion object { private val accountLock = Any() }
    private val prefs = context.getSharedPreferences("private_account", Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("openweb-account-v1", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("openweb-account-v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun envelope(): JSONObject {
        val raw = prefs.getString("sealed", null) ?: return JSONObject().put("schema",2).put("profiles",JSONArray())
        val bytes = Base64.decode(raw, Base64.NO_WRAP)
        require(bytes.size>28) { "This phone's saved accounts could not be opened" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        val saved=JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
        if(saved.optInt("schema")==2 && saved.optJSONArray("profiles")!=null)return saved
        // Commit the migration atomically with the existing Keystore key. The legacy
        // token, SIP secret, pending history and push state are copied without edits.
        require(saved.optJSONObject("sip")!=null && saved.optJSONObject("account")!=null)
        val id=UUID.randomUUID().toString();saved.put("profile_id",id)
        return JSONObject().put("schema",2).put("selected",id).put("profiles",JSONArray().put(saved)).also{seal(it)}
    }
    private fun seal(value:JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val bytes = cipher.iv + cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString("sealed", Base64.encodeToString(bytes, Base64.NO_WRAP)).commit()) { "Could not save this phone securely" }
    }
    private fun rows(value:JSONObject):List<JSONObject> = value.getJSONArray("profiles").let{list->(0 until list.length()).map{list.getJSONObject(it)}}
    fun profiles():List<JSONObject> = synchronized(accountLock) { rows(envelope()) }
    fun selectedId():String? = synchronized(accountLock) { val e=envelope();e.optString("selected").takeIf{id->rows(e).any{it.optString("profile_id")==id}} }
    fun read(profileId:String?=null):JSONObject? = synchronized(accountLock) {
        val e=envelope();val id=profileId ?: e.optString("selected");rows(e).firstOrNull{it.optString("profile_id")==id}
    }
    fun byDevice(deviceId:String):JSONObject? = profiles().filter{it.optString("device_id")==deviceId}.singleOrNull()
    fun add(value:JSONObject,select:Boolean=true):String = synchronized(accountLock) {
        val e=envelope();val existing=rows(e)
        require(existing.size<ProfileRules.MAX_PROFILES){"You can save up to ${ProfileRules.MAX_PROFILES} accounts on this phone"}
        require(existing.none{ProfileRules.sameAccount(it,value)}){"This account is already saved. Open Accounts to edit or reconnect it."}
        val id=UUID.randomUUID().toString();value.put("profile_id",id);e.getJSONArray("profiles").put(value)
        if(select || existing.isEmpty())e.put("selected",id)
        seal(e);id
    }
    /** Compatibility for existing account writes; never replaces another saved profile. */
    fun save(value: JSONObject) = synchronized(accountLock) {
        val e=envelope();val entries=rows(e);val id=value.optString("profile_id").ifBlank{e.optString("selected")}
        val target=entries.firstOrNull{it.optString("profile_id")==id}
        if(target==null){add(value);Unit}else {
            value.put("profile_id",id);e.put("profiles",JSONArray().apply{entries.forEach{put(if(it.optString("profile_id")==id)value else it)}});seal(e)
        }
    }
    fun select(profileId:String) = synchronized(accountLock) {
        val e=envelope();require(rows(e).any{it.optString("profile_id")==profileId}){"Choose a saved account"};e.put("selected",profileId);seal(e)
    }
    fun remove(profileId:String) = synchronized(accountLock) {
        val e=envelope();val kept=rows(e).filter{it.optString("profile_id")!=profileId};e.put("profiles",JSONArray().apply{kept.forEach{put(it)}})
        if(e.optString("selected")==profileId)e.put("selected",kept.firstOrNull()?.optString("profile_id") ?: "")
        seal(e)
    }
    fun clear() = synchronized(accountLock) { prefs.edit().clear().commit(); Unit }
    fun update(profileId:String?=null,change: (JSONObject) -> Unit): JSONObject? = synchronized(accountLock) {
        read(profileId)?.also { change(it); save(it) }
    }
}
