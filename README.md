# System Check

把为 Redmi K40（alioth）上的 iOS 16.5 移植写的几个检测应用合成一个：一个 App，下面七个标签页。
普通 iPhone 上它就是一个普通应用。

| 标签 | 原来的应用 | 做什么 |
| --- | --- | --- |
| GPU | GPU Check | 把 iOS 游戏可能用到的图形能力逐项测一遍（OpenGL ES 1/2/3、纹理和压缩格式、扩展、上屏、GLKit、CADisplayLink、Core Image、Metal、SceneKit、SpriteKit），每项 PASS / FAIL / SKIP，把应用带崩或卡住的记 CRASHED / HUNG |
| Metal | Metal Check | 应用能找到的 Metal：系统、GPU 内核服务、Metal 的设备发现、移植的驱动用到的私有部分；Metal 没有自己的设备时，由应用注册移植的驱动，再测命令队列、清屏、三角形、compute（离屏读回，加上顶部两个方块里的上屏结果）；用 [ios-alioth-devtools](https://github.com/xiongnemo/ios-alioth-devtools) 编的测试着色器逐项测顶点、纹理、混合（含混合颜色）、视口、裁剪、剔除、裁剪距离、间接绘制、深度、4x MSAA、heap、compute 的各种写入、threadgroup 内存、function constant、blit；在手机上现编的着色器测 SIMD-group 和 quad 函数（归约、前缀和、广播、洗牌）、多个颜色附件各用各的清屏色、采样器限定 mip 范围以后的 compute、深度截断（depth clamp）、一个被拒的绘制后面的绘制照样画出来、DontCare 存储、2000 次带 `setVertexBytes` 的绘制；MetalPerformanceShaders 里应用自己建的图像内核（直方图、高斯模糊、卷积、双线性和 Lanczos 缩放，Telegram 一类应用会用）；SpriteKit（SKRenderer）、SceneKit（SCNView 指定 Metal）、MTKView 连续画两秒。不测 MapKit：它的地图数据要苹果的服务器，地图用我们自己的 [Map](https://github.com/xiongnemo/ios-map) 测 |
| Video | VideoCheck | 用 AVPlayer + AVPlayerLayer 循环播放内置的 6 秒测试视频（ffmpeg 的 testsrc2），报告播放器状态 |
| Sensors | Sensor Check | 每个传感器和硬件输入实时显示：光线、距离、加速度计、陀螺仪、磁力计、气压、计步、指南针、定位、电池、麦克风、摄像头、蓝牙、方向、音量键、屏幕帧率、触摸、振动 |
| Motion | Motion Test | 一部 3D 的手机跟着这台手机转（CoreMotion 的姿态），下面是加速度计、陀螺仪、设备运动的数值 |
| GPS | （新） | 仿 GPS Status：卫星天空图（方位、仰角，按信号强度上色，参与定位的实心，随指南针转）、每颗卫星的信号柱、定位状态（在视/跟踪/使用的卫星数、精度、坐标、高度、速度、航向、定位时间）。数据两路并列：iOS 自己的（CoreLocation），以及移植内核从基带读到的卫星（sysctl `kern.hakios.gnss`，K40 的 SDX55 走 QMI LOC；iOS 不给应用卫星信息，所以卫星只来自这里，别的设备上没有这一路）。`/run` 画一张标着 DEMO 的假天空，用来检查绘制 |
| Effects | （新） | Telegram 一类应用在 iOS 16 上的“毛玻璃”外观拆成单项，每项在移动的内容上跑 10 秒（先等 1 秒，再量 8 秒）：帧率、迟到的帧、最慢的一帧。单项有 UIVisualEffectView、CABackdropLayer 的高斯模糊（半径 2、6、20，以及四分之一分辨率）、colorMatrix 加模糊、边缘渐变的 variableBlur、4 个和 8 个玻璃胶囊、带不带玻璃的弹簧面板、120 张缩略图滚动、相册缩略图、摄像头实时画面，最后是应用自己用 Metal 画的玻璃着色器作对比。这些都是照公开的事实自己写的，没有 Telegram 的代码。`systemcheck://effects/photos` 往相册里加 60 张编号的渐变测试图（移植每次启动相册都是空的） |

- 打开时不会自己跑：GPU、Metal、Video、Effects 各有 Run 按钮。同一次启动里第一次按 Run 时，如果上次启动跑到一半崩了，
  就从崩掉的那一项后面接着跑，之前崩过的项照样跳过；之后再按就是 Run again：从头跑，忘掉之前的标记。
- Sensors、Motion、GPS 只在自己的标签页在前台时才开传感器和定位，切走就关（距离传感器开着会让屏幕在靠近时熄灭）。
- 从电脑上驱动（移植的测试工具就是这么用的）：`systemcheck://<gpu|metal|video|sensors|motion|gps|effects>[/run]`，
  切到那个标签页，带 `/run` 就开始测。
- 记录：`Documents/gpucheck.log`、`Documents/metalcheck.log`、`Documents/gpscheck.log`、`Documents/effectscheck.log`
  （开了文件共享），`/dev/console` 和 NSLog 里的 `gpucheck: …`、`metalcheck: …`、`videocheck: …`、`gpscheck: …`、
  `effectscheck: …`。GPS 的记录只有卫星数和精度，不写坐标。
- 进程里只有一个崩溃处理函数（`main.m`），GPU 和 Metal 两页各自登记自己“正在跑哪一项”的回调。
- 测试自己的调用抛出的 Objective-C 异常算这一项 FAIL（带抛出位置：共享缓存的 slide 和返回地址），不再让应用闪退；
  之后在别的 run loop 里抛的照样会带崩应用，下次启动标记、跳过。
- Metal 页注册移植的 Metal 驱动以后（对整个进程有效，撤不回来），同一次启动里 GPU 页的 Metal 两项会过，
  SpriteKit 的两项也改走 Metal（SpriteKit 看到有 Metal 设备就用它）。反过来，GPU 页先跑过 SKView / SCNView，
  SpriteKit、SceneKit 在这个进程里就定在 OpenGL ES 上了，Metal 页的 `metal.spritekit`、`metal.scenekit` 记 SKIP。
  要看普通应用在移植上拿到的结果，就关掉 App 重开、先跑 GPU 页。

- 包名：`com.anzupop.ios.systemcheck`
- 最低 iOS 15.0，iPhone，竖屏
- 只用 Objective-C 和系统框架；每个标签页一个 `.m` 文件，没有 storyboard、asset catalog
- 链接 OpenGLES（移植只给主程序链接了 OpenGLES 的应用 GL），Metal、MetalKit、SpriteKit、SceneKit、MetalPerformanceShaders、Photos 弱链接
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
