package com.openweb.pbx

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.SecretKey

@RunWith(AndroidJUnit4::class)
class ProfileStoreTest {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun account(host:String,extension:String="100")=JSONObject().put("server","https://$host.example.invalid").put("token","fixture-token-$host-"+"x".repeat(32)).put("device_id","device-$host").put("account",JSONObject().put("extension",extension).put("domain_uuid","domain-$host").put("extension_uuid","extension-$host-$extension")).put("sip",JSONObject().put("domain","$host.example.invalid").put("username","device-$host").put("password","private-$host")).put("pending_calls",JSONArray().put(JSONObject().put("id","old-$host")))
    private fun isolated(block:(PhoneStore)->Unit){
        val prefs=context.getSharedPreferences("private_account",0);val before=prefs.getString("sealed",null)
        try{prefs.edit().clear().commit();block(PhoneStore(context))}finally{prefs.edit().clear().apply();if(before!=null)prefs.edit().putString("sealed",before).commit()}
    }
    @Test fun legacyCiphertextMigratesWithoutLosingSecretsHistoryOrPush()=isolated{store->
        store.save(account("key-initializer"));store.clear()
        val legacy=account("legacy").put("push_pending_id","waiting").put("push_state","ready")
        val keys=KeyStore.getInstance("AndroidKeyStore").apply{load(null)};val key=keys.getKey("openweb-account-v1",null) as SecretKey
        val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key)
        val encoded=Base64.encodeToString(cipher.iv+cipher.doFinal(legacy.toString().toByteArray()),Base64.NO_WRAP)
        val prefs=context.getSharedPreferences("private_account",0);prefs.edit().putString("sealed",encoded).commit()
        val migrated=store.read()!!;for(name in legacy.keys())assertEquals(legacy.get(name).toString(),migrated.get(name).toString())
        assertEquals(1,store.profiles().size);assertEquals(migrated.getString("profile_id"),PhoneStore(context).selectedId())
        assertFalse(prefs.getString("sealed","")!!.contains("fixture-token"));assertNotEquals(encoded,prefs.getString("sealed",null))
    }
    @Test fun sameExtensionAcrossTenantsStaysIsolatedAndRemovalPreservesOthers()=isolated{store->
        val a=store.add(account("alpha"));val b=store.add(account("beta"));assertNotEquals(a,b);assertEquals(2,store.profiles().size)
        store.select(a);assertEquals("device-alpha",store.read()!!.getString("device_id"))
        store.update(b){it.put("push_state","ready");it.getJSONArray("pending_calls").put(JSONObject().put("id","new-beta"))}
        assertEquals(1,store.read(a)!!.getJSONArray("pending_calls").length());assertEquals(2,store.read(b)!!.getJSONArray("pending_calls").length())
        assertEquals(b,store.byDevice("device-beta")!!.getString("profile_id"));val alpha=store.read(a).toString()
        store.remove(b);assertEquals(alpha,store.read(a).toString());assertEquals(a,store.selectedId());assertNull(store.read(b))
    }
    @Test fun independentWritersCannotOverwriteAnotherProfilesQueuedCalls()=isolated{store->
        val a=store.add(account("alpha"));val b=store.add(account("beta"))
        val threads=(0..3).map{n->Thread{
            repeat(20){index->PhoneStore(context).update(if(n%2==0)a else b){saved->saved.getJSONArray("pending_calls").put(JSONObject().put("id","$n-$index"))}}
        }}.onEach{it.start()}
        threads.forEach{it.join()};assertEquals(41,store.read(a)!!.getJSONArray("pending_calls").length());assertEquals(41,store.read(b)!!.getJSONArray("pending_calls").length())
    }
    @Test fun duplicateAccountAndUnknownProfileSelectionRefuse()=isolated{store->
        store.add(account("alpha"));val sealed=context.getSharedPreferences("private_account",0).getString("sealed",null)
        try{store.add(account("alpha"));fail()}catch(_:IllegalArgumentException){}
        try{store.select("missing");fail()}catch(_:IllegalArgumentException){}
        assertEquals(sealed,context.getSharedPreferences("private_account",0).getString("sealed",null))
    }
    @Test fun setupParserRejectsPasswordsForeignShapesAndOversizedFiles(){
        val valid=JSONObject().put("type","openwebpbx").put("version",1).put("server","https://alpha.example.invalid").put("extension","100").put("code","one-use-fixture-code-123456789")
        assertEquals("100",ProfileRules.setup(valid.toString()).getString("extension"))
        for(key in listOf("password","sip","token","extra")){val bad=JSONObject(valid.toString()).put(key,"no");try{ProfileRules.setup(bad.toString());fail(key)}catch(_:IllegalArgumentException){}}
        try{ProfileRules.setup("x".repeat(ProfileRules.MAX_SETUP_BYTES+1));fail()}catch(_:IllegalArgumentException){}
    }
    @Test fun updatePolicyIdentityIncludesEveryProfileAndIgnoresSelection()=isolated{store->
        val a=store.add(account("alpha"));val one=ProfileUpdatePolicy.identity(store.profiles());val b=store.add(account("beta"));val both=ProfileUpdatePolicy.identity(store.profiles());assertNotEquals(one,both)
        store.select(a);assertEquals(both,ProfileUpdatePolicy.identity(store.profiles()));store.select(b);assertEquals(both,ProfileUpdatePolicy.identity(store.profiles()))
        store.update(a){it.put("token","changed-alpha")};assertNotEquals(both,ProfileUpdatePolicy.identity(store.profiles()))
    }
}
