/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.net.URI
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object Enrollment {
    fun server(value: String): String {
        val uri = URI(value.trim())
        require(uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null && uri.query == null && uri.fragment == null && (uri.path.isNullOrEmpty() || uri.path == "/")) { "Enter your PBX's HTTPS address, for example https://call.example.com" }
        require(uri.port == -1 || uri.port in 1..65535) { "Invalid server port" }
        return "https://${uri.rawAuthority}"
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
    fun read(): JSONObject? = synchronized(accountLock) {
        val raw = prefs.getString("sealed", null) ?: return null
        return try {
            val bytes = Base64.decode(raw, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
        } catch (_: Exception) { clear(); null }
    }
    fun save(value: JSONObject) = synchronized(accountLock) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val bytes = cipher.iv + cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString("sealed", Base64.encodeToString(bytes, Base64.NO_WRAP)).commit()) { "Could not save this phone securely" }
    }
    fun clear() = synchronized(accountLock) { prefs.edit().clear().commit(); Unit }
    fun update(change: (JSONObject) -> Unit): JSONObject? = synchronized(accountLock) {
        read()?.also { change(it); save(it) }
    }
}
