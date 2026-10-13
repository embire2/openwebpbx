/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.junit.Assert.*
import org.junit.Test

class PhonePreferenceRulesTest {
    @Test fun invalidOrOlderPreferencesHaveSafeDefaults(){
        assertEquals("System",PhonePreferenceRules.choice("neon",PhonePreferenceRules.themes))
        assertEquals("Keypad",PhonePreferenceRules.choice(null,PhonePreferenceRules.pages))
        assertEquals("Name",PhonePreferenceRules.choice("random",PhonePreferenceRules.sorting))
        assertTrue(PhonePreferenceRules.dark("System",true));assertFalse(PhonePreferenceRules.dark("System",false))
        assertTrue(PhonePreferenceRules.dark("Dark",false));assertFalse(PhonePreferenceRules.dark("Light",true))
    }
    @Test fun ringtonesCannotSelectNetworkFilesSilentOrForeignProviders(){
        for(uri in listOf("", "file:///tmp/sound.wav", "https://example.com/sound.wav", "content://unknown/audio/1", "content://media", "content://user@media/audio/1", "content://media/audio/1?silent=true", "content://media/audio/1#x"))assertFalse(uri,PhonePreferenceRules.ringtone(uri))
        assertTrue(PhonePreferenceRules.ringtone("content://media/internal/audio/media/7"))
        assertTrue(PhonePreferenceRules.ringtone("content://settings/system/ringtone"))
    }
    @Test fun realAndroidCanonicalSoundsRetainOnlyTrustedMediaMetadata(){
        val sound="content://media/internal/audio/media/13"
        assertTrue(PhonePreferenceRules.ringtone("$sound?title=Andromeda&canonical=1"))
        assertTrue(PhonePreferenceRules.ringtone("$sound?canonical=1&title=My%20ringtone"))
        assertTrue(PhonePreferenceRules.ringtone("$sound?canonical=1"))
        for(query in listOf("title=Andromeda", "canonical=0", "canonical=1&redirect=https%3A%2F%2Fexample.com", "canonical=1&canonical=1", "title=&canonical=1", "title=%00&canonical=1", "canonical=1&title=Tone&extra=1"))assertFalse(query,PhonePreferenceRules.ringtone("$sound?$query"))
        assertFalse(PhonePreferenceRules.ringtone("content://settings/system/ringtone?canonical=1"))
    }
}
