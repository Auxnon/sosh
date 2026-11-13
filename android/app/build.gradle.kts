plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release signing from the environment (the release workflow decodes the
// keystore from secrets): SOSH_KEYSTORE, SOSH_KEYSTORE_PASSWORD, SOSH_KEY_ALIAS,
// SOSH_KEY_PASSWORD. Without them, release builds use the debug key, which is
// fine for trying one out but can't update an install signed by another key.
val releaseKeystore = System.getenv("SOSH_KEYSTORE")?.takeIf { it.isNotBlank() && file(it).exists() }

android {
    namespace = "app.sosh"
    compileSdk = 37

    defaultConfig {
        manifestPlaceholders["cleartext"] = "false"
        applicationId = "app.sosh"
        minSdk = 29
        targetSdk = 36
        // CI sets these from the tag (v1.2.3) and the run number
        versionCode = System.getenv("SOSH_VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("SOSH_VERSION_NAME") ?: "0.1.0"
        // The server the app talks to until it's changed on the sign-in
        // screen: the real one in release builds (below).
        buildConfigField("String", "DEFAULT_SERVER", "\"https://sosh.makeavoy.com\"")
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("SOSH_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("SOSH_KEY_ALIAS")
                keyPassword = System.getenv("SOSH_KEY_PASSWORD") ?: System.getenv("SOSH_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            // its own app beside the released one (which has another key and
            // a higher version code, so it can't be installed over)
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            manifestPlaceholders["cleartext"] = "true"
            // the host machine, from the Android emulator
            buildConfigField("String", "DEFAULT_SERVER", "\"http://10.0.2.2:4000\"")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // pictures in chat: Coil, with its gif module for animated GIF and WebP
    // (Android's AnimatedImageDecoder, API 28+)
    implementation("io.coil-kt.coil3:coil-compose:3.3.0")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.3.0")
    implementation("io.coil-kt.coil3:coil-gif:3.3.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    // the real org.json (Android's is stubbed off-device)
    testImplementation("org.json:json:20250517")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
}
