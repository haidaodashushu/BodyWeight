# BodyWeight（体重趋势）

一款本地优先、可通过 iCloud 同步的 iOS 体重记录 App。

## 已实现

- 手动输入体重与日期
- 中文语音录入，例如“今天的体重是 72.5 公斤”
- 相机拍照或从相册选择，通过 Vision OCR 识别体重秤数字
- 自动识别今天、昨天、前天、`2026年8月30日`、`8月30日` 等日期
- 支持 kg / 公斤 / 千克 / 斤 / lb / 磅，并统一换算为 kg
- Swift Charts 体重趋势曲线、近 7 天变化和历史记录
- SwiftData 本地持久化；付费开发者团队可按下方说明启用用户私有 CloudKit 同步

## 为什么采用 iCloud + 本地回落

体重属于敏感健康数据。首版使用 Apple 原生的 SwiftData/CloudKit 有几个好处：

- 数据保存在用户自己的 iCloud 私有数据库中，不需要维护账号系统和服务器
- 离线可用，网络恢复后由系统同步
- App 无需持有用户的体重数据
- 云能力未配置或暂时不可用时仍可本地保存

如果以后要支持 Android 或 Web，再把持久化层抽象到 Supabase / Firebase 等跨平台后端即可。当前版本不建议为了一个人的首版记录功能先维护独立服务器。

## 运行

1. 使用 Xcode 15 或更高版本打开 `BodyWeight.xcodeproj`。
2. 在 Target → Signing & Capabilities 选择你的 Apple Developer Team，并启用自动签名。
3. 选择 iOS 17+ 模拟器或真机运行。拍照和语音功能需要真机及对应系统权限。

默认配置兼容免费的 Personal Team，数据保存在设备本地。付费开发者团队如需启用 iCloud：

1. 在 Signing & Capabilities 中添加 iCloud / CloudKit，并选择容器 `iCloud.com.haidaodashushu.BodyWeight`。
2. 将 `BodyWeight/BodyWeight.entitlements` 配置为 Target 的 Code Signing Entitlements。
3. 在 Swift Active Compilation Conditions 中添加 `ICLOUD_SYNC`。

## 测试

文本和日期解析逻辑可在没有完整 Xcode 的环境中验证：

```bash
swift run ParserVerification
```

相机、语音、CloudKit 和完整 UI 仍需用 Xcode/真机验证。

## 技术栈

- SwiftUI / SwiftData（iOS 17+）
- Charts
- Vision
- Speech / AVFoundation
- CloudKit

## 隐私

OCR 和语音识别均调用 Apple 系统框架。体重记录不上传到本项目自建服务；启用 iCloud 时由用户的 Apple 账号负责私有数据同步。
