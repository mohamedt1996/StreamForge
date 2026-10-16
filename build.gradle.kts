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

    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "armeabi-v7a", "x86_64")
            isUniversalApk = true
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        jniLibs { useLegacyPackaging = true }
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
