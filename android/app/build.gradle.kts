import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose.compiler)
    alias(libs.plugins.kotlin.serialization)
}

java { toolchain { languageVersion = JavaLanguageVersion.of(17) } }

// Version comes from CI (run number) so every release upgrades in place.
val buildNumber = (System.getenv("BUILD_NUMBER") ?: "1").toInt()

android {
    namespace = "com.mohamedt.streamforge"
    compileSdk = 37
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "com.mohamedt.streamforge"
        minSdk = 26
        targetSdk = 37
        versionCode = buildNumber
        versionName = "1.0.$buildNumber"
    }

    // Two separate apps from one codebase:
    //  - "tv":     Android TV / Google TV (Chromecast with Google TV, Shield, TV boxes). Always the
    //              10-foot remote interface, shows in the TV launcher.
    //  - "mobile": phones and tablets. Always the touch interface (phone or tablet layout).
    // Same application id and signing key, so either one updates an existing install in place.
    flavorDimensions += "device"
    productFlavors {
        create("mobile") {
            dimension = "device"
            buildConfigField("boolean", "TV_BUILD", "false")
        }
        create("tv") {
            dimension = "device"
            buildConfigField("boolean", "TV_BUILD", "true")
        }
    }

    signingConfigs {
        create("release") {
            // A real keystore can be supplied via CI secrets; otherwise the repo's sideload key
            // keeps signatures stable so updates install over older builds.
            val ksPath = System.getenv("ANDROID_KEYSTORE_PATH") ?: "streamforge-release.jks"
            storeFile = file(ksPath)
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: "streamforge-sideload"
            keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "streamforge"
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: "streamforge-sideload"
        }
    }

    buildTypes {
        named("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("release")
        }
        named("debug") {
            applicationIdSuffix = ".debug"
        }
    }

    // ARM only: every phone, tablet and TV box we target is ARM (Intel Chromebooks run ARM apps
    // through translation). Dropping the x86 / x86_64 copies of mpv/ffmpeg roughly halves the
    // universal APK. Per-ABI APKs: armeabi-v7a is the one for the Chromecast with Google TV
    // (its Android is 32-bit), arm64-v8a for 64-bit phones, tablets and newer TV devices.
    splits {
        abi {
            isEnable = true
            reset()
            include("armeabi-v7a", "arm64-v8a")
            isUniversalApk = true
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            excludes += setOf("lib/x86/**", "lib/x86_64/**")
        }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
}

dependencies {
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.runtime)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons)
    implementation(libs.androidx.core)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.libmpv)
    implementation(libs.okhttp)

    // TorrServer engine (gomobile AAR built in CI). Loaded by reflection, so the app also
    // builds without it (remote TorrServer only).
    val torrserver = file("libs/torrserverkit.aar")
    if (torrserver.exists()) implementation(files(torrserver))
}
