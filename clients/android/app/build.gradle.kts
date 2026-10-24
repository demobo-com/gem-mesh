import java.util.Properties

buildscript {
    repositories { mavenCentral() }
    dependencies { classpath("org.yaml:snakeyaml:2.3") }
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// The repo's policy/ (docs/ANDROID.md: the app must not hard-code rules or tiers). In the repo it is two levels up;
// the 5090 build sandbox keeps it next to the source.
val policyDir: File = listOf("../../policy", "../policy").map { rootDir.resolve(it).normalize() }
    .firstOrNull { it.resolve("tiers.yaml").exists() } ?: error("policy/ not found next to clients/android")
val policyAssets = layout.buildDirectory.dir("generated/policy-assets")

// The YAML files become JSON in the app's assets, so the app reads them with org.json and needs no YAML parser.
val syncPolicy by tasks.registering {
    inputs.dir(policyDir)
    policyDir.resolveSibling("demo/files").takeIf { it.isDirectory }?.let { inputs.dir(it) }
    outputs.dir(policyAssets)
    doLast {
        val out = policyAssets.get().asFile.resolve("policy")
        out.deleteRecursively()
        out.mkdirs()
        for (name in listOf("tiers", "rules", "models")) {
            val data = org.yaml.snakeyaml.Yaml().load<Any>(policyDir.resolve("$name.yaml").readText())
            out.resolve("$name.json").writeText(groovy.json.JsonOutput.toJson(data))
        }
        policyDir.resolve("classifier.txt").copyTo(out.resolve("classifier.txt"), overwrite = true)
        // docs/ANDROID.md §2: the demo files (photos with real EXIF GPS, PDFs, a lease), offered in Settings.
        val demo = policyAssets.get().asFile.resolve("demo")
        demo.deleteRecursively()
        policyDir.resolveSibling("demo/files").takeIf { it.isDirectory }?.copyRecursively(demo, overwrite = true)
    }
}

android {
    namespace = "com.demobo.mesh"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.demobo.mesh"
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        // arm64 for phones, x86_64 for the emulator test bench on the 5090.
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    // Release signing (docs/ANDROID.md M7): keystore.properties next to settings.gradle.kts, never in git, with
    // storeFile, storePassword, keyAlias, keyPassword. Without it a release build is unsigned.
    val keystore = rootProject.file("keystore.properties").takeIf { it.exists() }?.let { f ->
        Properties().apply { f.inputStream().use { load(it) } }
    }
    if (keystore != null) {
        signingConfigs.create("release") {
            storeFile = rootProject.file(keystore.getProperty("storeFile"))
            storePassword = keystore.getProperty("storePassword")
            keyAlias = keystore.getProperty("keyAlias")
            keyPassword = keystore.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            if (keystore != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    sourceSets["main"].assets.srcDir(policyAssets)
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions { unitTests.isReturnDefaultValues = true }
}

tasks.named("preBuild") { dependsOn(syncPolicy) }
tasks.withType<Test>().configureEach {
    dependsOn(syncPolicy)
    systemProperty("policy.dir", policyAssets.get().asFile.resolve("policy").path)
    systemProperty("golden.dir", policyDir.resolve("golden").path)
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.08.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.2")
    implementation("androidx.datastore:datastore-preferences:1.1.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.1")
    // The memory authority's HTTP endpoint on :9401 (docs/PROTOCOL.md §4).
    implementation("org.nanohttpd:nanohttpd:2.3.1")
    // Pairing QR scanner; ZXing needs no Google Play services (phones sold in China have none).
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    // Workspace files: EXIF location (read, keep, remove) and PDFs (text, pages, stamps).
    implementation("androidx.exifinterface:exifinterface:1.4.1")
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    testImplementation("junit:junit:4.13.2")
    // The real org.json for JVM tests (android.jar only has stubs).
    testImplementation("org.json:json:20240303")
}
