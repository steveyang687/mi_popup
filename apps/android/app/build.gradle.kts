plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.mipopup.capture"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.mipopup.capture"
        minSdk = 26
        targetSdk = 36
        versionCode = 4
        versionName = "0.1.3-lock-screen-sync"
        testInstrumentationRunner = "android.test.InstrumentationTestRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
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
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // Android's local JVM stubs do not implement JSONObject; this stays test-only.
    testImplementation("org.json:json:20240303")
}
