import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.bear_tv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.bear_tv"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 固定 release 签名（android/key.properties，gitignored；CI 由 GitHub
        // Secrets 生成）。debug 回退只用于本地开发：CI 的 debug keystore 是
        // 每个 runner 随机生成的，用它签的版本无法覆盖安装（签名必须一致）。
        create("release") {
            val props = Properties()
            val propsFile = rootProject.file("key.properties")
            if (propsFile.exists()) propsFile.inputStream().use { props.load(it) }
            fun p(key: String, env: String) = props.getProperty(key) ?: System.getenv(env)
            val storePath = p("storeFile", "RELEASE_STORE_FILE")
            if (!storePath.isNullOrEmpty()) {
                storeFile = rootProject.file(storePath)
                storePassword = p("storePassword", "RELEASE_STORE_PASSWORD")
                keyAlias = p("keyAlias", "RELEASE_KEY_ALIAS")
                keyPassword = p("keyPassword", "RELEASE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            val releaseConfig = signingConfigs.findByName("release")
            signingConfig = if (releaseConfig?.storeFile != null) {
                releaseConfig
            } else {
                // Local dev only — CI must always have key.properties (workflow fails otherwise).
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // FileProvider (update APK install) — see MainActivity / file_paths.xml.
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
