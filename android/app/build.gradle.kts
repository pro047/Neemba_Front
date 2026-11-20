import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Signing material lives outside the repo (see .gitignore) and key.properties
// carries the passwords, so a fresh clone has neither. Release builds refuse
// to run without it — there is deliberately no debug-key fallback. Updates are
// installed over the existing app (Obtainium from GitHub Releases), and Android
// only allows that when the signing key matches; a mismatch forces an
// uninstall, which deletes the on-device diagnostics.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasKeystore) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    namespace = "app.neemba.translation"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "app.neemba.translation"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (hasKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// Fails only when a release task is actually scheduled. Throwing inside the
// release block above would run at configuration time, which evaluates every
// build type — `flutter run` (debug) would break on any machine without the key.
gradle.taskGraph.whenReady {
    val releaseScheduled = allTasks.any {
        it.project == project && it.name.contains("Release")
    }
    if (releaseScheduled && !hasKeystore) {
        throw GradleException(
            "android/key.properties not found. Release builds must be signed with " +
                "the release key: an update signed with any other key cannot install " +
                "over the existing app, and uninstalling wipes its diagnostics."
        )
    }
}

flutter {
    source = "../.."
}
