# StoreFlow POS release shrinking rules.
#
# The application has no reflection-driven Java code of its own; the rules below
# exist only to protect the plugins that do.

# flutter_secure_storage reaches EncryptedSharedPreferences and the Android
# keystore through reflection.
-keep class androidx.security.crypto.** { *; }
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# Drift's native SQLite is loaded through JNI. The Java side only holds the
# library name, but R8 must not rename the loader.
-keep class com.tekartik.sqflite.** { *; }
-keepclasseswithmembers class * {
    native <methods>;
}

# Keep annotations used by plugins at runtime.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# Flutter's embedding entry points.
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**
