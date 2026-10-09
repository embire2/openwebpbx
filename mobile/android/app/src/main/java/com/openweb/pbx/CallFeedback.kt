/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx
/** Never surface raw network/server messages, which can contain private identifiers. */
object CallFeedback {
    fun failure(code:Int):String = when(code) {
        401,403,407 -> "This call was not allowed. Ask your administrator to check your calling permissions."
        404,410,484 -> "That number could not be reached. Check the number or extension and try again."
        408,480,504 -> "No answer or the phone is unavailable. Try again shortly."
        486,600 -> "The person you called is busy. Try again shortly."
        603 -> "The call was declined. Try again later."
        488,415,606 -> "The phones could not connect their audio. Ask your administrator to check the connection."
        500,502,503 -> "Your company’s phone connection could not complete this call. Ask your administrator to check the provider and calling rules."
        else -> "The call could not connect. Check your connection and try again. If it continues, ask your administrator to check the calling rules."
    }
}
