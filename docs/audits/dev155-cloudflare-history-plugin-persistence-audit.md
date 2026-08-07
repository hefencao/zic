# dev.155 Cloudflare、历史与插件持久化审计

## 唯一基线

`zic_v0.31.0-dev.154_cloudflare-browser-stable-completion.zip`。

## 根因

- Cloudflare验证 WebView被强制设置为插件静态 UA；clearance来自真实 WebView执行环境，而后续 HTTP请求仍可能声明与实际浏览器/设备不一致的 UA。
- `_openSourceComic` 已持 raw comic route lock；首次详情持久化后第二次进入命中 local分支并再次调用带锁 `_openComicDetails`，同 identity嵌套锁失败后静默 return。
- Home远程历史封面只有 active source存在时才调用 artwork gateway；source缺失时 HTTP URL错误落入本地文件读取。
- 插件 `installed.json` 任一记录解析失败会让旧实现整个 manifest失效；主 manifest缺失时也不会尝试 `.invalid/.part`恢复。

## 修复所有权

- WebView UA/Cookie handoff：network bridge + Mihon runtime adapter。
- route lock：App source composition，不改变 Catalog identity。
- history artwork：现有 `ComicSourceResourceGateway`，不增加缓存。
- plugin manifest：plugin_host_bridge持久化 owner。
