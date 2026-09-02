# BodyWeight（体重趋势）

一款本地优先、可通过 iCloud 同步的 iOS 体重记录 App。

## 已实现

- 手动输入体重与日期
- 中文语音录入，例如“今天的体重是 72.5 公斤”
- 相机拍照或从相册选择，通过 Vision OCR 识别体重秤数字
- 自动识别今天、昨天、前天、`2026年8月30日`、`8月30日` 等日期
- 支持 kg / 公斤 / 千克 / 斤 / lb / 磅，并统一换算为 kg
- Swift Charts 体重趋势曲线、近 7 天变化和历史记录
- SwiftData 本地缓存 + 私有服务器双向同步，离线仍可记录
- Bearer Token 存入 iOS Keychain，不写入代码或公开仓库

## 数据存储

App 始终在设备上保留 SwiftData 本地副本，并可与个人服务器同步：

- API 地址：`https://8.138.40.226/body-weight-api/`
- 服务端数据库：`/var/lib/body-weight-api/body-weight.sqlite3`
- 每日备份：`/var/backups/body-weight-api`，保留 30 份
- 保存、删除、启动 App 时自动同步，也可以在主页下拉刷新
- 删除使用同步 tombstone，避免其他设备恢复已删除记录

服务端使用 Python 标准库、SQLite、systemd 和 Nginx，不需要 Docker。具体部署文件见 `Server/`。

## 运行

1. 使用 Xcode 15 或更高版本打开 `BodyWeight.xcodeproj`。
2. 在 Target → Signing & Capabilities 选择你的 Apple Developer Team，并启用自动签名。
3. 选择 iOS 17+ 模拟器或真机运行。拍照和语音功能需要真机及对应系统权限。

首次安装后点击主页右上角云朵，粘贴服务器访问令牌并选择“保存并立即同步”。令牌只保存在本机 Keychain。

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

OCR 和语音识别均调用 Apple 系统框架。体重数据仅发送到配置的个人服务器，并通过 HTTPS 加密传输。
