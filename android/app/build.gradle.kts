plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.tennanova"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.tennanova"
        minSdk = 33
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Every Android 13+ phone worth targeting is arm64. Keeps the sideloaded
        // APK small enough to Quick Share comfortably.
        ndk { abiFilters += "arm64-v8a" }
    }

    buildTypes {
        release {
            // Signed with the debug key on purpose: this app is sideloaded onto your
            // own phone, never published, so a release keystore would add ceremony
            // without adding safety.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.activity:activity-compose:1.9.3")

    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // WebSocket client
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Complete on-device scanner UI supplied by Play services; no CAMERA permission.
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // `play-services-base` drags in `fragment:1.0.0`, whose `FragmentActivity` never calls
    // `super.onRequestPermissionsResult`. Nothing here uses fragments, but the version on the
    // classpath is what `lintVital` reads, and it fails the release build over it. A
    // constraint raises the transitive version without adding a dependency of our own.
    constraints {
        implementation("androidx.fragment:fragment:1.8.5")
    }

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
