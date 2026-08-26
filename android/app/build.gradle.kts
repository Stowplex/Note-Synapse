import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// ---------------------------------------------------------------------------
// Google Drive sync OAuth redirect scheme (M2.9).
//
// These are the "reversed client ID" private-use URL schemes the app
// registers with Android so Google's OAuth redirect can come back to us.
// They MUST stay in sync with `lib/services/sync/google_drive_client_config.dart`
// (`releaseClientId` / `debugClientId`, reversed) —
// `test/google_drive_client_id_drift_test.dart` parses this file and fails
// the build's test suite if the two ever disagree.
//
// Both values come from Google OAuth clients of the **iOS** application type,
// not Android — only an iOS-type client gets a reversed-client-ID redirect
// (an Android-type client's is `<package.name>:/oauth2redirect`), and Google
// has restricted custom URI schemes for new Android clients. See the header
// of google_drive_client_config.dart for the full reasoning and links.
//
// Debug and release deliberately register DIFFERENT schemes. `debug` carries
// `applicationIdSuffix = ".debug"`, so both variants can be installed at once;
// if they registered the same scheme, Android would let either app claim the
// other's OAuth redirect (authorization code included). Two clients exist
// solely to yield two distinct schemes — NOT because a client is bound to an
// Android package name, which is not true of iOS-type clients. Do not
// "simplify" these into one value.
//
// `profile` has no applicationIdSuffix and therefore shares the release
// package name, so it takes the release scheme via `defaultConfig` below.
// That default also guarantees every present and future build type has SOME
// substitution for `${googleReversedClientId}` — without it the manifest
// merger fails outright on any variant we forgot to name here.
// ---------------------------------------------------------------------------
// PLACEHOLDER: no release-variant Google OAuth client exists yet. The
// `438894533578-…` client turned out to be registered against the `.debug`
// package, so it moved to the debug value below. See `releaseClientId` in
// google_drive_client_config.dart for how to create a release one.
val googleReversedClientIdRelease =
    "com.googleusercontent.apps.438894533578-g0tpgg76soku9srh76hj21p14to3kc4c"
val googleReversedClientIdDebug =
    "com.googleusercontent.apps.438894533578-i9ecrp6g518tdenpq5fo4dkv90ce2rig"

android {
    namespace = "com.github.kkspeed.note_synapse.note_synapse"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    defaultConfig {
        applicationId = "com.github.kkspeed.note_synapse.note_synapse"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Default substitution for AndroidManifest.xml's
        // `${googleReversedClientId}` — covers `profile` (release package
        // name, hence release scheme) and any build type not named below.
        manifestPlaceholders["googleReversedClientId"] = googleReversedClientIdRelease
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            manifestPlaceholders["googleReversedClientId"] = googleReversedClientIdDebug
        }

        release {
            manifestPlaceholders["googleReversedClientId"] = googleReversedClientIdRelease
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    // google_mlkit_text_recognition declares the non-Latin models compileOnly;
    // the Chinese script recognizer (search OCR, AttachmentOcrExtractor)
    // needs the app to link the model implementation or the plugin throws
    // NoClassDefFoundError at runtime. Version must match the plugin's
    // compileOnly declaration (text-recognition-chinese:16.0.1).
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

flutter {
    source = "../.."
}
