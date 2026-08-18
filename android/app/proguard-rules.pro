# The notification listener is instantiated by the system from the manifest name.
-keep class com.tennanova.notifications.TennaNotificationListener { *; }
# The accessibility service is also instantiated by the system from the manifest name.
-keep class com.tennanova.clipboard.TennaAccessibilityService { *; }

# OkHttp / Okio ship their own rules but these silence known warnings.
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
