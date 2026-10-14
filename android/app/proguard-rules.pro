# libmpv calls back into these from JNI.
-keep class dev.jdtech.mpv.** { *; }
# gomobile bindings (TorrServer) are loaded by reflection.
-keep class torrserverkit.** { *; }
-keep class go.** { *; }
# kotlinx.serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class com.mohamedt.streamforge.** {
    *** Companion;
}
-keepclasseswithmembers class com.mohamedt.streamforge.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.mohamedt.streamforge.**$$serializer { *; }
-dontwarn org.slf4j.**
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-ignorewarnings
