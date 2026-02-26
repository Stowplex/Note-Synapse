# Building Note Synapse

This document provides instructions for compiling and building the Note Synapse application from source. Be sure to carefully follow the instructions based on your target platform.

## Prerequisites

Before building the application, you must install the following dependencies. Please refer to their official documentation for detailed installation steps on your specific operating system:

1. **Install Flutter SDK**: [Official Flutter Installation Guide](https://docs.flutter.dev/get-started/install)
2. **Install Rust**: [Official Rust Installation Guide (rustup)](https://www.rust-lang.org/tools/install)

Once the prerequisites are installed, verify your environment by running:
```bash
flutter doctor
rustc --version
```

## Cloning the Repository

The Note Synapse repository contains submodules that must be initialized when cloning:

```bash
git clone --recursive https://github.com/kkspeed/Note-Synapse.git
cd Note-Synapse
```

## Building for Android

To build the application for Android, you must first install the Android SDK and command-line tools.

1. **Install Android Studio & SDK**: [Android Studio User Guide](https://developer.android.com/studio)
2. Open Android Studio, navigate to the SDK Manager, and ensure the latest SDK Platforms and Build Tools are installed.
3. Accept the Android licenses via the command line:
   ```bash
   flutter doctor --android-licenses
   ```

To build a debug APK, run the following command from the root of the project:
```bash
flutter build apk --debug
```
The compiled APK will be located in `build/app/outputs/flutter-apk/app-debug.apk`.

## Building for iOS

Building for iOS requires a macOS environment with Xcode installed.

1. **Install Xcode**: Download from the Mac App Store.
2. Install the Command Line Tools:
   ```bash
   xcode-select --install
   ```
3. Accept the Xcode license agreements:
   ```bash
   sudo xcodebuild -license accept
   ```

To prepare the iOS build, run the following command:
```bash
flutter build ios --debug
```

Once the Flutter build process completes, open the generated Xcode workspace to sign and run the application on a device or simulator:
```bash
open ios/Runner.xcworkspace
```

Continue the build, signing, and deployment process directly within Xcode.
