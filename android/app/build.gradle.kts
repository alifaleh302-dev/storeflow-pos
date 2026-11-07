import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release keystore lives outside the repository and is never committed.
// When android/key.properties is absent, a release build falls back to the debug
// keys so that `flutter run --release` still works on a fresh checkout. That
// fallback is refused when -Prequire.release.signing=true is passed, which CI
// does: a build that is meant to be published must never be debug-signed by
// accident, because the mistake is invisible in the artifact.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

val hasReleaseKeystore = keystoreProperties.getProperty("storeFile") != null
val requireReleaseSigning =
    (project.findProperty("require.release.signing") as String?) == "true"

if (requireReleaseSigning && !hasReleaseKeystore) {
    throw GradleException(
        "Release signing was required (-Prequire.release.signing=true) but " +
            "android/key.properties is missing or has no storeFile. " +
            "Provide the keystore, or drop the flag to build a debug-signed " +
            "artifact for local testing.",
    )
}

android {
    namespace = "com.storeflow.storeflow_pos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.storeflow.storeflow_pos"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.create("release") {
                    storeFile = file(keystoreProperties.getProperty("storeFile"))
                    storePassword = keystoreProperties.getProperty("storePassword")
                    keyAlias = keystoreProperties.getProperty("keyAlias")
                    keyPassword = keystoreProperties.getProperty("keyPassword")
                }
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
