package com.openweb.pbx
import org.junit.Assert.*
import org.junit.Test
class EnrollmentTest {
    @Test fun acceptsHttpsOrigin() { assertEquals("https://pbx.example.com",Enrollment.server(" https://pbx.example.com/ "));assertEquals("https://pbx.example.com:8443",Enrollment.server("https://pbx.example.com:8443")) }
    @Test fun rejectsUnsafeServerAddresses() { for(value in listOf("http://pbx.example.com","https://secret@pbx.example.com","https://pbx.example.com/path","https://pbx.example.com/?token=x","https://pbx.example.com/#x","file:///tmp/test","javascript:alert(1)","https://pbx.example.com:99999")) { try {Enrollment.server(value);fail(value)}catch(_:IllegalArgumentException){} } }
    @Test fun validatesOneTimeCodes() { assertEquals("abc_123-def_456789",Enrollment.code(" abc_123-def_456789 "));for(value in listOf("short","abc defg123456789012","abcdef1234567890&token=x")){try{Enrollment.code(value);fail(value)}catch(_:IllegalArgumentException){}} }
    @Test fun allowsOnlyPhoneNumbers() { assertEquals("+27123456789",Enrollment.number("+27 (12) 345-6789"));assertEquals("*97",Enrollment.number("*97"));for(value in listOf("sip:other@evil.example","1000;transport=udp","999\r\nVia: bad","a","")){try{Enrollment.number(value);fail(value)}catch(_:IllegalArgumentException){}} }
}
