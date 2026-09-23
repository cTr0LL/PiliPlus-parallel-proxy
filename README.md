# PiliPlus + 多线程 CDN 代理（Fork）

**目前本人正在使用测试，不一定真的管用**

本项目是 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 的一个 fork，
把视频请求拆成多个并发的字节范围（byte-range）请求，而不是用单条连接下载，
以改善海外访问哔哩哔哩 CDN 时的播放体验。

上游原始 README 完整保留在下方，未作改动。

## 要解决的问题

在海外B 站播放卡顿通常有两个**互相独立**的原因，需要分别处理：

1. **单条连接跑不满带宽。** CDN 的限速是按连接而非按客户端做的，
   所以一条连接往往只能用掉可用带宽的一小部分。
2. **冷门视频没有被就近的边缘节点缓存。** B 站的缓存是分层的，
   未命中边缘时需要回源拉取，这一点再怎么加并发也解决不了。

思路来自 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)，[原B站视频链接](https://www.bilibili.com/video/BV1Teec6BE3s/)
一个同时处理这两件事的浏览器扩展。本 fork 把同样的做法搬到了 Android 上。

## 实现方式

应用内启动一个仅监听本地回环地址的 HTTP 服务，对每条 DASH 轨道做镜像：
用多个并发的字节范围请求取回数据，再按顺序重新拼成一条普通的、支持 Range 的流。
libmpv 看到的就是一个普通的文件服务器，播放器侧不需要任何改动。

- **并行分段下载 + 慢启动**：先用少量连接把冷资源“焐热”，
  而不是一上来就并发打满——要不然会换来 503。
- **CDN 节点池**：把签名 URL 的主机名改写到 B 站的各个镜像（优先国内节点），
  并把各分段分散到节点池上。
- **按节点记录健康度**，跨视频共享并带指数退避，
  这样“某个节点连不上”只需要学习一次，而不是每次播放都重新试一次。
- **对冲请求（hedged request）**：队首分段一旦明显落后，
  就在另一个节点上再发一份相同请求，谁先返回用谁。
  因为交付必须严格按序，单个慢节点会拖住整条流。
- **断点续传**：连接中断后从断点继续，而不是把整个分段重下。
- **运行数据记录**：每次播放写一行 JSON 到应用外部存储，
  事后不接数据线也能回溯真实使用情况。

整套机制是**失败即退化**的：代理起不来、注册失败或任何一步出错，
都会回退到原始直连 URL——最坏情况就是退回成原来的单连接播放。

## 实测数据

在某条真实线路上，针对**冷资源**（边缘未缓存），
取同一文件的两段互不重叠的区间对比，避免其中一次预热了另一次：

|              |             |
| ------------ | ----------- |
| 直连，单连接 | 0.35 MiB/s  |
| 经由本代理   | 1.95 MiB/s  |
|              | **5.59 倍** |

该码率下直连根本撑不住播放。而对**已缓存的热资源**，
本代理反而比单连接更慢——多出来的握手开销大于收益。
这正是预期中的形态：它在真正卡顿的场景里起作用，
在本来就流畅的场景里则应当是无感的。

手机端的实际吞吐**尚未量化**，目前的工作重点是让它在手机上稳定可用。
完整的测量过程与每一项调参的依据见 `tool/parallel_proxy/README.md`。

## 相对上游的改动

| 路径                                                       | 说明                                   |
| ---------------------------------------------------------- | -------------------------------------- |
| `lib/plugin/parallel_proxy/`                               | 代理本体、接入层、运行数据记录（新增） |
| `lib/pages/video/controller.dart`                          | 四处 DASH 播放入口改为走代理           |
| `lib/main.dart`                                            | 启动代理                               |
| `android/app/src/main/res/xml/network_security_config.xml` | 仅对 127.0.0.1 放行明文（新增）        |
| `android/app/build.gradle.kts`                             | `compileSdkMinor = 0`                  |
| `android/gradle.properties`                                | `kotlin.incremental=false`             |
| `tool/parallel_proxy/`                                     | 测试与测量工具（新增）                 |
| `tool/patch_flutter_android.ps1`                           | 应用 Flutter SDK 补丁（新增）          |

## 构建

PiliPlus 需要打过补丁的 Flutter SDK。上游的 `lib/scripts/patch.ps1` 是给 CI 用的，
它会**改写你的全局 git 身份**；本 fork 提供了一个只做打补丁、且可回滚的替代脚本：

```
powershell -ExecutionPolicy Bypass -File .\tool\patch_flutter_android.ps1
powershell -ExecutionPolicy Bypass -File .\tool\patch_flutter_android.ps1 -Revert
```

之后照常 `flutter build apk` 即可。Windows 上请把 `PUB_CACHE` 设到较短的路径，
例如 `C:\pubcache`：默认路径太长，层级较深的 git 依赖会因为 260 字符路径上限
被悄悄截断，而 `pub get` 仍然会报成功。

## 测试

```
dart run tool/parallel_proxy/selftest.dart      # 代理行为，离线
dart run tool/parallel_proxy/resume_probe.dart  # 断线续传
flutter test test/plugin/parallel_proxy_test.dart
```

## 许可与致谢

沿用 PiliPlus 的 GPL v3。应用本身的全部功劳归
[bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)；
加速思路来自
[MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)。

下方的徽章与链接均属于上游项目，指向的也是上游仓库。

---

# PiliPlus（上游原始 README）

<div align="center">
    <img width="200" height="200" src="assets/images/logo/logo.png">
</div>

<div align="center">
    <h1>PiliPlus</h1>
<div align="center">
    
![GitHub repo size](https://img.shields.io/github/repo-size/bggRGjQaUbCoE/PiliPlus) 
![GitHub Repo stars](https://img.shields.io/github/stars/bggRGjQaUbCoE/PiliPlus) 
![GitHub all releases](https://img.shields.io/github/downloads/bggRGjQaUbCoE/PiliPlus/total) 
</div>
    <p>使用Flutter开发的BiliBili第三方客户端</p>
    
<img src="assets/screenshots/510shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/174shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/850shots_so.png" width="32%" alt="home" />
<br/>
<img src="assets/screenshots/main_screen.png" width="96%" alt="home" />
<br/>
</div>

<br/>

## 适配平台

- [x] Android
- [x] iOS
- [x] Pad
- [x] Windows
- [x] Linux

[![Packaging status](https://repology.org/badge/vertical-allrepos/piliplus.svg)](https://repology.org/project/piliplus/versions)

## refactor

- [ ] gRPC [wip]
- [x] 用户界面
- [x] 其他

## feat

- [x] 编辑动态
- [x] DLNA 投屏
- [x] 离线缓存/播放
- [x] 移动端支持点击弹幕悬停，点赞、复制、举报 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 播放音频
- [x] 跳过番剧片头/片尾
- [x] 安卓端 `loudnorm` 适配 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] Win/Mac 支持极验、短信登录 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 视频截取动图 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] AI 原声翻译
- [x] SuperChat
- [x] 播放课堂视频
- [x] 发起投票
- [x] 发布动态/评论支持`富文本编辑`/`表情显示`/`@用户`
- [x] 修改消息设置
- [x] 修改聊天设置
- [x] 展示折叠消息
- [x] 查看用户图文
- [x] 动态话题
- [x] 直播分区
- [x] 分享`视频`/`番剧`/`动态`/`专栏`/`直播`至消息
- [x] 创建/修改/删除关注分组
- [x] 移除粉丝
- [x] 直播弹幕发送表情
- [x] 收藏夹排序
- [x] 稍后再看 ~~`未看`~~ / `未看完` / ~~`已看完`~~ 分类
- [x] WebDAV 备份/恢复设置
- [x] 保存评论/动态
- [x] 高级弹幕 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 取消/置顶评论
- [x] 记笔记
- [x] 多账号支持 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 屏蔽带货动态/评论
- [x] 互动视频
- [x] 发评/动态反诈
- [x] 高能进度条
- [x] 滑动跳转预览视频缩略图
- [x] Live Photo
- [x] 复制/移动/排序收藏夹/稍后再看视频
- [x] 超分辨率
- [x] 合并弹幕
- [x] 会员彩色弹幕
- [x] 播放全部/继续播放/倒序播放
- [x] Cookie登录
- [x] 显示视频分段信息
- [x] 调节字幕大小
- [x] 调节全屏弹幕大小
- [x] 收藏夹/稍后再看多选删除
- [x] 搜索用户动态
- [x] 直播弹幕
- [x] 修改头像/用户名/签名/性别/生日
- [x] 创建/编辑/删除收藏夹
- [x] 评论楼中楼查看对话
- [x] 评论楼中楼定位点击查看的评论
- [x] 评论楼中楼按热度/时间排序
- [x] 评论点踩
- [x] 私信发图
- [x] 投币动画
- [x] 取消/追番，更新追番状态
- [x] 取消/订阅合集
- [x] SponsorBlock
- [x] 显示视频完整合集
- [x] 三连动画
- [x] 番剧三连
- [x] 带图评论
- [x] 视频TAG
- [x] 筛选搜索
- [x] 转发动态
- [x] 合集图片
- [x] 删除/置顶/撤回私信
- [x] 举报用户/评论/视频/动态
- [x] 删除/发布/置顶文本/图片动态
- [x] 其他

## opt

- [x] 专栏界面
- [x] 私信界面
- [x] 收藏面板
- [x] PIP
- [x] 视频封面
- [x] 回复界面
- [x] 系统通知
- [x] 评论显示
- [x] 亮度调节
- [x] 视频播放
- [x] 视频staff
- [x] 防止bottomsheet遮挡全屏视频
- [x] 其他

## fix

- [x] 番剧分集点赞/投币/收藏
- [x] bugs

<br/>

## 功能

- [x] 推荐视频列表(app端)
- [x] 最热视频列表
- [x] 热门直播
- [x] 番剧列表
- [x] 屏蔽黑名单内用户视频
- [x] 无痕模式（播放视为未登录）
- [x] 游客模式（推荐视为未登录）

- [x] 用户相关
  - [x] 粉丝、关注用户、拉黑用户查看
  - [x] 用户主页查看
  - [x] 关注/取关用户
  - [x] 离线缓存
  - [x] 稍后再看
  - [x] 观看记录
  - [x] 我的收藏
  - [x] 站内私信
- [x] 动态相关
  - [x] 全部、投稿、番剧分类查看
  - [x] 动态评论查看
  - [x] 动态评论回复功能

- [x] 视频播放相关
  - [x] 双击快进/快退
  - [x] 双击播放/暂停
  - [x] 垂直方向调节亮度/音量
  - [x] 垂直方向上滑全屏、下滑退出全屏
  - [x] 水平方向手势快进/快退
  - [x] 全屏方向设置
  - [x] 倍速选择/长按2倍速
  - [x] 硬件加速（视机型而定）
  - [x] 画质选择（高清画质未解锁）
  - [x] 音质选择（视视频而定）
  - [x] 解码格式选择（视视频而定）
  - [x] 弹幕
  - [x] 字幕
  - [x] 记忆播放
  - [x] 视频比例：高度/宽度适应、填充、包含等
- [x] 搜索相关
  - [x] 热搜
  - [x] 搜索历史
  - [x] 默认搜索词
  - [x] 投稿、番剧、直播间、用户搜索
  - [x] 视频搜索排序、按时长筛选
- [x] 视频详情页相关
  - [x] 视频选集(分p)切换
  - [x] 点赞、投币、收藏/取消收藏
  - [x] 相关视频查看
  - [x] 评论用户身份标识
  - [x] 评论(排序)查看、二楼评论查看
  - [x] 主楼、二楼评论回复功能
  - [x] 评论点赞
  - [x] 评论笔记图片查看、保存

- [x] 设置相关
  - [x] 画质、音质、解码方式预设
  - [x] 图片质量设定
  - [x] 主题模式：亮色/暗色/跟随系统
  - [x] 震动反馈(可选)
  - [x] 高帧率
  - [x] 自动全屏
  - [x] 横屏适配
- [ ] 等等

<br/>

## 下载

可以通过右侧release进行下载或拉取代码到本地进行编译

<br/>

## 声明

此项目（PiliPlus）是个人为了兴趣而开发，仅用于学习和测试，请于下载后24小时内删除。
所用API皆从官方网站收集，不提供任何破解内容。
在此致敬原作者：[guozhigq/pilipala](https://github.com/guozhigq/pilipala)
在此致敬上游作者：[orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)
本仓库做了更激进的修改，感谢原作者的开源精神。

感谢使用

<br/>

## 致谢

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)
- [media-kit](https://github.com/media-kit/media-kit)
- [dio](https://pub.dev/packages/dio)
- 等等

<br/>
<br/>
<br/>

## Star History

<a href="https://star-history.dera.page/#bggRGjQaUbCoE/PiliPlus&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=bggRGjQaUbCoE/PiliPlus&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=bggRGjQaUbCoE/PiliPlus&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=bggRGjQaUbCoE/PiliPlus&type=Date" />
 </picture>
</a>
