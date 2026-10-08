plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "com.openweb.pbx"
    compileSdk = 35
    testBuildType = if(providers.gradleProperty("openwebInstrumentRelease").orNull=="true") "release" else "debug"
    defaultConfig {
        applicationId = "com.openweb.pbx"
        minSdk = 28
        targetSdk = 35
        versionCode = 103
        versionName = "1.0.3"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    signingConfigs {
        create("release") {
            val path = System.getenv("OPENWEB_ANDROID_KEYSTORE")
            if (path != null) {
                storeFile = file(path)
                storePassword = System.getenv("OPENWEB_ANDROID_STORE_PASSWORD")
                keyAlias = "openwebpbx"
                keyPassword = System.getenv("OPENWEB_ANDROID_KEY_PASSWORD")
            }
        }
    }
    buildTypes { debug { ndk { abiFilters += (providers.gradleProperty("openwebTestAbi").orNull?.let { listOf(it) } ?: listOf("arm64-v8a", "armeabi-v7a", "x86_64")) } }; release { ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }; isMinifyEnabled = false; signingConfig = signingConfigs.getByName("release") } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    packaging { jniLibs.useLegacyPackaging = true; resources.excludes += setOf("META-INF/DEPENDENCIES") }
    buildFeatures { buildConfig = true }
}
dependencies {
    implementation("org.linphone:linphone-sdk-android:5.5.23")
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}

tasks.register("writeRuntimeInventory") {
    doLast {
        val items = configurations.getByName("releaseRuntimeClasspath").resolvedConfiguration.resolvedArtifacts
            .map { "${it.moduleVersion.id.group}:${it.name}:${it.moduleVersion.id.version}" }.distinct().sorted()
        layout.buildDirectory.file("runtime-dependencies.txt").get().asFile.writeText(items.joinToString("\n")+"\n")
    }
}
