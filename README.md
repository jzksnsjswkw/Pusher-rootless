# Pusher-rootless

rootless version of [NoahSaso/Pusher](https://github.com/NoahSaso/Pusher)  
无根版本的 [NoahSaso/Pusher](https://github.com/NoahSaso/Pusher)

支持 iOS 15-16（roothide 设备也支持）。
内置 Bark / 飞书 / 企业微信 / Pushover / Pushbullet / IFTTT / Pusher Receiver / Webhook 等服务，支持自定义服务、每应用覆盖、设备 / 声音列表、SNS 通知条件与中文界面。

## 构建

依赖：Theos + `com.opa334.altlist`（来自 [AltList](https://github.com/opa334/AltList)）。

```bash
# rootless 设备（本项目默认形态）
make clean package THEOS_PACKAGE_SCHEME=rootless

# roothide 设备 —— 必须显式传 scheme！
# 否则 Preferences 的 AltList.framework 会因缺少 @loader_path/.jbroot rpath 而加载失败
make clean package THEOS_PACKAGE_SCHEME=roothide
```

安装到设备（需先在 Makefile 里配置 `THEOS_DEVICE_IP` / `THEOS_DEVICE_PORT`）：

```bash
make package THEOS_PACKAGE_SCHEME=rootless install
# roothide:
make package THEOS_PACKAGE_SCHEME=roothide install
```

构建时 `scripts/generate_builtin_services.sh` 会自动扫描
`Core/Services/NSP*Service.h` 里的 `PUSHER_SERVICE_*` 宏，重新生成
`Generated/BuiltinServices.generated.h`，所以**新增服务不需要手工维护 import 列表和名单**。

## 文档

- [新推送服务开发文档](Docs/新推送服务开发文档.md)：如何添加一个内置推送服务，包含 Bark 最小样板、企业微信进阶样板、Shared Store / 本地化 / Device-Sound 列表等架构说明。
- 界面文案集中在 `Preferences/Resources/zh-Hans.lproj/Localizable.strings`，plist 里的英文标签会在设置界面自动本地化。

有汉化需求的 fork 一份自己做，勿提 PR :)
