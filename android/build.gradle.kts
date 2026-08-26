allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// NOTE (M2.9): a `plugins { id("com.google.gms.google-services") ... apply false }`
// block used to sit here. It was dead — nothing in this build ever applied it,
// and there is no google-services.json — but it still made Gradle resolve the
// Google Services plugin marker on every configuration, and it is precisely
// the kind of leftover that makes a later "just add Firebase" change look
// pre-approved. Locked-in product requirement 12 forbids any Google Play
// Services dependency, so it is gone. `test/no_gms_dependency_audit_test.dart`
// now fails if it (or anything like it) comes back.
