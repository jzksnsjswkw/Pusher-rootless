*beta3 新增 Server酱³，移除 PushPlus*

**仍然不兼容旧版配置，升级后所有服务需要重新配置，做好数据备份**

本版本为预览版，可能有 bug 或功能失效，欢迎提 issue 和 PR

## 新增

- 新增 Server酱³，与 Server酱·Turbo 是两个独立服务，账号密钥不通用
- Server酱³ 和 Bark 一样附有使用指南

## 修改

- 移除 PushPlus，其 API 已改为收费
- 应用黑白名单新增「默认」选项，跟随全局设置；选默认时不显示应用列表
- 实例的黑白名单会覆盖全局设置，而不是叠加

## 修复

- 只有标题没有正文的通知，在 Pushover、Pushbullet、WxPusher、Server酱³ 上会被拒绝，现在用标题补齐
- 实例配置里的 id 字段（如 Bark 的推送 ID）会被实例自己的 ID 覆盖
- WxPusher 推送时标题和正文内容重复

## 已知问题

- 示例快捷指令的签名将于 2027 年 11 月到期，后续需联网重新签名。服务已内置 HubSign 续签，但中国大陆境内有 Cloudflare 防火墙，有新方法欢迎 PR
