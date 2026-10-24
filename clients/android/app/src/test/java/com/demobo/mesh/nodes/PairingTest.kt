package com.demobo.mesh.nodes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingTest {
    @Test fun readsTheCodeGemmaMeshPairPrints() {
        val p = Pairing.parse("""{"v":1,"app":"gemma-mesh","mesh":"default","nodes":["http://192.168.1.20:9400"],"device":"my-macbook"}""").getOrThrow()
        assertEquals("default", p.mesh)
        assertEquals(listOf("http://192.168.1.20:9400"), p.nodes)
        assertEquals("my-macbook", p.device)
    }

    @Test fun refusesOtherCodes() {
        assertTrue(Pairing.parse("""{"v":1,"app":"other","nodes":["http://x:1"]}""").isFailure)
        assertTrue(Pairing.parse("https://example.com").isFailure)
        assertTrue(Pairing.parse("""{"v":1,"app":"gemma-mesh","nodes":[]}""").isFailure)
        assertTrue(Pairing.parse("""{"v":1,"app":"gem-mesh","mesh":"default","nodes":["http://192.168.1.20:9400"],"device":"m"}""").isSuccess)
    }

    @Test fun normalizesAddresses() {
        assertEquals("http://10.0.2.2:9400", Node.normalizeUrl("10.0.2.2"))
        assertEquals("http://mac.local:9400", Node.normalizeUrl("http://mac.local:9400/v1/"))
        assertEquals("http://h:1234", Node.normalizeUrl("h:1234"))
    }
}
