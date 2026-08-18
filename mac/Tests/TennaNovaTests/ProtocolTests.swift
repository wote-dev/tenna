import Testing
@testable import TennaNova

struct ProtocolTests {
    @Test func imageHeaderRoundTrip() throws {
        let original = ClipImage(origin: "android", seq: 4, mime: "image/png",
                                 bytes: 123, sha256: String(repeating: "a", count: 64),
                                 name: "shot.png")
        let decoded = try Wire.decode(ClipImage.self, from: Wire.encode(original))
        #expect(decoded.type == "clip.image")
        #expect(decoded.bytes == 123)
        #expect(decoded.name == "shot.png")
    }

    @Test func usbPortIsOmittedWhenTheTunnelIsDown() throws {
        // Absence is meaningful: the phone reads a missing usbPort as "no USB right now"
        // and drops any loopback endpoint it was holding. Encoding a null would be read
        // the same way, but a key that is simply absent is what older builds already emit.
        let json = String(data: try Wire.encode(MacHosts(hosts: ["10.0.0.2"], port: 18777)),
                          encoding: .utf8)!
        #expect(!json.contains("usbPort"))
    }

    @Test func usbPortSurvivesTheWireOnHostsAndAck() throws {
        let hosts = try Wire.decode(
            MacHosts.self,
            from: Wire.encode(MacHosts(hosts: ["10.0.0.2"], port: 18777, usbPort: 18777))
        )
        #expect(hosts.usbPort == 18777)

        let ack = try Wire.decode(
            HelloAck.self,
            from: Wire.encode(HelloAck(deviceToken: nil, macName: "Mac", usbPort: 18777))
        )
        #expect(ack.usbPort == 18777)
    }

    @Test func helloAckAdvertisesImageCapability() throws {
        let ack = HelloAck(deviceToken: nil, macName: "Mac")
        let decoded = try Wire.decode(HelloAck.self, from: Wire.encode(ack))
        #expect(decoded.capabilities == [Proto.imageClipboardCapability])
    }

    @Test func legacyHelloWithoutCapabilitiesStillDecodes() throws {
        let data = Wire.utf8(
            #"{"v":1,"type":"hello","token":"t","device":{"id":"1","name":"Phone"}}"#
        )
        let hello = try Wire.decode(Hello.self, from: data)
        #expect(hello.capabilities == nil)
    }

    @Test func imageMetadataRejectsWrongOriginSizeAndHash() {
        let image = ClipImage(origin: "android", seq: 1, mime: "image/png", bytes: 4,
                              sha256: String(repeating: "a", count: 64), name: "a.png")
        #expect(image.hasValidMetadata(expectedOrigin: "android"))
        #expect(!image.hasValidMetadata(expectedOrigin: "mac"))
        #expect(!image.with(bytes: Proto.maxImageBytes + 1)
            .hasValidMetadata(expectedOrigin: "android"))
        #expect(!image.with(sha256: String(repeating: "A", count: 64))
            .hasValidMetadata(expectedOrigin: "android"))
    }

    @Test func clipboardHashIsStable() {
        #expect(
            PasteboardBridge.sha256(Wire.utf8("tenna")) ==
                "95271fca5ee7a17b5e4d4257c5c6f8833973bcfef9e757dd9ec7df16fc966341"
        )
    }

    @Test func adbDeviceParsingIgnoresHeaderAndKeepsAuthorizationState() {
        let output = """
        List of devices attached
        PHONE1 device usb:1-2 model:SM_S942B
        PHONE2 unauthorized usb:1-3

        """
        #expect(ADBBridge.parseDevices(output) == [
            ADBDevice(serial: "PHONE1", state: "device"),
            ADBDevice(serial: "PHONE2", state: "unauthorized")
        ])
    }
}

private extension ClipImage {
    func with(bytes: Int? = nil, sha256: String? = nil) -> ClipImage {
        ClipImage(origin: origin, seq: seq, mime: mime, bytes: bytes ?? self.bytes,
                  sha256: sha256 ?? self.sha256, name: name)
    }
}
