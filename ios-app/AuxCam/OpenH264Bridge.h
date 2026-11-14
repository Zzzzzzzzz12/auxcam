#ifndef AUXCAM_OPENH264_BRIDGE_H
#define AUXCAM_OPENH264_BRIDGE_H
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

// 软件解码器（OpenH264，单线程：多线程模式实测会解错画面，不用）。
void * _Nullable auxh264_create(void);
void auxh264_destroy(void * _Nullable decoder);
// 输入一帧 Annex-B（00 00 00 01 + NAL）。
// lowDelay = 1：码流里没有 B 帧，这一帧解完立刻出画面（不让解码器为"可能的重排序"扣住一帧）。
//            有 B 帧时必须传 0，否则画面顺序会乱。
// 返回 1 = 出了一张画面（*outputBuffer 已 retain，调用方负责释放）；0 = 这次没出画面；<0 = 出错。
int32_t auxh264_decode(void * _Nullable decoder, const uint8_t * _Nullable bytes, int32_t length, int32_t lowDelay,
                       CVPixelBufferRef _Nullable * _Nonnull outputBuffer);

// 把一张 NV12 画面写进共享内存，相机插件从那里读。
// limitedRange = 1：画面是"窄范围"(16~235)，写入时拉伸成插件要的全范围(0~255)，否则颜色发灰。
// 返回 1 = 成功；<0 = 失败。
int32_t auxcam_publish_frame(CVPixelBufferRef _Nonnull frame, int32_t limitedRange);

// 镜像 / 旋转（0/90/180/270，顺时针），写共享内存时生效。
void auxcam_set_transform(int32_t mirror, int32_t rotate);
#endif
