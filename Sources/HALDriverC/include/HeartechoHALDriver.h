#ifndef HeartechoHALDriver_h
#define HeartechoHALDriver_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>

#include "HeartechoHALAudioShared.h"
#include "HeartechoHALShared.h"

typedef struct HeartechoHALConfigChangeSummary {
    UInt32 deviceListChanged;
    UInt32 deviceMetadataChanged;
    UInt32 deviceFormatChanged;
    UInt32 streamFormatChanged;
    UInt32 notifiedObjectCount;
} HeartechoHALConfigChangeSummary;

typedef struct HeartechoHALRealtimeSafetyStats {
    UInt64 ioOperationCount;
    UInt64 audioReadCallCount;
    UInt64 audioReadFrameCount;
    UInt64 zeroFillFrameCount;
    UInt64 renderPathLockCount;
    UInt64 renderPathAllocationCount;
    UInt64 renderPathFileIOCount;
    UInt64 renderPathSharedMemoryOpenCount;
} HeartechoHALRealtimeSafetyStats;

void* HeartechoHALDriverFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
Boolean HeartechoHALDriverLoadSharedConfigFromFile(const char* path);
Boolean HeartechoHALDriverLoadSharedConfigFromSharedMemory(const char* name);
Boolean HeartechoHALDriverPublishSharedConfigToSharedMemory(const char* name, const void* bytes, size_t byteCount);
Boolean HeartechoHALDriverUnlinkSharedMemory(const char* name);
size_t HeartechoHALDriverAudioSharedMemoryByteCount(void);
Boolean HeartechoHALDriverOpenAudioBuffersSharedMemory(const char* name, Boolean createIfMissing);
void HeartechoHALDriverCloseAudioBuffersSharedMemory(void);
Boolean HeartechoHALDriverPublishAudioBuffersToSharedMemory(const char* name);
Boolean HeartechoHALDriverLoadAudioBuffersFromSharedMemory(const char* name);
Boolean HeartechoHALDriverUnlinkAudioBuffersSharedMemory(const char* name);
void HeartechoHALDriverResetSharedConfig(void);
UInt32 HeartechoHALDriverActiveDeviceCount(void);
UInt32 HeartechoHALDriverActiveDeviceObjectID(UInt32 activeIndex);
UInt32 HeartechoHALDriverActiveDeviceChannelCount(UInt32 activeIndex);
Float64 HeartechoHALDriverActiveDeviceSampleRate(UInt32 activeIndex);
Boolean HeartechoHALDriverActiveDeviceIsEnabled(UInt32 activeIndex);
size_t HeartechoHALDriverCopyActiveDeviceName(UInt32 activeIndex, char* outBuffer, size_t bufferLength);
size_t HeartechoHALDriverCopyActiveDeviceUID(UInt32 activeIndex, char* outBuffer, size_t bufferLength);
HeartechoHALConfigChangeSummary HeartechoHALDriverLastConfigChangeSummary(void);
void HeartechoHALDriverResetAudioBuffer(void);
Boolean HeartechoHALDriverWriteAudioFrames(AudioObjectID deviceObjectID, UInt32 channelCount, UInt32 frameCount, const Float32* interleavedFrames);
UInt32 HeartechoHALDriverReadAudioFrames(AudioObjectID deviceObjectID, UInt32 channelCount, UInt32 frameCount, Float32* outInterleavedFrames);
UInt32 HeartechoHALDriverAudioBufferAvailableFrames(AudioObjectID deviceObjectID);
HeartechoHALAudioBufferStats HeartechoHALDriverAudioBufferStats(AudioObjectID deviceObjectID);
HeartechoHALAudioSharedBuffer HeartechoHALDriverAudioBufferSnapshot(void);
void HeartechoHALDriverResetRealtimeSafetyStats(void);
HeartechoHALRealtimeSafetyStats HeartechoHALDriverRealtimeSafetyStats(void);
OSStatus HeartechoHALDriverRunIOOperationForDiagnostics(AudioObjectID deviceObjectID, UInt32 frameCount, Float32* ioMainBuffer);
Boolean HeartechoHALDriverCopyPropertyDataForDiagnostics(AudioObjectID objectID, AudioObjectPropertySelector selector, UInt32 dataSize, UInt32* outDataSize, void* outData);

#endif
