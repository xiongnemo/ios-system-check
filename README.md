# System Check

把为 Redmi K40（alioth）上的 iOS 16.5 移植写的几个检测应用合成一个：一个 App，下面五个标签页。
普通 iPhone 上它就是一个普通应用。

| 标签 | 原来的应用 | 做什么 |
| --- | --- | --- |
| GPU | GPU Check | 把 iOS 游戏可能用到的图形能力逐项测一遍（OpenGL ES 1/2/3、纹理和压缩格式、扩展、上屏、GLKit、CADisplayLink、Core Image、Metal、SceneKit、SpriteKit），每项 PASS / FAIL / SKIP，把应用带崩或卡住的记 CRASHED / HUNG |
| Metal | Metal Check | 应用能找到的 Metal：系统、GPU 内核服务、Metal 的设备发现、移植的驱动用到的私有部分；Metal 没有自己的设备时，由应用注册移植的驱动，再测命令队列、清屏、三角形、compute（离屏读回，加上顶部两个方块里的上屏结果）；用 [ios-alioth-devtools](https://github.com/xiongnemo/ios-alioth-devtools) 编的测试着色器逐项测顶点、纹理、混合（含混合颜色）、视口、裁剪、剔除、裁剪距离、间接绘制、深度、4x MSAA、heap、compute 的各种写入、threadgroup 内存、function constant、blit；SpriteKit（SKRenderer）、SceneKit（SCNView 指定 Metal）、MTKView 连续画两秒。不测 MapKit：它的地图数据要苹果的服务器，地图用我们自己的 [Map](https://github.com/xiongnemo/ios-map) 测 |
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
- 测试自己的调用抛出的 Objective-C 异常算这一项 FAIL（带抛出位置：共享缓存的 slide 和返回地址），不再让应用闪退；
  之后在别的 run loop 里抛的照样会带崩应用，下次启动标记、跳过。
- Metal 页注册移植的 Metal 驱动以后（对整个进程有效，撤不回来），同一次启动里 GPU 页的 Metal 两项会过，
  SpriteKit 的两项也改走 Metal（SpriteKit 看到有 Metal 设备就用它）。反过来，GPU 页先跑过 SKView / SCNView，
  SpriteKit、SceneKit 在这个进程里就定在 OpenGL ES 上了，Metal 页的 `metal.spritekit`、`metal.scenekit` 记 SKIP。
  要看普通应用在移植上拿到的结果，就关掉 App 重开、先跑 GPU 页。

- 包名：`com.anzupop.com.ios.systemcheck`
- 最低 iOS 15.0，iPhone，竖屏
- 只用 Objective-C 和系统框架；每个标签页一个 `.m` 文件，没有 storyboard、asset catalog
- 链接 OpenGLES（移植只给主程序链接了 OpenGLES 的应用 GL），Metal、MetalKit、SpriteKit、SceneKit 弱链接
- `build.sh` 从 devtools 的 v2 发布下载 `alioth-tests.metallib`（`METALLIB=文件` 用自己的）
- 图标由 `mkicon.py` 生成（纯 Python）：四块分别代表 GPU、Metal、视频、传感器，中间一个对勾
- `Entitlements.plist`：`com.apple.private.hid.client.event-monitor`（光线传感器的 HID 事件要它）

## 编译

```
./build.sh                                                        # macOS：Xcode 的 clang 和 SDK
CC=xnu-clang SDK=$THEOS/sdks/iPhoneOS16.5.sdk ./build.sh          # 别的地方：能出 iOS 程序的 clang + iPhoneOS SDK
```

产物在 `build/SystemCheck.ipa`。装了 ldid 就用 `Entitlements.plist` 签名。没有苹果签名：给不要苹果签名就能装应用的
iOS 用（K40 移植），或者自己重签。
