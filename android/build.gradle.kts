allprojects {
    repositories {
        google()
        mavenCentral()
        // 个推（GeTui）SDK Maven 仓库：getuiflut Flutter 插件的原生依赖
        // com.getui:gtsdk / gtc 从此仓库拉取。
        maven { url = uri("https://mvn.getui.com/nexus/content/repositories/releases/") }
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
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
