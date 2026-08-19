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
            listOf(
                ConnectionEndpoint("mac.local", 18777, isUsb = false),
                ConnectionEndpoint("127.0.0.1", 18777, isUsb = true)
            ),
            buildEndpointCandidates(listOf("mac.local"), 18777, null)
        )
    }

    @Test fun unknownUsbIsProbedLastRatherThanNotAtAll() {
        // A phone paired while unplugged is never taught usbPort, and on a network with
        // AP client isolation it cannot establish the session that would teach it. So the
        // loopback guess goes on the end, where it costs a timeout only once every real
        // address has already failed.
        val endpoints = buildEndpointCandidates(listOf("192.168.1.20", "192.168.1.21"), 18777, null)

        assertEquals(ConnectionEndpoint("127.0.0.1", 18777, isUsb = true), endpoints.last())
        assertTrue(endpoints.dropLast(1).none { it.isUsb })
    }

    @Test fun aKnownUsbPortIsNotAlsoGuessedAtTheEnd() {
        val endpoints = buildEndpointCandidates(listOf("192.168.1.20"), 18777, 18777)

        assertEquals(1, endpoints.count { it.isUsb })
        assertTrue(endpoints.first().isUsb)
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
                ConnectionEndpoint("192.168.43.37", 18777, isUsb = false),
                ConnectionEndpoint("127.0.0.1", 18777, isUsb = true)
            ),
            buildEndpointCandidates(listOf("192.168.1.20", "192.168.43.37"), 18777, null)
        )
    }

    @Test fun freshlyDiscoveredAddressLeadsRememberedAddresses() {
        val live = ConnectionEndpoint("192.168.210.196", 18777, isUsb = false)

        assertEquals(
            listOf(
                live,
                ConnectionEndpoint("192.168.1.20", 18777, isUsb = false),
                ConnectionEndpoint("127.0.0.1", 18777, isUsb = true)
            ),
            buildEndpointCandidates(
                lanHosts = listOf("192.168.1.20"),
                lanPort = 18777,
                usbPort = null,
                discovered = listOf(live)
            )
        )
    }

    @Test fun repeatedAddressesCollapse() {
        assertEquals(
            listOf(
                ConnectionEndpoint("192.168.1.20", 18777, isUsb = false),
                ConnectionEndpoint("127.0.0.1", 18777, isUsb = true)
            ),
            buildEndpointCandidates(listOf("192.168.1.20", "192.168.1.20"), 18777, null)
        )
    }

    @Test fun noKnownAddressesMeansNothingToTry() {
        // An empty list is how "not paired" reaches the client, so the loopback guess must
        // not fire here either — it would turn UNPAIRED into a permanent CONNECTING.
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

    @Test fun theRelayIsTriedOnlyAfterEveryDirectRouteHasFailed() {
        // Reaching a Mac on the same desk by way of a server on the other side of the
        // country is absurd, so the relay never races a direct route — it rescues one.
        val endpoints = buildEndpointCandidates(
            lanHosts = listOf("192.168.1.20"),
            lanPort = 18777,
            usbPort = 18777,
            discovered = listOf(ConnectionEndpoint("192.168.1.21", 18777, isUsb = false)),
            relayPort = 41234
        )

        assertEquals(
            ConnectionEndpoint("127.0.0.1", 41234, isUsb = false, isRelay = true),
            endpoints.last()
        )
        assertTrue(endpoints.dropLast(1).none { it.isRelay })
    }

    @Test fun theRelayIsTheOnlyCandidateWhenNoAddressIsKnown() {
        // A phone paired over the relay alone, or one whose remembered addresses have all
        // been cleared, still has somewhere to go.
        assertEquals(
            listOf(ConnectionEndpoint("127.0.0.1", 41234, isUsb = false, isRelay = true)),
            buildEndpointCandidates(emptyList(), 18777, null, emptyList(), relayPort = 41234)
        )
    }

    @Test fun noRelayPortMeansNoRelayCandidate() {
        assertTrue(
            buildEndpointCandidates(listOf("192.168.1.20"), 18777, null, emptyList(), null)
                .none { it.isRelay }
        )
    }

    @Test fun theRelayLoopbackIsNotConfusedWithTheUsbLoopback() {
        // Same address, opposite handling: USB is instant and local, the relay is a
        // round trip through the internet, and neither may be treated as the other.
        val endpoints = buildEndpointCandidates(emptyList(), 18777, 18777, emptyList(), 41234)
        val usb = endpoints.single { it.isUsb }
        val relay = endpoints.single { it.isRelay }

        assertEquals(usb.host, relay.host)
        assertTrue(!usb.isRelay && !relay.isUsb)
    }
}
