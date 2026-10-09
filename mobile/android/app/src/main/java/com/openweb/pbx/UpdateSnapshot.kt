/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

/** Shared display state for direct-download and store-managed update providers. */
data class UpdateSnapshot(val state:String="idle",val message:String="Updates have not been checked yet.",val release:AndroidRelease?=null,val mode:String="notify",val progress:Long=0,val total:Long=0,val displayVersion:String?=release?.version,val releaseKey:String?=release?.sha256,val actionLabel:String?=null,val gateTitle:String="Your phone update is ready",val gateMessage:String?=null,val policyMessage:String?=null)
