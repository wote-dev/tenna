package com.tennanova.net

import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager
import android.util.Base64

/**
 * Trusts exactly one public key — the Mac's — and nothing else.
 *
 * The Mac's certificate is self-signed, so normal CA validation is meaningless here.
 * Instead we pin the SHA-256 of its public key, which the user transferred out of band
 * by scanning the pairing QR. This is the KDE Connect model.
 *
 * A mismatch is fatal and must not be retried: it means either the wrong Mac or an
 * interception attempt.
 */
class PinnedTrustManager(private val expectedSpkiBase64: String) : X509TrustManager {

    class PinMismatch(val actual: String) :
        CertificateException("server key does not match the paired Mac")

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        throw CertificateException("client authentication is not used")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val leaf = chain?.firstOrNull()
            ?: throw CertificateException("server presented no certificate")

        val actual = spkiHash(leaf)
        if (actual != expectedSpkiBase64) throw PinMismatch(actual)
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    companion object {
        /**
         * Base64 SHA-256 over the raw public key bytes.
         *
         * This must match what the Mac computes with
         * `SecKeyCopyExternalRepresentation`, which for an RSA key returns the
         * PKCS#1 RSAPublicKey structure — *not* the full X.509 SubjectPublicKeyInfo
         * that Java's `getEncoded()` returns. The trailing PKCS#1 blob is therefore
         * extracted from the SPKI wrapper before hashing.
         */
        fun spkiHash(cert: X509Certificate): String {
            val pkcs1 = pkcs1FromSpki(cert.publicKey.encoded)
            val digest = MessageDigest.getInstance("SHA-256").digest(pkcs1)
            return Base64.encodeToString(digest, Base64.NO_WRAP)
        }

        /**
         * Pulls the PKCS#1 RSAPublicKey out of an X.509 SubjectPublicKeyInfo.
         *
         * SPKI is: SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }.
         * We walk to the BIT STRING and return its contents, skipping the unused-bits byte.
         */
        private fun pkcs1FromSpki(spki: ByteArray): ByteArray {
            val p = DerReader(spki)
            p.expect(0x30)          // outer SEQUENCE
            p.readLength()
            p.expect(0x30)          // AlgorithmIdentifier
            val algLen = p.readLength()
            p.skip(algLen)
            p.expect(0x03)          // BIT STRING
            val bitLen = p.readLength()
            p.skip(1)               // unused-bits count, always 0 for keys
            return p.read(bitLen - 1)
        }

        private class DerReader(private val buf: ByteArray) {
            private var i = 0
            fun expect(tag: Int) {
                require(buf[i].toInt() and 0xFF == tag) { "unexpected DER tag at $i" }
                i++
            }
            fun readLength(): Int {
                var len = buf[i++].toInt() and 0xFF
                if (len and 0x80 != 0) {
                    val n = len and 0x7F
                    len = 0
                    repeat(n) { len = (len shl 8) or (buf[i++].toInt() and 0xFF) }
                }
                return len
            }
            fun skip(n: Int) { i += n }
            fun read(n: Int): ByteArray = buf.copyOfRange(i, i + n).also { i += n }
        }

        fun socketFactory(trustManager: X509TrustManager): SSLSocketFactory {
            val ctx = SSLContext.getInstance("TLSv1.3")
            ctx.init(null, arrayOf(trustManager), java.security.SecureRandom())
            return ctx.socketFactory
        }
    }
}
