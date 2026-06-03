#ifndef HeartechoHALAudioShared_h
#define HeartechoHALAudioShared_h

#include <stddef.h>
#include <stdint.h>

#define HEARTECHO_HAL_AUDIO_SHARED_MAGIC UINT32_C(0x41424548) /* "HEBA" as little-endian bytes. */
#define HEARTECHO_HAL_AUDIO_SHARED_STATE_MAGIC UINT32_C(0x41534548) /* "HESA" as little-endian bytes. */
#define HEARTECHO_HAL_AUDIO_SHARED_VERSION UINT16_C(1)
#define HEARTECHO_HAL_AUDIO_SHARED_STATE_HEADER_BYTES UINT16_C(32)
#define HEARTECHO_HAL_AUDIO_SHARED_MAX_CHANNELS UINT32_C(64)
#define HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES UINT32_C(16)
#define HEARTECHO_HAL_AUDIO_SHARED_CAPACITY_FRAMES UINT32_C(4096)
#define HEARTECHO_HAL_AUDIO_SHARED_SAMPLE_CAPACITY (HEARTECHO_HAL_AUDIO_SHARED_MAX_CHANNELS * HEARTECHO_HAL_AUDIO_SHARED_CAPACITY_FRAMES)

typedef struct HeartechoHALAudioSharedBuffer {
    uint32_t magic;
    uint16_t version;
    uint16_t headerSize;
    uint32_t deviceObjectID;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint32_t reserved0;
    uint64_t writeFrameIndex;
    uint64_t readFrameIndex;
    uint64_t totalWrittenFrames;
    uint64_t totalReadFrames;
    uint64_t droppedFrameCount;
    uint64_t writerHeartbeat;
    uint64_t readerHeartbeat;
    uint64_t reserved1;
    float samples[HEARTECHO_HAL_AUDIO_SHARED_SAMPLE_CAPACITY];
} HeartechoHALAudioSharedBuffer;

typedef struct HeartechoHALAudioBufferStats {
    uint32_t deviceObjectID;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint32_t availableFrames;
    uint64_t totalWrittenFrames;
    uint64_t totalReadFrames;
    uint64_t droppedFrameCount;
    uint64_t writerHeartbeat;
    uint64_t readerHeartbeat;
} HeartechoHALAudioBufferStats;

typedef struct HeartechoHALAudioSharedState {
    uint32_t magic;
    uint16_t version;
    uint16_t headerSize;
    uint32_t slotCount;
    uint32_t maxDevices;
    uint32_t bufferSize;
    uint8_t reserved[12];
    HeartechoHALAudioSharedBuffer buffers[HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES];
} HeartechoHALAudioSharedState;

_Static_assert(offsetof(HeartechoHALAudioSharedState, buffers) == HEARTECHO_HAL_AUDIO_SHARED_STATE_HEADER_BYTES, "Unexpected HAL audio shared state header size");

#endif
