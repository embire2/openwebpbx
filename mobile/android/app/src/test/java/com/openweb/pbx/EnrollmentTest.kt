package com.openweb.pbx
import org.junit.Assert.*
import org.junit.Test
class EnrollmentTest {
    @Test fun acceptsOnlyTenantHttpsOrigins() { assertEquals("https://openweb.openwebpbx.com",Enrollment.server(" https://OpenWeb.openwebpbx.com/ "));assertEquals("https://alpha.openwebpbx.com",Enrollment.server("https://alpha.openwebpbx.com:443")) }
    @Test fun rejectsUnsafeServerAddresses() { for(value in listOf("http://alpha.openwebpbx.com","https://secret@alpha.openwebpbx.com","https://alpha.openwebpbx.com/path","https://alpha.openwebpbx.com/?token=x","https://alpha.openwebpbx.com/#x","file:///tmp/test","javascript:alert(1)","https://alpha.openwebpbx.com:8443","https://call.openweb.co.za","https://openwebpbx.com","https://alpha.openwebpbx.com.evil.com","https://evilopenwebpbx.com","https://nested.alpha.openwebpbx.com","https://alpha.openwebpbx.com.","https://xn--test-9qa.openwebpbx.com","https://127.0.0.1","https://[::1]","https://alpha.openwebpbx.com\\@evil.test")) { try {Enrollment.server(value);fail(value)}catch(_:Exception){} } }
    @Test fun validatesOneTimeCodes() { assertEquals("abc_123-def_456789",Enrollment.code(" abc_123-def_456789 "));for(value in listOf("short","abc defg123456789012","abcdef1234567890&token=x")){try{Enrollment.code(value);fail(value)}catch(_:IllegalArgumentException){}} }
    @Test fun allowsOnlyPhoneNumbers() { assertEquals("+27123456789",Enrollment.number("+27 (12) 345-6789"));assertEquals("*97",Enrollment.number("*97"));for(value in listOf("sip:other@evil.example","1000;transport=udp","999\r\nVia: bad","a","")){try{Enrollment.number(value);fail(value)}catch(_:IllegalArgumentException){}} }
}
