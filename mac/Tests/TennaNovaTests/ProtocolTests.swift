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

    @Test func helloAckAdvertisesWhatThisMacCanDo() throws {
        let ack = HelloAck(deviceToken: nil, macName: "Mac")
        let decoded = try Wire.decode(HelloAck.self, from: Wire.encode(ack))
        #expect(decoded.capabilities.contains(Proto.imageClipboardCapability))
        #expect(decoded.capabilities.contains(Proto.fileTransferCapability))
        #expect(decoded.capabilities.contains(Proto.mirrorVideoCapability))
        #expect(decoded.capabilities.contains(Proto.mirrorControlCapability))
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

    // MARK: - Files

    @Test func fileOfferRoundTrips() throws {
        let offer = FileOffer(id: "a1b2c3d4", name: "screen-20250817-005420.mp4",
                              bytes: 14_417_920, mime: "video/mp4",
                              sha256: String(repeating: "b", count: 64),
                              modified: 1_723_900_000_000)
        let decoded = try Wire.decode(FileOffer.self, from: Wire.encode(offer))
        #expect(decoded.type == "file.offer")
        #expect(decoded.id == "a1b2c3d4")
        #expect(decoded.name == "screen-20250817-005420.mp4")
        #expect(decoded.bytes == 14_417_920)
        #expect(decoded.mime == "video/mp4")
        #expect(decoded.modified == 1_723_900_000_000)
        #expect(decoded.hasValidMetadata)
    }

    @Test func aModificationTimeIsOmittedRatherThanNulled() throws {
        let offer = FileOffer(id: "a1b2c3d4", name: "notes.txt", bytes: 12,
                              mime: "text/plain",
                              sha256: String(repeating: "c", count: 64), modified: nil)
        let json = try #require(String(data: Wire.encode(offer), encoding: .utf8))
        #expect(!json.contains("modified"))
    }

    @Test func anOfferIsRefusedWhenAnythingAboutItIsWrong() {
        let valid = FileOffer(id: "a1b2c3d4", name: "notes.txt", bytes: 12,
                              mime: "text/plain",
                              sha256: String(repeating: "c", count: 64), modified: nil)
        #expect(valid.hasValidMetadata)
        #expect(!valid.with(bytes: 0).hasValidMetadata)
        #expect(!valid.with(bytes: Proto.maxFileBytes + 1).hasValidMetadata)
        #expect(!valid.with(sha256: "nope").hasValidMetadata)
        #expect(!valid.with(id: "not hex").hasValidMetadata)
        #expect(!valid.with(id: "abc").hasValidMetadata)
    }

    /// A name is the one field a hostile peer controls that could name a path. The offer
    /// is refused outright rather than repaired, and nothing is ever stored under it.
    @Test func aNameThatCouldNameAPathIsRefused() {
        let valid = FileOffer(id: "a1b2c3d4", name: "notes.txt", bytes: 12,
                              mime: "text/plain",
                              sha256: String(repeating: "c", count: 64), modified: nil)
        #expect(!valid.with(name: "../../.ssh/authorized_keys").hasValidMetadata)
        #expect(!valid.with(name: "sub/dir.txt").hasValidMetadata)
        #expect(!valid.with(name: #"windows\path.txt"#).hasValidMetadata)
        #expect(!valid.with(name: "..").hasValidMetadata)
        #expect(!valid.with(name: "").hasValidMetadata)
        #expect(!valid.with(name: String(repeating: "n", count: 256)).hasValidMetadata)
        // Legitimate names that merely look alarming still pass.
        #expect(valid.with(name: "..notes..txt").hasValidMetadata)
        #expect(valid.with(name: "résumé (final) [v2].pdf").hasValidMetadata)
    }

    @Test func chunkAndAckRoundTrip() throws {
        let chunk = FileChunk(id: "a1b2c3d4", offset: 3_145_728, bytes: 262_144)
        let decodedChunk = try Wire.decode(FileChunk.self, from: Wire.encode(chunk))
        #expect(decodedChunk.type == "file.chunk")
        #expect(decodedChunk.offset == 3_145_728)
        #expect(decodedChunk.hasValidMetadata)
        #expect(!FileChunk(id: "a1b2c3d4", offset: -1, bytes: 1).hasValidMetadata)
        #expect(!FileChunk(id: "a1b2c3d4", offset: 0,
                           bytes: Proto.fileChunkBytes + 1).hasValidMetadata)

        let ack = FileAck(id: "a1b2c3d4", received: 3_407_872)
        let decodedAck = try Wire.decode(FileAck.self, from: Wire.encode(ack))
        #expect(decodedAck.type == "file.ack")
        #expect(decodedAck.received == 3_407_872)
    }

    /// `offset == fileBytes` is not a resume, it is a finished file, and a sender that
    /// honoured it would send zero chunks and then claim success.
    @Test func aBeginOffsetMustLeaveSomethingToSend() {
        #expect(FileBegin(id: "a1b2c3d4", offset: 0).hasValidMetadata(fileBytes: 10))
        #expect(FileBegin(id: "a1b2c3d4", offset: 9).hasValidMetadata(fileBytes: 10))
        #expect(!FileBegin(id: "a1b2c3d4", offset: 10).hasValidMetadata(fileBytes: 10))
        #expect(!FileBegin(id: "a1b2c3d4", offset: -1).hasValidMetadata(fileBytes: 10))
    }

    @Test func aSuccessfulResultCarriesNoErrorKey() throws {
        let ok = FileResult(id: "a1b2c3d4", ok: true, error: nil)
        let json = try #require(String(data: Wire.encode(ok), encoding: .utf8))
        // Absent rather than null: the phone decodes this into an optional.
        #expect(!json.contains("error"))

        let bad = FileResult(id: "a1b2c3d4", ok: false, error: "checksum mismatch")
        let decoded = try Wire.decode(FileResult.self, from: Wire.encode(bad))
        #expect(decoded.ok == false)
        #expect(decoded.error == "checksum mismatch")
    }
}

private extension ClipImage {
    func with(bytes: Int? = nil, sha256: String? = nil) -> ClipImage {
        ClipImage(origin: origin, seq: seq, mime: mime, bytes: bytes ?? self.bytes,
                  sha256: sha256 ?? self.sha256, name: name)
    }
}

private extension FileOffer {
    func with(id: String? = nil, name: String? = nil, bytes: Int? = nil,
              sha256: String? = nil) -> FileOffer {
        FileOffer(id: id ?? self.id, name: name ?? self.name, bytes: bytes ?? self.bytes,
                  mime: mime, sha256: sha256 ?? self.sha256, modified: modified)
    }
}
