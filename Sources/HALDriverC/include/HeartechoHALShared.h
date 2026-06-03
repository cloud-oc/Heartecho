#ifndef HeartechoHALShared_h
#define HeartechoHALShared_h

#include <stddef.h>
#include <stdint.h>

#define HEARTECHO_HAL_SHARED_MAGIC UINT32_C(0x43534548) /* "HESC" as little-endian bytes. */
#define HEARTECHO_HAL_SHARED_VERSION UINT16_C(1)
#define HEARTECHO_HAL_SHARED_MAX_DEVICES UINT16_C(16)
#define HEARTECHO_HAL_SHARED_MAX_CHANNELS UINT32_C(64)
#define HEARTECHO_HAL_SHARED_MAX_NAME_BYTES UINT16_C(96)
#define HEARTECHO_HAL_SHARED_MAX_UID_BYTES UINT16_C(128)
#define HEARTECHO_HAL_SHARED_HEADER_BYTES UINT16_C(32)
#define HEARTECHO_HAL_SHARED_DEVICE_BYTES UINT16_C(256)
#define HEARTECHO_HAL_SHARED_DEVICE_OBJECT_BASE UINT32_C(2)
#define HEARTECHO_HAL_SHARED_OBJECT_STRIDE UINT32_C(3)

typedef struct HeartechoHALSharedDeviceConfig {
    uint32_t deviceObjectID;
    uint32_t inputStreamObjectID;
    uint32_t outputStreamObjectID;
    uint32_t channelCount;
    double sampleRate;
    uint8_t isEnabled;
    uint8_t reservedFlags;
    uint16_t latencyFrames;
    uint16_t safetyOffsetFrames;
    uint16_t bufferFrameSize;
    char name[HEARTECHO_HAL_SHARED_MAX_NAME_BYTES];
    char uid[HEARTECHO_HAL_SHARED_MAX_UID_BYTES];
} HeartechoHALSharedDeviceConfig;

typedef struct HeartechoHALSharedConfig {
    uint32_t magic;
    uint16_t version;
    uint16_t headerSize;
    uint16_t deviceSize;
    uint16_t deviceCount;
    uint32_t maxDevices;
    uint8_t reserved[16];
    HeartechoHALSharedDeviceConfig devices[HEARTECHO_HAL_SHARED_MAX_DEVICES];
} HeartechoHALSharedConfig;

_Static_assert(sizeof(HeartechoHALSharedDeviceConfig) == HEARTECHO_HAL_SHARED_DEVICE_BYTES, "Unexpected HAL shared device config size");
_Static_assert(offsetof(HeartechoHALSharedConfig, devices) == HEARTECHO_HAL_SHARED_HEADER_BYTES, "Unexpected HAL shared config header size");

#endif
