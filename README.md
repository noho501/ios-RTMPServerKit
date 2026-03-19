# ios-RTMPServerKit

## Cấu trúc dự án

- `Sources/RTMPServerKit`: SDK RTMPServerKit (Swift Package)
- `Examples/RTMPServerExample`: iOS app example dùng trực tiếp package local

## Chạy app example

1. Mở file [RTMPServerExample.xcodeproj](file:///Users/katchy/Documents/ios-RTMPServerKit/Examples/RTMPServerExample/RTMPServerExample.xcodeproj)
2. Chọn signing team cho target `RTMPServerExample`
3. Run trên iPhone/iPad hoặc iOS Simulator
4. App sẽ chạy RTMP server cổng `1935` và hiển thị URL `rtmp://<ip>/live`
