import java.util.Base64

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val relayConfigPath = providers.gradleProperty("mipopupRelayConfigFile")
    .orElse(providers.environmentVariable("MIPOPUP_RELAY_CONFIG_FILE"))
    .orNull
val relayConfigFile = relayConfigPath?.let(::file)
val embeddedRelayConfigBase64 = relayConfigFile
    ?.takeIf { it.isFile }
    ?.readBytes()
    ?.let(Base64.getEncoder()::encodeToString)
    .orEmpty()

android {
    namespace = "com.mipopup.capture"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.mipopup.capture"
        minSdk = 26
        targetSdk = 36
        versionCode = 6
        versionName = "0.1.5"
        testInstrumentationRunner = "android.test.InstrumentationTestRunner"
        manifestPlaceholders["appLabel"] = "MiPopup 通知采集"
        buildConfigField("boolean", "USER_FACING", "false")
        buildConfigField("String", "EMBEDDED_RELAY_CONFIG_BASE64", "\"\"")
    }

    buildTypes {
        debug {
            versionNameSuffix = "-network-test"
        }
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        create("user") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            versionNameSuffix = "-user"
            manifestPlaceholders["appLabel"] = "MiPopup 配送同步"
            buildConfigField("boolean", "USER_FACING", "true")
            buildConfigField(
                "String",
                "EMBEDDED_RELAY_CONFIG_BASE64",
                "\"$embeddedRelayConfigBase64\""
            )
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

val validateUserRelayConfig by tasks.registering {
    doLast {
        require(relayConfigFile?.isFile == true) {
            "User APK requires -PmipopupRelayConfigFile=/path/to/client-config.json " +
                "or MIPOPUP_RELAY_CONFIG_FILE. The file must stay outside Git."
        }
        require(embeddedRelayConfigBase64.isNotEmpty()) {
            "The relay client configuration file is empty."
        }
    }
}

tasks.matching { it.name == "assembleUser" }.configureEach {
    dependsOn(validateUserRelayConfig)
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // Android's local JVM stubs do not implement JSONObject; this stays test-only.
    testImplementation("org.json:json:20240303")
}
