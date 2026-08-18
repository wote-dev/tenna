package com.tennanova.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SocketClientTest {
    @Test fun usbLoopbackIsTriedBeforeLan() {
        assertEquals(
            listOf(
                ConnectionEndpoint("127.0.0.1", 18777, isUsb = true),
                ConnectionEndpoint("192.168.1.20", 18777, isUsb = false)
            ),
            buildEndpointCandidates(listOf("192.168.1.20"), 18777, 18777)
        )
    }

    @Test fun lanStillWorksForLegacyPairingCodes() {
        assertEquals(
            listOf(ConnectionEndpoint("mac.local", 18777, isUsb = false)),
            buildEndpointCandidates(listOf("mac.local"), 18777, null)
        )
    }

    @Test fun duplicateLoopbackEndpointIsOnlyTriedOnce() {
        assertEquals(
            listOf(ConnectionEndpoint("127.0.0.1", 18777, isUsb = true)),
            buildEndpointCandidates(listOf("127.0.0.1"), 18777, 18777)
        )
    }

    @Test fun everyKnownAddressIsTriedInOrder() {
        // The hotspot case: the Mac's LAN address is stale and the one that works is the
        // tether-subnet address it picked up afterwards.
        assertEquals(
            listOf(
                ConnectionEndpoint("192.168.1.20", 18777, isUsb = false),
                ConnectionEndpoint("192.168.43.37", 18777, isUsb = false)
            ),
            buildEndpointCandidates(listOf("192.168.1.20", "192.168.43.37"), 18777, null)
        )
    }

    @Test fun repeatedAddressesCollapse() {
        assertEquals(
            listOf(ConnectionEndpoint("192.168.1.20", 18777, isUsb = false)),
            buildEndpointCandidates(listOf("192.168.1.20", "192.168.1.20"), 18777, null)
        )
    }

    @Test fun noKnownAddressesMeansNothingToTry() {
        assertTrue(buildEndpointCandidates(emptyList(), 18777, null).isEmpty())
    }

    @Test fun subnetMembershipDecidesWhichNetworkToBind() {
        val local = NetworkRoutes.parseIPv4("192.168.2.7")!!
        val onSameWifi = NetworkRoutes.parseIPv4("192.168.2.1")!!
        val onCellular = NetworkRoutes.parseIPv4("10.44.9.3")!!

        assertTrue(NetworkRoutes.sameSubnet(local, 24, onSameWifi))
        assertTrue(!NetworkRoutes.sameSubnet(local, 24, onCellular))
        // A /16 swallows both halves of 192.168.x.x.
        assertTrue(NetworkRoutes.sameSubnet(local, 16, NetworkRoutes.parseIPv4("192.168.99.4")!!))
    }

    @Test fun onlyLiteralAddressesParse() {
        // A hostname would mean a DNS lookup on the main thread.
        assertNull(NetworkRoutes.parseIPv4("mac.local"))
        assertNull(NetworkRoutes.parseIPv4("192.168.1"))
        assertNull(NetworkRoutes.parseIPv4("192.168.1.256"))
        assertEquals(4, NetworkRoutes.parseIPv4("255.255.255.255")!!.size)
    }

    @Test fun probeWalksEveryHostInTheSubnet() {
        val base = SubnetScanner.maskedBase(NetworkRoutes.parseIPv4("192.168.43.137")!!, 24)

        assertEquals("192.168.43.0", base.joinToString(".") { (it.toInt() and 0xFF).toString() })
        assertEquals(
            "192.168.43.1",
            SubnetScanner.addOffset(base, 1).joinToString(".") { (it.toInt() and 0xFF).toString() }
        )
        assertEquals(
            "192.168.43.254",
            SubnetScanner.addOffset(base, 254)
                .joinToString(".") { (it.toInt() and 0xFF).toString() }
        )
    }

    @Test fun offsetsCarryAcrossOctetsOnWiderSubnets() {
        val base = SubnetScanner.maskedBase(NetworkRoutes.parseIPv4("10.0.3.5")!!, 23)

        assertEquals("10.0.2.0", base.joinToString(".") { (it.toInt() and 0xFF).toString() })
        assertEquals(
            "10.0.3.44",
            SubnetScanner.addOffset(base, 300)
                .joinToString(".") { (it.toInt() and 0xFF).toString() }
        )
    }
}
