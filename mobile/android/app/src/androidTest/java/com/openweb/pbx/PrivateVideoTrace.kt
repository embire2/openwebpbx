/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx
import org.linphone.core.*
import java.io.File
/** Opt-in fictional-tenant diagnostic; logs stay private and are never release assets. */
internal class PrivateVideoTrace(file:File):AutoCloseable {
 private val writer=file.bufferedWriter()
 private var closed=false
 private val logger=Factory.instance().loggingService
 private val listener=object:LoggingServiceListenerStub(){override fun onLogMessageWritten(service:LoggingService,domain:String,level:LogLevel,message:String){synchronized(writer){if(!closed){writer.appendLine("${System.currentTimeMillis()} $domain $level $message");writer.flush()}}}}
 init{logger.addListener(listener);logger.setLogLevel(LogLevel.Message)}
 override fun close(){logger.setLogLevel(LogLevel.Fatal);logger.removeListener(listener);synchronized(writer){closed=true;writer.close()}}
}
