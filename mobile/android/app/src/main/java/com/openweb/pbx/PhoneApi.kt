/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.URLEncoder
import java.net.URL
import javax.net.ssl.HttpsURLConnection

class ApiError(val status: Int, message: String): Exception(message)
class PhoneApi(private val server: String, private val token: String? = null) {
    private fun connection(action: String, id: String?, body: JSONObject?): HttpsURLConnection {
        require(action.matches(Regex("[a-z_]+")))
        val endpoint = Enrollment.server(server) + "/app/pbx_mobile/api.php?action=" + action + (id?.let { "&id=" + URLEncoder.encode(it, "UTF-8") } ?: "")
        return (URL(endpoint).openConnection() as HttpsURLConnection).apply {
            connectTimeout = 12000; readTimeout = 15000; instanceFollowRedirects = false
            setRequestProperty("Accept", "application/json")
            setRequestProperty("User-Agent", "OpenWebPBX-Android/${BuildConfig.VERSION_NAME}")
            if (!token.isNullOrEmpty()) setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                requestMethod = "POST"; doOutput = true; setRequestProperty("Content-Type", "application/json")
                outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
        }
    }
    private fun bytes(action: String, id: String?, body: JSONObject?, limit: Int): ByteArray {
        val c = connection(action, id, body)
        try {
            val status = c.responseCode
            if (status !in 200..299) {
                // Do not display server bodies: they can contain implementation or credential details.
                throw ApiError(status, when(status) { 401, 403 -> "This phone is no longer connected. Ask your administrator for a new QR code."; 409, 410 -> "That connection code was already used or has expired."; 429 -> "Please wait a moment before trying again."; 400 -> if(action=="enroll") "That setup code is invalid or has expired. Ask your administrator for a new QR code." else "Check the details and try again."; 503 -> "Your PBX is temporarily unavailable. Try again shortly."; else -> "The PBX could not complete the request. Please try again." })
            }
            require(c.contentLengthLong <= limit) { "The server returned a file that is too large" }
            return c.inputStream.use { input ->
                val result = ByteArrayOutputStream(); val buffer = ByteArray(8192)
                while (true) { val n = input.read(buffer); if (n < 0) break; require(result.size() + n <= limit) { "The server returned too much data" }; result.write(buffer, 0, n) }
                result.toByteArray()
            }
        } finally { c.disconnect() }
    }
    fun json(action: String, body: JSONObject? = null): JSONObject = JSONObject(String(bytes(action, null, body, 2 * 1024 * 1024), Charsets.UTF_8))
    fun voicemail(id: String): ByteArray = bytes("voicemail_audio", id, null, 32 * 1024 * 1024)
}
