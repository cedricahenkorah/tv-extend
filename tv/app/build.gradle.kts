plugins {
    id("com.android.application")
}

android {
    namespace = "local.tvextend.tv"
    compileSdk = 36

    defaultConfig {
        applicationId = "local.tvextend.tv"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Sideloaded personal app: sign release builds with the debug key.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}


// No dependencies: plain Android framework APIs only (MediaCodec, sockets, Views).
