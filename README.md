# System Check

把为 Redmi K40（alioth）上的 iOS 16.5 移植写的几个检测应用合成一个：一个 App，下面五个标签页。
普通 iPhone 上它就是一个普通应用。

| 标签 | 原来的应用 | 做什么 |
| --- | --- | --- |
| GPU | GPU Check | 把 iOS 游戏可能用到的图形能力逐项测一遍（OpenGL ES 1/2/3、纹理和压缩格式、扩展、上屏、GLKit、CADisplayLink、Core Image、Metal、SceneKit、SpriteKit），每项 PASS / FAIL / SKIP，把应用带崩或卡住的记 CRASHED / HUNG |
| Metal | Metal Check | 应用能找到的 Metal：系统、GPU 内核服务、Metal 的设备发现、移植的驱动用到的私有部分；Metal 没有自己的设备时，由应用注册移植的驱动，再测命令队列、清屏、三角形、compute（离屏读回，加上顶部两个方块里的上屏结果） |
| Video | VideoCheck | 用 AVPlayer + AVPlayerLayer 循环播放内置的 6 秒测试视频（ffmpeg 的 testsrc2），报告播放器状态 |
| Sensors | Sensor Check | 每个传感器和硬件输入实时显示：光线、距离、加速度计、陀螺仪、磁力计、气压、计步、指南针、定位、电池、麦克风、摄像头、蓝牙、方向、音量键、屏幕帧率、触摸、振动 |
| Motion | Motion Test | 一部 3D 的手机跟着这台手机转（CoreMotion 的姿态），下面是加速度计、陀螺仪、设备运动的数值 |

- 打开时不会自己跑：GPU、Metal、Video 各有 Run 按钮。同一次启动里第一次按 Run 时，如果上次启动跑到一半崩了，
  就从崩掉的那一项后面接着跑，之前崩过的项照样跳过；之后再按就是 Run again：从头跑，忘掉之前的标记。
- Sensors、Motion 只在自己的标签页在前台时才开传感器，切走就关（距离传感器开着会让屏幕在靠近时熄灭）。
- 从电脑上驱动（移植的测试工具就是这么用的）：`systemcheck://<gpu|metal|video|sensors|motion>[/run]`，
  切到那个标签页，带 `/run` 就开始测。
- 记录和原来一样：`Documents/gpucheck.log`、`Documents/metalcheck.log`（开了文件共享），
  `/dev/console` 和 NSLog 里的 `gpucheck: …`、`metalcheck: …`、`videocheck: …`。
- 进程里只有一个崩溃处理函数（`main.m`），GPU 和 Metal 两页各自登记自己“正在跑哪一项”的回调。
- `Info.plist` 里 `PrefersOpenGL` = YES：Metal 页注册了移植的 Metal 驱动以后（注册对整个进程有效，撤不回来），
  SpriteKit、SceneKit 照样走 OpenGL ES，GPU 页测的仍是普通应用在移植上拿到的那条路。不加的话 SpriteKit 会改走
  Metal，在移植上直接闪退（它的 Metal 渲染器找不到着色器库，`-[NSURL initFileURLWithPath:]` 拿到 nil）。
  代价：在真 iPhone 上 SpriteKit、SceneKit 的“默认”也变成 OpenGL ES。

- 包名：`com.anzupop.com.ios.systemcheck`
- 最低 iOS 15.0，iPhone，竖屏
- 只用 Objective-C 和系统框架；每个标签页一个 `.m` 文件，没有 storyboard、asset catalog
- 链接 OpenGLES（移植只给主程序链接了 OpenGLES 的应用 GL），Metal、SpriteKit、SceneKit 弱链接
- 图标由 `mkicon.py` 生成（纯 Python）：四块分别代表 GPU、Metal、视频、传感器，中间一个对勾
- `Entitlements.plist`：`com.apple.private.hid.client.event-monitor`（光线传感器的 HID 事件要它）

## 编译

```
./build.sh                                                        # macOS：Xcode 的 clang 和 SDK
CC=xnu-clang SDK=$THEOS/sdks/iPhoneOS16.5.sdk ./build.sh          # 别的地方：能出 iOS 程序的 clang + iPhoneOS SDK
```

产物在 `build/SystemCheck.ipa`。装了 ldid 就用 `Entitlements.plist` 签名。没有苹果签名：给不要苹果签名就能装应用的
iOS 用（K40 移植），或者自己重签。
