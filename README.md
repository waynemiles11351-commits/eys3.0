# GGD Identity Overlay v6

Target: com.seayoo.ggd / 1.1.13 / arm64 / iOS 18+.

This revision fixes the v5 floating-window lifecycle. The overlay uses a dedicated UIWindow attached to the active UIWindowScene, retains that window strongly, retries scene startup without blocking the main thread, and passes non-control touches through to the game.

The runtime scan remains diagnostic-first. It is started only after tapping “开始读取”, and the scan executes on the main thread to reduce Unity/IL2CPP thread-safety risk.

GitHub Actions builds the dylib with Apple clang on macos-latest.
