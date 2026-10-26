AuxCam 电脑端（Windows）
=======================
作用：采集 OBS 的虚拟摄像头，通过 USB 线推到手机上的 AuxCam，再由手机替换相机画面。

一、用之前（只做一次）
1. 电脑装 Apple Devices（微软商店，免费）或 iTunes。这样电脑才认得 USB 上的 iPhone。这是苹果的驱动，不能内置；没装的话，本程序会提示，并有按钮一键打开下载页。
2. 手机用 USB 线连电脑，手机解锁，弹出"信任此电脑"点信任。
3. OBS：设置 → 视频，基础分辨率和输出分辨率都设 1080x1920，帧率 30。

二、每次直播
1. 打开 OBS，点右下角"启动虚拟摄像头"。
2. 手机打开 AuxCam App（保持在运行）。
3. 打开本程序 AuxCamPC.exe，摄像头选 "OBS Virtual Camera"，点"开始推流"。
4. 状态变成绿色"推流中（正常）"，帧率 30，就可以了。
5. 去抖音开播，点悬浮窗的"放视频"。

三、文件
AuxCamPC.exe  本程序（只有这一个文件，视频编码工具 ffmpeg 已经内置在里面，不用另外装）
第一次启动会慢几秒（在解压内置的工具），之后正常。

四、常见问题
- "没找到手机"：换 USB 口/线，解锁手机，点信任。
- "手机已连上，但 AuxCam 没打开"：先打开手机上的 AuxCam。
- "没找到苹果 USB 驱动"：装 iTunes 或 Apple Devices。
- 摄像头下拉里没有 OBS Virtual Camera：OBS 里先点"启动虚拟摄像头"，再点本程序"刷新"。
- 编码选"自动"即可：优先用显卡编码（NVIDIA/Intel/AMD），都没有才用 CPU。
- 摄像头被别的软件占用时打不开，关掉其他读摄像头的软件。

五、给开发者
用 Python 直接运行（不打包）：python pc-tools\win\AuxCamPC.py
命令行推流：python pc-tools\sender_h264.py usb 28765 cam:"OBS Virtual Camera"
