/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.content.Context
import android.media.RingtoneManager
import android.net.Uri
import java.net.URI
import java.net.URLDecoder

/** Personal presentation choices only. Account, connection and update trust use separate stores. */
object PhonePreferenceRules {
    val themes = listOf("System", "Light", "Dark")
    val pages = listOf("Keypad", "Contacts", "Recents", "Voicemail")
    val sorting = listOf("Name", "Extension")
    fun choice(value:String?, allowed:List<String>) = value?.takeIf { it in allowed } ?: allowed.first()
    fun ringtone(value:String):Boolean = try {
        val uri=URI(value)
        value.length<=2048 && uri.scheme=="content" && uri.rawAuthority in listOf("media", "settings") &&
            uri.userInfo==null && (uri.rawQuery==null || uri.rawAuthority=="media" && canonicalSound(uri.rawQuery)) &&
            uri.rawFragment==null && !uri.rawPath.isNullOrBlank()
    } catch(_:Exception) { false }
    /** Android's picker includes stable title/canonical metadata on MediaStore sounds. */
    private fun canonicalSound(query:String):Boolean {
        val pairs=query.split('&').map { part ->
            val split=part.indexOf('=');require(split>0)
            URLDecoder.decode(part.substring(0,split),"UTF-8") to URLDecoder.decode(part.substring(split+1),"UTF-8")
        }
        val fields=pairs.toMap()
        return pairs.size in 1..2 && fields.size==pairs.size && fields.keys.all{it in listOf("canonical","title")} &&
            fields["canonical"]=="1" && fields["title"]?.let{it.isNotBlank() && it.length<=512 && it.none{c->c.isISOControl()}}!=false
    }
    fun dark(theme:String, systemDark:Boolean) = when(choice(theme,themes)) { "Dark"->true; "Light"->false; else->systemDark }
}

class PhonePreferences(private val context:Context) {
    private val prefs=context.getSharedPreferences("phone_preferences",Context.MODE_PRIVATE)
    var theme:String
        get()=PhonePreferenceRules.choice(prefs.getString("theme",null),PhonePreferenceRules.themes)
        set(value){require(value in PhonePreferenceRules.themes);save("theme",value)}
    var startupPage:String
        get()=PhonePreferenceRules.choice(prefs.getString("startup_page",null),PhonePreferenceRules.pages)
        set(value){require(value in PhonePreferenceRules.pages);save("startup_page",value)}
    var contactSort:String
        get()=PhonePreferenceRules.choice(prefs.getString("contact_sort",null),PhonePreferenceRules.sorting)
        set(value){require(value in PhonePreferenceRules.sorting);save("contact_sort",value)}
    var keypadHaptics:Boolean
        get()=prefs.getBoolean("keypad_haptics",true)
        set(value){check(prefs.edit().putBoolean("keypad_haptics",value).commit())}
    private fun save(key:String,value:String){check(prefs.edit().putString(key,value).commit())}
    /** Missing/deleted/revoked sounds always fall back to Android's default ringtone. */
    fun ringtoneUri():Uri? {
        val saved=prefs.getString("ringtone",null) ?: return null
        return if(PhonePreferenceRules.ringtone(saved) && readable(Uri.parse(saved)))Uri.parse(saved) else null
    }
    private fun readable(uri:Uri):Boolean = try {
        context.contentResolver.openAssetFileDescriptor(uri,"r")?.use { it.length!=0L && it.length<=32L*1024*1024 }==true
    }catch(_:Exception){false}
    fun setRingtone(uri:Uri?) {
        if(uri==null || RingtoneManager.isDefault(uri)){check(prefs.edit().remove("ringtone").commit());return}
        require(PhonePreferenceRules.ringtone(uri.toString()) && readable(uri)) { "Choose an available Android ringtone. Silent sounds are not supported." }
        save("ringtone",uri.toString())
    }
    fun ringtoneName():String = ringtoneUri()?.let { try { RingtoneManager.getRingtone(context,it)?.getTitle(context) }catch(_:Exception){null} }?.takeIf{it.isNotBlank()} ?: "System ringtone"
    fun reset(){check(prefs.edit().clear().commit())}
}
