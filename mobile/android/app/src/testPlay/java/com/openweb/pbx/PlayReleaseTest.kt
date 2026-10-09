/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.junit.Assert.*
import org.junit.Test

class PlayReleaseTest {
    private val now=1800000000000L
    private fun release()=PlayRelease("1.0.7",107,"1.0.6",28,now-1000,now+60000)
    private fun rejects(block:()->Unit){try{block();fail("Invalid Play publication must be rejected")}catch(_:IllegalArgumentException){}}
    @Test fun onlyCompletedProductionPublicationIsAvailabilityEvidence(){
        assertTrue(PlayReleaseRules.published("published","production","complete"))
        assertFalse(PlayReleaseRules.published("pending","production","complete"))
        assertFalse(PlayReleaseRules.published("published","internal","complete"))
        assertFalse(PlayReleaseRules.published("published","production","staged"))
    }
    @Test fun publishedVersionCannotLeadSignedFeedOrUseInvalidValues(){
        PlayReleaseRules.validate(release(),"1.0.8",now,now)
        rejects{PlayReleaseRules.validate(release(),"1.0.6",now,now)}
        rejects{PlayReleaseRules.validate(release().copy(versionCode=0),"1.0.8",now,now)}
        rejects{PlayReleaseRules.validate(release().copy(minimumSdk=27),"1.0.8",now,now)}
        rejects{PlayReleaseRules.validate(release().copy(published=now+1),"1.0.8",now,now)}
        rejects{PlayReleaseRules.validate(release().copy(expires=now),"1.0.8",now,now)}
    }
    @Test fun versionSdkAndServerSupportMustAllHold(){
        assertTrue(PlayReleaseRules.newer(release(),"1.0.6",106))
        assertFalse(PlayReleaseRules.newer(release(),"1.0.7",106))
        assertFalse(PlayReleaseRules.newer(release(),"1.0.6",107))
        assertTrue(PlayReleaseRules.supported(release(),28,"1.0.6"))
        assertFalse(PlayReleaseRules.supported(release(),27,"1.0.6"))
        assertFalse(PlayReleaseRules.supported(release(),28,"1.0.5"))
    }
    @Test fun cachedRequiredPolicyIsTimeLimitedAndAccountBound(){
        assertTrue(PlayReleaseRules.policyFresh(now-1000,now,"first","first"))
        assertFalse(PlayReleaseRules.policyFresh(now,now,"first","second"))
        assertFalse(PlayReleaseRules.policyFresh(now,now,"",""))
        assertFalse(PlayReleaseRules.policyFresh(now-86400000,now,"first","first"))
        assertFalse(PlayReleaseRules.policyFresh(now+300001,now,"first","first"))
    }
}
