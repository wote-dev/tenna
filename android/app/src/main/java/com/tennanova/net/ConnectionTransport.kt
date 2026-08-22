package com.tennanova.net

/**
 * Which route is carrying the session.
 *
 * Worth surfacing rather than collapsing into "connected": a relayed session works, but
 * it depends on a server being up and it is slower than the same phone on the same desk
 * over Wi-Fi. Someone debugging why sync feels sluggish deserves to see which one it is.
 */
enum class ConnectionTransport {
    NONE, LAN, USB, RELAY;

    val wire: String?
        get() = when (this) {
            LAN -> "lan"
            USB -> "usb"
            RELAY -> "relay"
            NONE -> null
        }
}
