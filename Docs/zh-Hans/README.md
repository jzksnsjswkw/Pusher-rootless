# Pusher-rootless

[English](../../README.md)

[NoahSaso/Pusher](https://github.com/NoahSaso/Pusher) 的无根（rootless）版本。

支持 iOS 15–16（roothide 设备也支持）。内置 Bark / 飞书 / 企业微信 / Pushover /
Pushbullet / IFTTT / Pusher Receiver / Webhook 等服务，支持自定义服务、每应用覆盖、
设备 / 声音列表、通知设置条件与中文界面。

## 构建

依赖：Theos + `com.opa334.altlist`（来自 [AltList](https://github.com/opa334/AltList)）。

```bash
# rootless
THEOS_PACKAGE_SCHEME=rootless make clean package
# roothide
THEOS_PACKAGE_SCHEME=roothide make clean package
```

安装到设备（需先在 Makefile 里配置 `THEOS_DEVICE_IP` / `THEOS_DEVICE_PORT`）：

```bash
# rootless
THEOS_PACKAGE_SCHEME=rootless make clean do
# roothide
THEOS_PACKAGE_SCHEME=roothide make clean do
```

代码全部为 Swift（仅 `Sources/Hooks/*.xm` 是 Logos 钩子，因为
`%hook` / `%orig` / `%init` 没有 Swift 等价物）。新增内置服务只需两步：写好类型，
然后在 `Sources/Core/ServiceRegistry.swift` 的 `addableServices` 里加一行。

目录结构：

```
Sources/
├── Core/                 推送流水线（与 UI 无关）
│   ├── Services/         各推送服务（Bark / 飞书 / 企业微信 / …）
│   └── Runtime/          Objective-C 运行时桥接（私有 API、方法 hook）
├── Shared/               偏好存储与日志
├── Hooks/                Logos 钩子 + 桥接头文件
├── Preferences/          设置界面（含 Resources/ 下的 plist 与图片）
└── Flipswitch/           控制中心开关
```

## 文档

- [新推送服务开发文档](新推送服务开发文档.md)
- 界面文案集中在 `Preferences/Resources/zh-Hans.lproj/Localizable.strings`，
  plist 里的英文标签会在设置界面自动本地化。
