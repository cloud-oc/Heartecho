#include "HeartechoHALDriver.h"
#include "HeartechoHALShared.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static AudioServerPlugInHostRef gHost = NULL;
static atomic_uint gRefCount = 1;
static atomic_bool gIsRunning = false;
static atomic_ullong gSampleTime = 0;
static atomic_ullong gHostTime = 0;
static atomic_ullong gSeed = 1;
static atomic_ullong gRealtimeIOOperationCount = 0;
static atomic_ullong gRealtimeAudioReadCallCount = 0;
static atomic_ullong gRealtimeAudioReadFrameCount = 0;
static atomic_ullong gRealtimeZeroFillFrameCount = 0;
static atomic_ullong gRealtimeRenderPathLockCount = 0;
static atomic_ullong gRealtimeRenderPathAllocationCount = 0;
static atomic_ullong gRealtimeRenderPathFileIOCount = 0;
static atomic_ullong gRealtimeRenderPathSharedMemoryOpenCount = 0;
static HeartechoHALSharedConfig gLoadedSharedConfig;
static _Atomic(const HeartechoHALSharedConfig*) gActiveSharedConfig = NULL;
static HeartechoHALConfigChangeSummary gLastConfigChangeSummary = {0};
static const char* kDefaultConfigSharedMemoryName = "/HeartechoHALSharedConfig";
static const char* kDefaultAudioSharedMemoryName = "/HeartechoHALAudioBuffers";
static HeartechoHALAudioSharedState gLocalAudioSharedState = {
    HEARTECHO_HAL_AUDIO_SHARED_STATE_MAGIC,
    HEARTECHO_HAL_AUDIO_SHARED_VERSION,
    HEARTECHO_HAL_AUDIO_SHARED_STATE_HEADER_BYTES,
    HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES,
    HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES,
    sizeof(HeartechoHALAudioSharedBuffer),
    {0},
    {0}
};
static _Atomic(HeartechoHALAudioSharedState*) gActiveAudioSharedState = NULL;
static HeartechoHALAudioSharedState* gMappedAudioSharedState = NULL;
static size_t gMappedAudioSharedStateByteCount = 0;
static pthread_mutex_t gAudioStateMutex = PTHREAD_MUTEX_INITIALIZER;

static const HeartechoHALSharedConfig kDefaultSharedConfig = {
    HEARTECHO_HAL_SHARED_MAGIC,
    HEARTECHO_HAL_SHARED_VERSION,
    HEARTECHO_HAL_SHARED_HEADER_BYTES,
    HEARTECHO_HAL_SHARED_DEVICE_BYTES,
    1,
    HEARTECHO_HAL_SHARED_MAX_DEVICES,
    {0},
    {
        {
            HEARTECHO_HAL_SHARED_DEVICE_OBJECT_BASE,
            HEARTECHO_HAL_SHARED_DEVICE_OBJECT_BASE + 1,
            HEARTECHO_HAL_SHARED_DEVICE_OBJECT_BASE + 2,
            2,
            48000.0,
            1,
            0,
            0,
            0,
            512,
            "Heartecho Virtual Device",
            "com.heartecho.Heartecho.VirtualDevice"
        }
    }
};

static const HeartechoHALSharedConfig* activeSharedConfig(void);
static Boolean sharedConfigIsValid(const HeartechoHALSharedConfig* config);
static Boolean activateSharedConfig(const HeartechoHALSharedConfig* config);
static HeartechoHALConfigChangeSummary summarizeConfigChange(const HeartechoHALSharedConfig* oldConfig, const HeartechoHALSharedConfig* newConfig);
static void notifyConfigChange(const HeartechoHALSharedConfig* oldConfig, const HeartechoHALSharedConfig* newConfig, HeartechoHALConfigChangeSummary* summary);
static const HeartechoHALSharedDeviceConfig* matchingDeviceByObjectID(const HeartechoHALSharedConfig* config, UInt32 objectID);
static Boolean deviceIdentityChanged(const HeartechoHALSharedDeviceConfig* oldDevice, const HeartechoHALSharedDeviceConfig* newDevice);
static Boolean deviceMetadataChanged(const HeartechoHALSharedDeviceConfig* oldDevice, const HeartechoHALSharedDeviceConfig* newDevice);
static Boolean deviceFormatChanged(const HeartechoHALSharedDeviceConfig* oldDevice, const HeartechoHALSharedDeviceConfig* newDevice);
static Boolean fixedCStringEquals(const char* left, const char* right, UInt32 maxLength);
static void notifyObjectProperties(AudioObjectID objectID, const AudioObjectPropertyAddress* addresses, UInt32 addressCount, HeartechoHALConfigChangeSummary* summary);
static Boolean loadSharedConfigFromFile(const char* path, HeartechoHALSharedConfig* outConfig);
static Boolean loadSharedConfigFromSharedMemory(const char* name, HeartechoHALSharedConfig* outConfig);
static Boolean audioSharedStateIsValid(const HeartechoHALAudioSharedState* state);
static Boolean audioBufferSlotIsValidOrEmpty(const HeartechoHALAudioSharedBuffer* buffer);
static Boolean audioBufferSlotIsEmpty(const HeartechoHALAudioSharedBuffer* buffer);
static HeartechoHALAudioSharedState* activeAudioSharedState(void);
static void initializeAudioSharedState(HeartechoHALAudioSharedState* state);
static void resetAudioSharedState(HeartechoHALAudioSharedState* state);
static Boolean openAudioSharedState(const char* name, Boolean createIfMissing);
static void closeMappedAudioSharedStateLocked(void);
static void writeAudioSharedStateSnapshot(HeartechoHALAudioSharedState* outState);
static void loadAudioSharedStateSnapshot(const HeartechoHALAudioSharedState* state);
static size_t copyDeviceCString(const char* source, UInt32 maxLength, char* outBuffer, size_t bufferLength);
static UInt32 activeDeviceCount(void);
static const HeartechoHALSharedDeviceConfig* deviceConfigAtActiveIndex(UInt32 activeIndex);
static const HeartechoHALSharedDeviceConfig* firstDeviceConfig(void);
static const HeartechoHALSharedDeviceConfig* deviceConfigForDeviceObject(AudioObjectID objectID);
static const HeartechoHALSharedDeviceConfig* deviceConfigForStreamObject(AudioObjectID objectID);
static const HeartechoHALSharedDeviceConfig* deviceConfigForObject(AudioObjectID objectID);
static UInt32 deviceChannelCount(const HeartechoHALSharedDeviceConfig* device);
static UInt32 deviceLatencyFrames(const HeartechoHALSharedDeviceConfig* device);
static UInt32 deviceSafetyOffsetFrames(const HeartechoHALSharedDeviceConfig* device);
static UInt32 deviceBufferFrameSize(const HeartechoHALSharedDeviceConfig* device);
static UInt32 bytesPerFrameForDevice(const HeartechoHALSharedDeviceConfig* device);
static HeartechoHALAudioSharedBuffer* audioBufferForDevice(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID);
static HeartechoHALAudioSharedBuffer* audioBufferForDeviceOrEmptySlot(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID);
static void initializeAudioBuffer(HeartechoHALAudioSharedBuffer* buffer, AudioObjectID deviceObjectID, UInt32 channelCount);
static UInt32 audioBufferAvailableFrames(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID);
static UInt32 writeAudioFrames(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID, UInt32 channelCount, UInt32 frameCount, const Float32* interleavedFrames);
static UInt32 readAudioFrames(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID, UInt32 channelCount, UInt32 frameCount, Float32* outInterleavedFrames);
static HeartechoHALAudioBufferStats audioBufferStats(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID);
static void recordRealtimeAudioRead(UInt32 requestedFrames, UInt32 readableFrames);
static UInt64 atomicLoadUInt64(const UInt64* value);
static void atomicStoreUInt64(UInt64* value, UInt64 newValue);
static UInt64 atomicAddUInt64(UInt64* value, UInt64 increment);
static UInt32 atomicLoadUInt32(const UInt32* value);
static void atomicStoreUInt32(UInt32* value, UInt32 newValue);

static HRESULT STDMETHODCALLTYPE QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface);
static ULONG STDMETHODCALLTYPE AddRef(void* driver);
static ULONG STDMETHODCALLTYPE Release(void* driver);
static OSStatus STDMETHODCALLTYPE Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus STDMETHODCALLTYPE CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus STDMETHODCALLTYPE DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID);
static OSStatus STDMETHODCALLTYPE AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo* clientInfo);
static OSStatus STDMETHODCALLTYPE RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo* clientInfo);
static OSStatus STDMETHODCALLTYPE PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo);
static OSStatus STDMETHODCALLTYPE AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo);
static Boolean STDMETHODCALLTYPE HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address);
static OSStatus STDMETHODCALLTYPE IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable);
static OSStatus STDMETHODCALLTYPE GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32* outDataSize);
static OSStatus STDMETHODCALLTYPE GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, UInt32* outDataSize, void* outData);
static OSStatus STDMETHODCALLTYPE SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, const void* data);
static OSStatus STDMETHODCALLTYPE StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus STDMETHODCALLTYPE StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus STDMETHODCALLTYPE GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus STDMETHODCALLTYPE WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus STDMETHODCALLTYPE BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo);
static OSStatus STDMETHODCALLTYPE DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus STDMETHODCALLTYPE EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo);

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation
};

static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;

__attribute__((visibility("default")))
void* HeartechoHALDriverFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;

    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        AddRef(&gDriverInterfacePtr);
        return &gDriverInterfacePtr;
    }

    return NULL;
}

Boolean HeartechoHALDriverLoadSharedConfigFromFile(const char* path)
{
    HeartechoHALSharedConfig config;
    if (!loadSharedConfigFromFile(path, &config)) {
        return false;
    }

    return activateSharedConfig(&config);
}

Boolean HeartechoHALDriverLoadSharedConfigFromSharedMemory(const char* name)
{
    HeartechoHALSharedConfig config;
    if (!loadSharedConfigFromSharedMemory(name, &config)) {
        return false;
    }

    return activateSharedConfig(&config);
}

Boolean HeartechoHALDriverPublishSharedConfigToSharedMemory(const char* name, const void* bytes, size_t byteCount)
{
    if (name == NULL || bytes == NULL || byteCount != sizeof(HeartechoHALSharedConfig)) {
        return false;
    }

    shm_unlink(name);
    int descriptor = shm_open(name, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        return false;
    }

    if (ftruncate(descriptor, (off_t)byteCount) != 0) {
        close(descriptor);
        return false;
    }

    void* mapped = mmap(NULL, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    int closeResult = close(descriptor);
    if (mapped == MAP_FAILED || closeResult != 0) {
        if (mapped != MAP_FAILED) {
            munmap(mapped, byteCount);
        }
        return false;
    }

    memcpy(mapped, bytes, byteCount);
    int syncResult = msync(mapped, byteCount, MS_SYNC);
    int unmapResult = munmap(mapped, byteCount);
    return syncResult == 0 && unmapResult == 0;
}

Boolean HeartechoHALDriverUnlinkSharedMemory(const char* name)
{
    return name != NULL && shm_unlink(name) == 0;
}

size_t HeartechoHALDriverAudioSharedMemoryByteCount(void)
{
    return sizeof(HeartechoHALAudioSharedState);
}

Boolean HeartechoHALDriverOpenAudioBuffersSharedMemory(const char* name, Boolean createIfMissing)
{
    return openAudioSharedState(name, createIfMissing);
}

void HeartechoHALDriverCloseAudioBuffersSharedMemory(void)
{
    pthread_mutex_lock(&gAudioStateMutex);
    closeMappedAudioSharedStateLocked();
    pthread_mutex_unlock(&gAudioStateMutex);
}

Boolean HeartechoHALDriverPublishAudioBuffersToSharedMemory(const char* name)
{
    if (name == NULL) {
        return false;
    }

    size_t byteCount = sizeof(HeartechoHALAudioSharedState);
    shm_unlink(name);
    int descriptor = shm_open(name, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        return false;
    }

    if (ftruncate(descriptor, (off_t)byteCount) != 0) {
        close(descriptor);
        return false;
    }

    void* mapped = mmap(NULL, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    int closeResult = close(descriptor);
    if (mapped == MAP_FAILED || closeResult != 0) {
        if (mapped != MAP_FAILED) {
            munmap(mapped, byteCount);
        }
        return false;
    }

    writeAudioSharedStateSnapshot((HeartechoHALAudioSharedState*)mapped);

    int syncResult = msync(mapped, byteCount, MS_SYNC);
    int unmapResult = munmap(mapped, byteCount);
    return syncResult == 0 && unmapResult == 0;
}

Boolean HeartechoHALDriverLoadAudioBuffersFromSharedMemory(const char* name)
{
    if (name == NULL) {
        return false;
    }

    size_t byteCount = sizeof(HeartechoHALAudioSharedState);
    int descriptor = shm_open(name, O_RDONLY, 0);
    if (descriptor < 0) {
        return false;
    }

    void* mapped = mmap(NULL, byteCount, PROT_READ, MAP_SHARED, descriptor, 0);
    int closeResult = close(descriptor);
    if (mapped == MAP_FAILED || closeResult != 0) {
        if (mapped != MAP_FAILED) {
            munmap(mapped, byteCount);
        }
        return false;
    }

    const HeartechoHALAudioSharedState* state = (const HeartechoHALAudioSharedState*)mapped;
    Boolean isValid = audioSharedStateIsValid(state);
    if (isValid) {
        loadAudioSharedStateSnapshot(state);
    }

    int unmapResult = munmap(mapped, byteCount);
    return isValid && unmapResult == 0;
}

Boolean HeartechoHALDriverUnlinkAudioBuffersSharedMemory(const char* name)
{
    return name != NULL && shm_unlink(name) == 0;
}

void HeartechoHALDriverResetSharedConfig(void)
{
    atomic_store(&gActiveSharedConfig, NULL);
    memset(&gLoadedSharedConfig, 0, sizeof(gLoadedSharedConfig));
    memset(&gLastConfigChangeSummary, 0, sizeof(gLastConfigChangeSummary));
}

UInt32 HeartechoHALDriverActiveDeviceCount(void)
{
    return activeDeviceCount();
}

UInt32 HeartechoHALDriverActiveDeviceObjectID(UInt32 activeIndex)
{
    const HeartechoHALSharedDeviceConfig* device = deviceConfigAtActiveIndex(activeIndex);
    return device != NULL ? device->deviceObjectID : 0;
}

UInt32 HeartechoHALDriverActiveDeviceChannelCount(UInt32 activeIndex)
{
    return deviceChannelCount(deviceConfigAtActiveIndex(activeIndex));
}

Float64 HeartechoHALDriverActiveDeviceSampleRate(UInt32 activeIndex)
{
    const HeartechoHALSharedDeviceConfig* device = deviceConfigAtActiveIndex(activeIndex);
    return device != NULL && device->sampleRate > 0.0 ? device->sampleRate : 48000.0;
}

Boolean HeartechoHALDriverActiveDeviceIsEnabled(UInt32 activeIndex)
{
    const HeartechoHALSharedDeviceConfig* device = deviceConfigAtActiveIndex(activeIndex);
    return device != NULL && device->isEnabled;
}

size_t HeartechoHALDriverCopyActiveDeviceName(UInt32 activeIndex, char* outBuffer, size_t bufferLength)
{
    const HeartechoHALSharedDeviceConfig* device = deviceConfigAtActiveIndex(activeIndex);
    return copyDeviceCString(
        device != NULL ? device->name : NULL,
        HEARTECHO_HAL_SHARED_MAX_NAME_BYTES,
        outBuffer,
        bufferLength
    );
}

size_t HeartechoHALDriverCopyActiveDeviceUID(UInt32 activeIndex, char* outBuffer, size_t bufferLength)
{
    const HeartechoHALSharedDeviceConfig* device = deviceConfigAtActiveIndex(activeIndex);
    return copyDeviceCString(
        device != NULL ? device->uid : NULL,
        HEARTECHO_HAL_SHARED_MAX_UID_BYTES,
        outBuffer,
        bufferLength
    );
}

HeartechoHALConfigChangeSummary HeartechoHALDriverLastConfigChangeSummary(void)
{
    return gLastConfigChangeSummary;
}

void HeartechoHALDriverResetAudioBuffer(void)
{
    resetAudioSharedState(activeAudioSharedState());
}

Boolean HeartechoHALDriverWriteAudioFrames(AudioObjectID deviceObjectID, UInt32 channelCount, UInt32 frameCount, const Float32* interleavedFrames)
{
    if (interleavedFrames == NULL || channelCount == 0 || channelCount > HEARTECHO_HAL_AUDIO_SHARED_MAX_CHANNELS) {
        return false;
    }

    UInt32 written = writeAudioFrames(activeAudioSharedState(), deviceObjectID, channelCount, frameCount, interleavedFrames);
    return written == frameCount;
}

UInt32 HeartechoHALDriverReadAudioFrames(AudioObjectID deviceObjectID, UInt32 channelCount, UInt32 frameCount, Float32* outInterleavedFrames)
{
    if (outInterleavedFrames == NULL || channelCount == 0 || channelCount > HEARTECHO_HAL_AUDIO_SHARED_MAX_CHANNELS) {
        return 0;
    }

    return readAudioFrames(activeAudioSharedState(), deviceObjectID, channelCount, frameCount, outInterleavedFrames);
}

UInt32 HeartechoHALDriverAudioBufferAvailableFrames(AudioObjectID deviceObjectID)
{
    return audioBufferAvailableFrames(activeAudioSharedState(), deviceObjectID);
}

HeartechoHALAudioBufferStats HeartechoHALDriverAudioBufferStats(AudioObjectID deviceObjectID)
{
    return audioBufferStats(activeAudioSharedState(), deviceObjectID);
}

HeartechoHALAudioSharedBuffer HeartechoHALDriverAudioBufferSnapshot(void)
{
    HeartechoHALAudioSharedState* state = activeAudioSharedState();
    return state != NULL ? state->buffers[0] : (HeartechoHALAudioSharedBuffer){0};
}

void HeartechoHALDriverResetRealtimeSafetyStats(void)
{
    atomic_store(&gRealtimeIOOperationCount, 0);
    atomic_store(&gRealtimeAudioReadCallCount, 0);
    atomic_store(&gRealtimeAudioReadFrameCount, 0);
    atomic_store(&gRealtimeZeroFillFrameCount, 0);
    atomic_store(&gRealtimeRenderPathLockCount, 0);
    atomic_store(&gRealtimeRenderPathAllocationCount, 0);
    atomic_store(&gRealtimeRenderPathFileIOCount, 0);
    atomic_store(&gRealtimeRenderPathSharedMemoryOpenCount, 0);
}

HeartechoHALRealtimeSafetyStats HeartechoHALDriverRealtimeSafetyStats(void)
{
    return (HeartechoHALRealtimeSafetyStats){
        atomic_load(&gRealtimeIOOperationCount),
        atomic_load(&gRealtimeAudioReadCallCount),
        atomic_load(&gRealtimeAudioReadFrameCount),
        atomic_load(&gRealtimeZeroFillFrameCount),
        atomic_load(&gRealtimeRenderPathLockCount),
        atomic_load(&gRealtimeRenderPathAllocationCount),
        atomic_load(&gRealtimeRenderPathFileIOCount),
        atomic_load(&gRealtimeRenderPathSharedMemoryOpenCount)
    };
}

OSStatus HeartechoHALDriverRunIOOperationForDiagnostics(AudioObjectID deviceObjectID, UInt32 frameCount, Float32* ioMainBuffer)
{
    return DoIOOperation(
        &gDriverInterfacePtr,
        deviceObjectID,
        deviceObjectID + 1,
        0,
        kAudioServerPlugInIOOperationReadInput,
        frameCount,
        NULL,
        ioMainBuffer,
        NULL
    );
}

Boolean HeartechoHALDriverCopyPropertyDataForDiagnostics(AudioObjectID objectID, AudioObjectPropertySelector selector, UInt32 dataSize, UInt32* outDataSize, void* outData)
{
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    return GetPropertyData(
        &gDriverInterfacePtr,
        objectID,
        0,
        &address,
        0,
        NULL,
        dataSize,
        outDataSize,
        outData
    ) == noErr;
}

static Boolean sharedConfigIsValid(const HeartechoHALSharedConfig* config)
{
    return config != NULL &&
           config->magic == HEARTECHO_HAL_SHARED_MAGIC &&
           config->version == HEARTECHO_HAL_SHARED_VERSION &&
           config->headerSize == HEARTECHO_HAL_SHARED_HEADER_BYTES &&
           config->deviceSize == HEARTECHO_HAL_SHARED_DEVICE_BYTES &&
           config->deviceCount <= HEARTECHO_HAL_SHARED_MAX_DEVICES &&
           config->maxDevices == HEARTECHO_HAL_SHARED_MAX_DEVICES;
}

static const HeartechoHALSharedConfig* activeSharedConfig(void)
{
    const HeartechoHALSharedConfig* loaded = atomic_load(&gActiveSharedConfig);
    return sharedConfigIsValid(loaded) ? loaded : &kDefaultSharedConfig;
}

static Boolean activateSharedConfig(const HeartechoHALSharedConfig* config)
{
    if (!sharedConfigIsValid(config)) {
        return false;
    }

    const HeartechoHALSharedConfig* oldConfig = activeSharedConfig();
    HeartechoHALSharedConfig oldSnapshot = *oldConfig;
    HeartechoHALConfigChangeSummary summary = summarizeConfigChange(&oldSnapshot, config);
    gLoadedSharedConfig = *config;
    atomic_store(&gActiveSharedConfig, &gLoadedSharedConfig);
    notifyConfigChange(&oldSnapshot, &gLoadedSharedConfig, &summary);
    gLastConfigChangeSummary = summary;
    return true;
}

static HeartechoHALConfigChangeSummary summarizeConfigChange(const HeartechoHALSharedConfig* oldConfig, const HeartechoHALSharedConfig* newConfig)
{
    HeartechoHALConfigChangeSummary summary;
    memset(&summary, 0, sizeof(summary));

    if (!sharedConfigIsValid(oldConfig) || !sharedConfigIsValid(newConfig)) {
        summary.deviceListChanged = 1;
        return summary;
    }

    if (oldConfig->deviceCount != newConfig->deviceCount) {
        summary.deviceListChanged = 1;
    }

    for (UInt32 index = 0; index < newConfig->deviceCount; index += 1) {
        const HeartechoHALSharedDeviceConfig* newDevice = &newConfig->devices[index];
        const HeartechoHALSharedDeviceConfig* oldDevice = matchingDeviceByObjectID(oldConfig, newDevice->deviceObjectID);

        if (oldDevice == NULL || deviceIdentityChanged(oldDevice, newDevice)) {
            summary.deviceListChanged = 1;
        }

        if (oldDevice == NULL || deviceMetadataChanged(oldDevice, newDevice)) {
            summary.deviceMetadataChanged += 1;
        }

        if (oldDevice == NULL || deviceFormatChanged(oldDevice, newDevice)) {
            summary.deviceFormatChanged += 1;
            summary.streamFormatChanged += 2;
        }
    }

    for (UInt32 index = 0; index < oldConfig->deviceCount; index += 1) {
        const HeartechoHALSharedDeviceConfig* oldDevice = &oldConfig->devices[index];
        if (matchingDeviceByObjectID(newConfig, oldDevice->deviceObjectID) == NULL) {
            summary.deviceListChanged = 1;
            break;
        }
    }

    return summary;
}

static void notifyConfigChange(const HeartechoHALSharedConfig* oldConfig, const HeartechoHALSharedConfig* newConfig, HeartechoHALConfigChangeSummary* summary)
{
    if (summary == NULL) {
        return;
    }

    if (summary->deviceListChanged) {
        AudioObjectPropertyAddress pluginAddresses[] = {
            { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
        };
        notifyObjectProperties(kAudioObjectPlugInObject, pluginAddresses, 2, summary);
    }

    if (!sharedConfigIsValid(newConfig)) {
        return;
    }

    for (UInt32 index = 0; index < newConfig->deviceCount; index += 1) {
        const HeartechoHALSharedDeviceConfig* newDevice = &newConfig->devices[index];
        if (!newDevice->isEnabled) {
            continue;
        }

        const HeartechoHALSharedDeviceConfig* oldDevice = sharedConfigIsValid(oldConfig) ? matchingDeviceByObjectID(oldConfig, newDevice->deviceObjectID) : NULL;
        Boolean metadataChanged = oldDevice == NULL || deviceMetadataChanged(oldDevice, newDevice);
        Boolean formatChanged = oldDevice == NULL || deviceFormatChanged(oldDevice, newDevice);

        if (metadataChanged || formatChanged) {
            AudioObjectPropertyAddress deviceAddresses[5];
            UInt32 addressCount = 0;
            if (metadataChanged) {
                deviceAddresses[addressCount++] = (AudioObjectPropertyAddress){ kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                deviceAddresses[addressCount++] = (AudioObjectPropertyAddress){ kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            }
            if (formatChanged) {
                deviceAddresses[addressCount++] = (AudioObjectPropertyAddress){ kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                deviceAddresses[addressCount++] = (AudioObjectPropertyAddress){ kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                deviceAddresses[addressCount++] = (AudioObjectPropertyAddress){ kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            }
            notifyObjectProperties(newDevice->deviceObjectID, deviceAddresses, addressCount, summary);
        }

        if (formatChanged) {
            AudioObjectPropertyAddress streamAddresses[] = {
                { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
            };
            notifyObjectProperties(newDevice->inputStreamObjectID, streamAddresses, 2, summary);
            notifyObjectProperties(newDevice->outputStreamObjectID, streamAddresses, 2, summary);
        }
    }
}

static const HeartechoHALSharedDeviceConfig* matchingDeviceByObjectID(const HeartechoHALSharedConfig* config, UInt32 objectID)
{
    if (!sharedConfigIsValid(config)) {
        return NULL;
    }

    for (UInt32 index = 0; index < config->deviceCount; index += 1) {
        if (config->devices[index].deviceObjectID == objectID) {
            return &config->devices[index];
        }
    }

    return NULL;
}

static Boolean deviceIdentityChanged(const HeartechoHALSharedDeviceConfig* oldDevice, const HeartechoHALSharedDeviceConfig* newDevice)
{
    return oldDevice == NULL ||
           newDevice == NULL ||
           oldDevice->isEnabled != newDevice->isEnabled ||
           oldDevice->deviceObjectID != newDevice->deviceObjectID ||
           oldDevice->inputStreamObjectID != newDevice->inputStreamObjectID ||
           oldDevice->outputStreamObjectID != newDevice->outputStreamObjectID;
}

static Boolean deviceMetadataChanged(const HeartechoHALSharedDeviceConfig* oldDevice, const HeartechoHALSharedDeviceConfig* newDevice)
{
    return oldDevice == NULL ||
           newDevice == NULL ||
           !fixedCStringEquals(oldDevice->name, newDevice->name, HEARTECHO_HAL_SHARED_MAX_NAME_BYTES) ||
           !fixedCStringEquals(oldDevice->uid, newDevice->uid, HEARTECHO_HAL_SHARED_MAX_UID_BYTES);
}

static Boolean deviceFormatChanged(const HeartechoHALSharedDeviceConfig* oldDevice, const HeartechoHALSharedDeviceConfig* newDevice)
{
    return oldDevice == NULL ||
           newDevice == NULL ||
           oldDevice->channelCount != newDevice->channelCount ||
           oldDevice->sampleRate != newDevice->sampleRate;
}

static Boolean fixedCStringEquals(const char* left, const char* right, UInt32 maxLength)
{
    if (left == NULL || right == NULL) {
        return left == right;
    }

    return strncmp(left, right, maxLength) == 0;
}

static void notifyObjectProperties(AudioObjectID objectID, const AudioObjectPropertyAddress* addresses, UInt32 addressCount, HeartechoHALConfigChangeSummary* summary)
{
    if (addressCount == 0 || addresses == NULL || summary == NULL) {
        return;
    }

    summary->notifiedObjectCount += 1;

    if (gHost != NULL && gHost->PropertiesChanged != NULL) {
        gHost->PropertiesChanged(gHost, objectID, addressCount, addresses);
    }
}

static Boolean loadSharedConfigFromFile(const char* path, HeartechoHALSharedConfig* outConfig)
{
    if (path == NULL || outConfig == NULL) {
        return false;
    }

    FILE* file = fopen(path, "rb");
    if (file == NULL) {
        return false;
    }

    HeartechoHALSharedConfig config;
    memset(&config, 0, sizeof(config));
    size_t bytesRead = fread(&config, 1, sizeof(config), file);
    int extraByte = fgetc(file);
    int closeResult = fclose(file);

    if (bytesRead != sizeof(config) || extraByte != EOF || closeResult != 0) {
        return false;
    }

    if (!sharedConfigIsValid(&config)) {
        return false;
    }

    *outConfig = config;
    return true;
}

static Boolean loadSharedConfigFromSharedMemory(const char* name, HeartechoHALSharedConfig* outConfig)
{
    if (name == NULL || outConfig == NULL) {
        return false;
    }

    int descriptor = shm_open(name, O_RDONLY, 0);
    if (descriptor < 0) {
        return false;
    }

    void* mapped = mmap(NULL, sizeof(HeartechoHALSharedConfig), PROT_READ, MAP_SHARED, descriptor, 0);
    int closeResult = close(descriptor);
    if (mapped == MAP_FAILED || closeResult != 0) {
        if (mapped != MAP_FAILED) {
            munmap(mapped, sizeof(HeartechoHALSharedConfig));
        }
        return false;
    }

    HeartechoHALSharedConfig config;
    memcpy(&config, mapped, sizeof(config));
    int unmapResult = munmap(mapped, sizeof(HeartechoHALSharedConfig));
    if (unmapResult != 0 || !sharedConfigIsValid(&config)) {
        return false;
    }

    *outConfig = config;
    return true;
}

static Boolean audioSharedStateIsValid(const HeartechoHALAudioSharedState* state)
{
    if (state == NULL ||
        state->magic != HEARTECHO_HAL_AUDIO_SHARED_STATE_MAGIC ||
        state->version != HEARTECHO_HAL_AUDIO_SHARED_VERSION ||
        state->headerSize != HEARTECHO_HAL_AUDIO_SHARED_STATE_HEADER_BYTES ||
        state->slotCount > HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES ||
        state->maxDevices != HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES ||
        state->bufferSize != sizeof(HeartechoHALAudioSharedBuffer)) {
        return false;
    }

    for (UInt32 index = 0; index < state->slotCount; index += 1) {
        if (!audioBufferSlotIsValidOrEmpty(&state->buffers[index])) {
            return false;
        }
    }

    return true;
}

static Boolean audioBufferSlotIsValidOrEmpty(const HeartechoHALAudioSharedBuffer* buffer)
{
    if (audioBufferSlotIsEmpty(buffer)) {
        return true;
    }

    return buffer != NULL &&
           buffer->magic == HEARTECHO_HAL_AUDIO_SHARED_MAGIC &&
           buffer->version == HEARTECHO_HAL_AUDIO_SHARED_VERSION &&
           buffer->headerSize == offsetof(HeartechoHALAudioSharedBuffer, samples) &&
           buffer->deviceObjectID != 0 &&
           buffer->channelCount > 0 &&
           buffer->channelCount <= HEARTECHO_HAL_AUDIO_SHARED_MAX_CHANNELS &&
           buffer->capacityFrames == HEARTECHO_HAL_AUDIO_SHARED_CAPACITY_FRAMES;
}

static Boolean audioBufferSlotIsEmpty(const HeartechoHALAudioSharedBuffer* buffer)
{
    return buffer == NULL ||
           (buffer->magic == 0 &&
            buffer->deviceObjectID == 0 &&
            buffer->channelCount == 0 &&
            buffer->capacityFrames == 0 &&
            buffer->totalWrittenFrames == 0 &&
            buffer->totalReadFrames == 0 &&
            buffer->droppedFrameCount == 0);
}

static HeartechoHALAudioSharedState* activeAudioSharedState(void)
{
    HeartechoHALAudioSharedState* state = atomic_load(&gActiveAudioSharedState);
    return audioSharedStateIsValid(state) ? state : &gLocalAudioSharedState;
}

static void initializeAudioSharedState(HeartechoHALAudioSharedState* state)
{
    if (state == NULL) {
        return;
    }

    memset(state, 0, sizeof(*state));
    state->magic = HEARTECHO_HAL_AUDIO_SHARED_STATE_MAGIC;
    state->version = HEARTECHO_HAL_AUDIO_SHARED_VERSION;
    state->headerSize = HEARTECHO_HAL_AUDIO_SHARED_STATE_HEADER_BYTES;
    state->slotCount = HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES;
    state->maxDevices = HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES;
    state->bufferSize = sizeof(HeartechoHALAudioSharedBuffer);
}

static void resetAudioSharedState(HeartechoHALAudioSharedState* state)
{
    initializeAudioSharedState(state != NULL ? state : &gLocalAudioSharedState);
}

static Boolean openAudioSharedState(const char* name, Boolean createIfMissing)
{
    if (name == NULL) {
        return false;
    }

    size_t byteCount = sizeof(HeartechoHALAudioSharedState);
    int flags = createIfMissing ? (O_CREAT | O_RDWR) : O_RDWR;
    int descriptor = shm_open(name, flags, S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        return false;
    }

    if (createIfMissing && ftruncate(descriptor, (off_t)byteCount) != 0) {
        close(descriptor);
        return false;
    }

    void* mapped = mmap(NULL, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    int closeResult = close(descriptor);
    if (mapped == MAP_FAILED || closeResult != 0) {
        if (mapped != MAP_FAILED) {
            munmap(mapped, byteCount);
        }
        return false;
    }

    HeartechoHALAudioSharedState* state = (HeartechoHALAudioSharedState*)mapped;
    if (createIfMissing) {
        initializeAudioSharedState(state);
    } else if (!audioSharedStateIsValid(state)) {
        munmap(mapped, byteCount);
        return false;
    }

    pthread_mutex_lock(&gAudioStateMutex);
    closeMappedAudioSharedStateLocked();
    gMappedAudioSharedState = state;
    gMappedAudioSharedStateByteCount = byteCount;
    atomic_store(&gActiveAudioSharedState, state);
    pthread_mutex_unlock(&gAudioStateMutex);
    return true;
}

static void closeMappedAudioSharedStateLocked(void)
{
    HeartechoHALAudioSharedState* mapped = gMappedAudioSharedState;
    if (mapped != NULL) {
        atomic_store(&gActiveAudioSharedState, &gLocalAudioSharedState);
        munmap(mapped, gMappedAudioSharedStateByteCount);
        gMappedAudioSharedState = NULL;
        gMappedAudioSharedStateByteCount = 0;
    }
}

static void writeAudioSharedStateSnapshot(HeartechoHALAudioSharedState* outState)
{
    if (outState == NULL) {
        return;
    }

    HeartechoHALAudioSharedState* state = activeAudioSharedState();
    memcpy(outState, state, sizeof(*outState));
}

static void loadAudioSharedStateSnapshot(const HeartechoHALAudioSharedState* state)
{
    if (state == NULL || !audioSharedStateIsValid(state)) {
        return;
    }

    memcpy(activeAudioSharedState(), state, sizeof(*state));
}

static size_t copyDeviceCString(const char* source, UInt32 maxLength, char* outBuffer, size_t bufferLength)
{
    if (outBuffer == NULL || bufferLength == 0) {
        return 0;
    }

    size_t sourceLength = source != NULL ? strnlen(source, maxLength) : 0;
    size_t copyLength = sourceLength < (bufferLength - 1) ? sourceLength : (bufferLength - 1);
    if (copyLength > 0) {
        memcpy(outBuffer, source, copyLength);
    }
    outBuffer[copyLength] = '\0';
    return copyLength;
}

static UInt32 activeDeviceCount(void)
{
    const HeartechoHALSharedConfig* config = activeSharedConfig();
    if (!sharedConfigIsValid(config)) {
        config = &kDefaultSharedConfig;
    }

    UInt32 count = 0;
    for (UInt32 index = 0; index < config->deviceCount; index += 1) {
        if (config->devices[index].isEnabled) {
            count += 1;
        }
    }

    return count > 0 ? count : 1;
}

static const HeartechoHALSharedDeviceConfig* deviceConfigAtActiveIndex(UInt32 activeIndex)
{
    const HeartechoHALSharedConfig* config = activeSharedConfig();
    if (!sharedConfigIsValid(config)) {
        config = &kDefaultSharedConfig;
    }

    UInt32 enabledIndex = 0;
    for (UInt32 index = 0; index < config->deviceCount; index += 1) {
        if (!config->devices[index].isEnabled) {
            continue;
        }

        if (enabledIndex == activeIndex) {
            return &config->devices[index];
        }

        enabledIndex += 1;
    }

    return activeIndex == 0 ? &kDefaultSharedConfig.devices[0] : NULL;
}

static const HeartechoHALSharedDeviceConfig* firstDeviceConfig(void)
{
    return deviceConfigAtActiveIndex(0);
}

static const HeartechoHALSharedDeviceConfig* deviceConfigForDeviceObject(AudioObjectID objectID)
{
    const HeartechoHALSharedConfig* config = activeSharedConfig();
    if (!sharedConfigIsValid(config)) {
        config = &kDefaultSharedConfig;
    }

    for (UInt32 index = 0; index < config->deviceCount; index += 1) {
        const HeartechoHALSharedDeviceConfig* device = &config->devices[index];
        if (device->isEnabled && device->deviceObjectID == objectID) {
            return device;
        }
    }

    const HeartechoHALSharedDeviceConfig* fallback = firstDeviceConfig();
    return fallback != NULL && fallback->deviceObjectID == objectID ? fallback : NULL;
}

static const HeartechoHALSharedDeviceConfig* deviceConfigForStreamObject(AudioObjectID objectID)
{
    const HeartechoHALSharedConfig* config = activeSharedConfig();
    if (!sharedConfigIsValid(config)) {
        config = &kDefaultSharedConfig;
    }

    for (UInt32 index = 0; index < config->deviceCount; index += 1) {
        const HeartechoHALSharedDeviceConfig* device = &config->devices[index];
        if (device->isEnabled && (device->inputStreamObjectID == objectID || device->outputStreamObjectID == objectID)) {
            return device;
        }
    }

    const HeartechoHALSharedDeviceConfig* fallback = firstDeviceConfig();
    if (fallback == NULL) {
        return NULL;
    }

    return fallback->inputStreamObjectID == objectID || fallback->outputStreamObjectID == objectID ? fallback : NULL;
}

static const HeartechoHALSharedDeviceConfig* deviceConfigForObject(AudioObjectID objectID)
{
    const HeartechoHALSharedDeviceConfig* device = deviceConfigForDeviceObject(objectID);
    return device != NULL ? device : deviceConfigForStreamObject(objectID);
}

static UInt32 deviceChannelCount(const HeartechoHALSharedDeviceConfig* device)
{
    if (device == NULL || device->channelCount == 0 || device->channelCount > HEARTECHO_HAL_SHARED_MAX_CHANNELS) {
        return 2;
    }

    return device->channelCount;
}

static UInt32 deviceLatencyFrames(const HeartechoHALSharedDeviceConfig* device)
{
    return device != NULL ? device->latencyFrames : 0;
}

static UInt32 deviceSafetyOffsetFrames(const HeartechoHALSharedDeviceConfig* device)
{
    return device != NULL ? device->safetyOffsetFrames : 0;
}

static UInt32 deviceBufferFrameSize(const HeartechoHALSharedDeviceConfig* device)
{
    UInt32 frameSize = device != NULL ? device->bufferFrameSize : 512;
    if (frameSize < 16) {
        return 512;
    }
    if (frameSize > HEARTECHO_HAL_AUDIO_SHARED_CAPACITY_FRAMES) {
        return HEARTECHO_HAL_AUDIO_SHARED_CAPACITY_FRAMES;
    }
    return frameSize;
}

static UInt32 bytesPerFrameForDevice(const HeartechoHALSharedDeviceConfig* device)
{
    return sizeof(Float32) * deviceChannelCount(device);
}

static HeartechoHALAudioSharedBuffer* audioBufferForDevice(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID)
{
    if (state == NULL || !audioSharedStateIsValid(state)) {
        return NULL;
    }

    for (UInt32 index = 0; index < HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES; index += 1) {
        HeartechoHALAudioSharedBuffer* buffer = &state->buffers[index];
        if (buffer->magic == HEARTECHO_HAL_AUDIO_SHARED_MAGIC &&
            buffer->deviceObjectID == deviceObjectID) {
            return buffer;
        }
    }

    return NULL;
}

static HeartechoHALAudioSharedBuffer* audioBufferForDeviceOrEmptySlot(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID)
{
    if (state == NULL || !audioSharedStateIsValid(state)) {
        return NULL;
    }

    HeartechoHALAudioSharedBuffer* empty = NULL;

    for (UInt32 index = 0; index < HEARTECHO_HAL_AUDIO_SHARED_MAX_DEVICES; index += 1) {
        HeartechoHALAudioSharedBuffer* buffer = &state->buffers[index];
        if (buffer->magic == HEARTECHO_HAL_AUDIO_SHARED_MAGIC &&
            buffer->deviceObjectID == deviceObjectID) {
            return buffer;
        }

        if (empty == NULL && buffer->magic != HEARTECHO_HAL_AUDIO_SHARED_MAGIC) {
            empty = buffer;
        }
    }

    return empty;
}

static void initializeAudioBuffer(HeartechoHALAudioSharedBuffer* buffer, AudioObjectID deviceObjectID, UInt32 channelCount)
{
    if (buffer == NULL) {
        return;
    }

    memset(buffer, 0, sizeof(*buffer));
    buffer->magic = HEARTECHO_HAL_AUDIO_SHARED_MAGIC;
    buffer->version = HEARTECHO_HAL_AUDIO_SHARED_VERSION;
    buffer->headerSize = (UInt16)((char*)buffer->samples - (char*)buffer);
    buffer->deviceObjectID = deviceObjectID;
    buffer->channelCount = channelCount;
    buffer->capacityFrames = HEARTECHO_HAL_AUDIO_SHARED_CAPACITY_FRAMES;
}

static UInt32 audioBufferAvailableFrames(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID)
{
    HeartechoHALAudioSharedBuffer* buffer = audioBufferForDevice(state, deviceObjectID);
    if (buffer == NULL || buffer->capacityFrames == 0) {
        return 0;
    }

    UInt64 written = atomicLoadUInt64(&buffer->totalWrittenFrames);
    UInt64 read = atomicLoadUInt64(&buffer->totalReadFrames);
    UInt64 available = written >= read ? written - read : 0;
    if (available > buffer->capacityFrames) {
        return buffer->capacityFrames;
    }

    return (UInt32)available;
}

static UInt32 writeAudioFrames(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID, UInt32 channelCount, UInt32 frameCount, const Float32* interleavedFrames)
{
    if (frameCount == 0 || interleavedFrames == NULL || channelCount == 0 || channelCount > HEARTECHO_HAL_AUDIO_SHARED_MAX_CHANNELS) {
        return 0;
    }

    HeartechoHALAudioSharedBuffer* buffer = audioBufferForDeviceOrEmptySlot(state, deviceObjectID);
    if (buffer == NULL) {
        return 0;
    }

    if (buffer->magic != HEARTECHO_HAL_AUDIO_SHARED_MAGIC ||
        buffer->deviceObjectID != deviceObjectID ||
        buffer->channelCount != channelCount) {
        initializeAudioBuffer(buffer, deviceObjectID, channelCount);
    }

    for (UInt32 frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
        UInt64 writeFrameIndex = atomicLoadUInt64(&buffer->writeFrameIndex);
        UInt32 targetFrame = (UInt32)(writeFrameIndex % buffer->capacityFrames);
        UInt32 sampleBase = targetFrame * HEARTECHO_HAL_AUDIO_SHARED_MAX_CHANNELS;
        UInt32 sourceBase = frameIndex * channelCount;

        for (UInt32 channelIndex = 0; channelIndex < channelCount; channelIndex += 1) {
            buffer->samples[sampleBase + channelIndex] = interleavedFrames[sourceBase + channelIndex];
        }

        atomicStoreUInt64(&buffer->writeFrameIndex, (writeFrameIndex + 1) % buffer->capacityFrames);
        UInt64 totalWritten = atomicAddUInt64(&buffer->totalWrittenFrames, 1);
        atomicAddUInt64(&buffer->writerHeartbeat, 1);
        UInt64 totalRead = atomicLoadUInt64(&buffer->totalReadFrames);

        UInt64 available = totalWritten >= totalRead ? totalWritten - totalRead : 0;
        if (available > buffer->capacityFrames) {
            atomicStoreUInt64(&buffer->totalReadFrames, totalWritten - buffer->capacityFrames);
            atomicStoreUInt64(&buffer->readFrameIndex, atomicLoadUInt64(&buffer->writeFrameIndex));
            atomicAddUInt64(&buffer->droppedFrameCount, 1);
        }
    }

    return frameCount;
}

static UInt32 readAudioFrames(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID, UInt32 channelCount, UInt32 frameCount, Float32* outInterleavedFrames)
{
    if (frameCount == 0 || outInterleavedFrames == NULL || channelCount == 0) {
        return 0;
    }

    memset(outInterleavedFrames, 0, sizeof(Float32) * frameCount * channelCount);

    HeartechoHALAudioSharedBuffer* buffer = audioBufferForDevice(state, deviceObjectID);
    if (buffer == NULL || buffer->channelCount != channelCount) {
        recordRealtimeAudioRead(frameCount, 0);
        return 0;
    }

    UInt32 readableFrames = audioBufferAvailableFrames(state, deviceObjectID);
    if (readableFrames > frameCount) {
        readableFrames = frameCount;
    }

    for (UInt32 frameIndex = 0; frameIndex < readableFrames; frameIndex += 1) {
        UInt64 readFrameIndex = atomicLoadUInt64(&buffer->readFrameIndex);
        UInt32 sourceFrame = (UInt32)(readFrameIndex % buffer->capacityFrames);
        UInt32 sourceBase = sourceFrame * HEARTECHO_HAL_AUDIO_SHARED_MAX_CHANNELS;
        UInt32 targetBase = frameIndex * channelCount;

        for (UInt32 channelIndex = 0; channelIndex < channelCount; channelIndex += 1) {
            outInterleavedFrames[targetBase + channelIndex] = buffer->samples[sourceBase + channelIndex];
        }

        atomicStoreUInt64(&buffer->readFrameIndex, (readFrameIndex + 1) % buffer->capacityFrames);
        atomicAddUInt64(&buffer->totalReadFrames, 1);
        atomicAddUInt64(&buffer->readerHeartbeat, 1);
    }

    recordRealtimeAudioRead(frameCount, readableFrames);
    return readableFrames;
}

static HeartechoHALAudioBufferStats audioBufferStats(HeartechoHALAudioSharedState* state, AudioObjectID deviceObjectID)
{
    HeartechoHALAudioBufferStats stats = {0};
    HeartechoHALAudioSharedBuffer* buffer = audioBufferForDevice(state, deviceObjectID);
    if (buffer == NULL) {
        return stats;
    }

    stats.deviceObjectID = buffer->deviceObjectID;
    stats.channelCount = buffer->channelCount;
    stats.capacityFrames = buffer->capacityFrames;
    stats.availableFrames = audioBufferAvailableFrames(state, deviceObjectID);
    stats.totalWrittenFrames = atomicLoadUInt64(&buffer->totalWrittenFrames);
    stats.totalReadFrames = atomicLoadUInt64(&buffer->totalReadFrames);
    stats.droppedFrameCount = atomicLoadUInt64(&buffer->droppedFrameCount);
    stats.writerHeartbeat = atomicLoadUInt64(&buffer->writerHeartbeat);
    stats.readerHeartbeat = atomicLoadUInt64(&buffer->readerHeartbeat);
    return stats;
}

static void recordRealtimeAudioRead(UInt32 requestedFrames, UInt32 readableFrames)
{
    atomic_fetch_add(&gRealtimeAudioReadCallCount, 1);
    atomic_fetch_add(&gRealtimeAudioReadFrameCount, readableFrames);
    if (requestedFrames > readableFrames) {
        atomic_fetch_add(&gRealtimeZeroFillFrameCount, requestedFrames - readableFrames);
    }
}

static UInt64 atomicLoadUInt64(const UInt64* value)
{
    return value != NULL ? atomic_load_explicit((_Atomic UInt64*)value, memory_order_acquire) : 0;
}

static void atomicStoreUInt64(UInt64* value, UInt64 newValue)
{
    if (value != NULL) {
        atomic_store_explicit((_Atomic UInt64*)value, newValue, memory_order_release);
    }
}

static UInt64 atomicAddUInt64(UInt64* value, UInt64 increment)
{
    if (value == NULL) {
        return 0;
    }

    return atomic_fetch_add_explicit((_Atomic UInt64*)value, increment, memory_order_acq_rel) + increment;
}

static UInt32 atomicLoadUInt32(const UInt32* value)
{
    return value != NULL ? atomic_load_explicit((_Atomic UInt32*)value, memory_order_acquire) : 0;
}

static void atomicStoreUInt32(UInt32* value, UInt32 newValue)
{
    if (value != NULL) {
        atomic_store_explicit((_Atomic UInt32*)value, newValue, memory_order_release);
    }
}

static HRESULT STDMETHODCALLTYPE QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface)
{
    (void)driver;

    if (outInterface == NULL) {
        return E_POINTER;
    }

    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    Boolean matches = CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID) || CFEqual(requestedUUID, IUnknownUUID);
    CFRelease(requestedUUID);

    if (!matches) {
        *outInterface = NULL;
        return E_NOINTERFACE;
    }

    AddRef(&gDriverInterfacePtr);
    *outInterface = &gDriverInterfacePtr;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE AddRef(void* driver)
{
    (void)driver;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG STDMETHODCALLTYPE Release(void* driver)
{
    (void)driver;
    unsigned int value = atomic_fetch_sub(&gRefCount, 1) - 1;
    return value;
}

static OSStatus STDMETHODCALLTYPE Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host)
{
    (void)driver;
    gHost = host;
    HeartechoHALDriverLoadSharedConfigFromSharedMemory(kDefaultConfigSharedMemoryName);
    HeartechoHALDriverOpenAudioBuffersSharedMemory(kDefaultAudioSharedMemoryName, false);
    return noErr;
}

static OSStatus STDMETHODCALLTYPE CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)driver;
    (void)description;
    (void)clientInfo;

    if (outDeviceObjectID == NULL) {
        return kAudioHardwareBadObjectError;
    }

    const HeartechoHALSharedDeviceConfig* device = firstDeviceConfig();
    if (device == NULL) {
        return kAudioHardwareBadObjectError;
    }

    *outDeviceObjectID = device->deviceObjectID;
    return noErr;
}

static OSStatus STDMETHODCALLTYPE DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID)
{
    (void)driver;
    return deviceConfigForDeviceObject(deviceObjectID) != NULL ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo* clientInfo)
{
    (void)driver;
    (void)clientInfo;
    return deviceConfigForDeviceObject(deviceObjectID) != NULL ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo* clientInfo)
{
    (void)driver;
    (void)clientInfo;
    return deviceConfigForDeviceObject(deviceObjectID) != NULL ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo)
{
    (void)driver;
    (void)changeAction;
    (void)changeInfo;
    return deviceConfigForDeviceObject(deviceObjectID) != NULL ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo)
{
    (void)driver;
    (void)changeAction;
    (void)changeInfo;
    return deviceConfigForDeviceObject(deviceObjectID) != NULL ? noErr : kAudioHardwareBadObjectError;
}

static Boolean objectExists(AudioObjectID objectID)
{
    return objectID == kAudioObjectPlugInObject || deviceConfigForObject(objectID) != NULL;
}

static Boolean STDMETHODCALLTYPE HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address)
{
    (void)driver;
    (void)clientProcessID;

    if (address == NULL || !objectExists(objectID)) {
        return false;
    }

    switch (objectID) {
        case kAudioObjectPlugInObject:
            return address->mSelector == kAudioObjectPropertyOwnedObjects ||
                   address->mSelector == kAudioPlugInPropertyDeviceList;
        default:
            if (deviceConfigForDeviceObject(objectID) == NULL) {
                break;
            }

            return address->mSelector == kAudioObjectPropertyName ||
                   address->mSelector == kAudioObjectPropertyManufacturer ||
                   address->mSelector == kAudioDevicePropertyDeviceUID ||
                   address->mSelector == kAudioDevicePropertyNominalSampleRate ||
                   address->mSelector == kAudioDevicePropertyStreamConfiguration ||
                   address->mSelector == kAudioObjectPropertyOwnedObjects ||
                   address->mSelector == kAudioDevicePropertyDeviceIsAlive ||
                   address->mSelector == kAudioDevicePropertyDeviceIsRunning ||
                   address->mSelector == kAudioDevicePropertyLatency ||
                   address->mSelector == kAudioDevicePropertySafetyOffset ||
                   address->mSelector == kAudioDevicePropertyBufferFrameSize ||
                   address->mSelector == kAudioDevicePropertyBufferFrameSizeRange ||
                   address->mSelector == kAudioDevicePropertyTransportType;
    }

    if (deviceConfigForStreamObject(objectID) != NULL) {
        switch (address->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return true;
        default:
            return false;
        }
    }

    return false;
}

static OSStatus STDMETHODCALLTYPE IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable)
{
    (void)driver;
    (void)objectID;
    (void)clientProcessID;
    (void)address;

    if (outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    *outIsSettable = false;
    return noErr;
}

static UInt32 propertyDataSize(AudioObjectID objectID, const AudioObjectPropertyAddress* address)
{
    if (address == NULL) {
        return 0;
    }

    switch (address->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
            return sizeof(CFStringRef);
        case kAudioPlugInPropertyDeviceList:
            return sizeof(AudioObjectID) * activeDeviceCount();
        case kAudioObjectPropertyOwnedObjects:
            return objectID == kAudioObjectPlugInObject ? sizeof(AudioObjectID) * activeDeviceCount() : sizeof(AudioObjectID) * 2;
        case kAudioDevicePropertyNominalSampleRate:
            return sizeof(Float64);
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyTransportType:
            return sizeof(UInt32);
        case kAudioDevicePropertyBufferFrameSizeRange:
            return sizeof(AudioValueRange);
        case kAudioDevicePropertyStreamConfiguration:
            return sizeof(AudioBufferList) + sizeof(AudioBuffer) * 1;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return sizeof(AudioStreamBasicDescription);
        default:
            return 0;
    }
}

static OSStatus STDMETHODCALLTYPE GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32* outDataSize)
{
    (void)driver;
    (void)clientProcessID;
    (void)qualifierDataSize;
    (void)qualifierData;

    if (outDataSize == NULL || !HasProperty(driver, objectID, clientProcessID, address)) {
        return kAudioHardwareUnknownPropertyError;
    }

    *outDataSize = propertyDataSize(objectID, address);
    return noErr;
}

static AudioStreamBasicDescription streamFormat(const HeartechoHALSharedDeviceConfig* device)
{
    UInt32 bytesPerFrame = bytesPerFrameForDevice(device);
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = device != NULL && device->sampleRate > 0.0 ? device->sampleRate : 48000.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = bytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = bytesPerFrame;
    format.mChannelsPerFrame = deviceChannelCount(device);
    format.mBitsPerChannel = sizeof(Float32) * 8;
    return format;
}

static OSStatus copyString(CFStringRef value, UInt32 dataSize, UInt32* outDataSize, void* outData)
{
    if (dataSize < sizeof(CFStringRef)) {
        return kAudioHardwareBadPropertySizeError;
    }

    CFStringRef retained = CFRetain(value);
    *((CFStringRef*)outData) = retained;
    *outDataSize = sizeof(CFStringRef);
    return noErr;
}

static OSStatus copyCString(const char* value, UInt32 maxLength, UInt32 dataSize, UInt32* outDataSize, void* outData)
{
    CFStringRef string = NULL;
    if (value != NULL && maxLength > 0 && value[0] != '\0') {
        string = CFStringCreateWithBytes(NULL, (const UInt8*)value, strnlen(value, maxLength), kCFStringEncodingUTF8, false);
    }

    if (string == NULL) {
        string = CFStringCreateWithCString(NULL, "Heartecho", kCFStringEncodingUTF8);
    }

    OSStatus status = copyString(string, dataSize, outDataSize, outData);
    CFRelease(string);
    return status;
}

static const char* streamName(AudioObjectID objectID, const HeartechoHALSharedDeviceConfig* device)
{
    if (device != NULL && objectID == device->inputStreamObjectID) {
        return "Heartecho Input Stream";
    }

    if (device != NULL && objectID == device->outputStreamObjectID) {
        return "Heartecho Output Stream";
    }

    return "Heartecho Stream";
}

static OSStatus STDMETHODCALLTYPE GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, UInt32* outDataSize, void* outData)
{
    (void)qualifierDataSize;
    (void)qualifierData;

    if (outData == NULL || outDataSize == NULL || !HasProperty(driver, objectID, clientProcessID, address)) {
        return kAudioHardwareUnknownPropertyError;
    }

    const HeartechoHALSharedDeviceConfig* device = deviceConfigForObject(objectID);

    switch (address->mSelector) {
        case kAudioObjectPropertyName:
            if (objectID == kAudioObjectPlugInObject) {
                return copyString(CFSTR("Heartecho HAL Driver"), dataSize, outDataSize, outData);
            }

            if (deviceConfigForDeviceObject(objectID) != NULL) {
                return copyCString(device->name, HEARTECHO_HAL_SHARED_MAX_NAME_BYTES, dataSize, outDataSize, outData);
            }

            return copyCString(streamName(objectID, device), 64, dataSize, outDataSize, outData);
        case kAudioObjectPropertyManufacturer:
            return copyString(CFSTR("Heartecho"), dataSize, outDataSize, outData);
        case kAudioDevicePropertyDeviceUID:
            if (device == NULL) {
                return kAudioHardwareBadObjectError;
            }
            return copyCString(device->uid, HEARTECHO_HAL_SHARED_MAX_UID_BYTES, dataSize, outDataSize, outData);
        case kAudioPlugInPropertyDeviceList: {
            UInt32 count = activeDeviceCount();
            UInt32 required = sizeof(AudioObjectID) * count;
            if (dataSize < required) return kAudioHardwareBadPropertySizeError;
            for (UInt32 index = 0; index < count; index += 1) {
                const HeartechoHALSharedDeviceConfig* activeDevice = deviceConfigAtActiveIndex(index);
                ((AudioObjectID*)outData)[index] = activeDevice != NULL ? activeDevice->deviceObjectID : kDefaultSharedConfig.devices[0].deviceObjectID;
            }
            *outDataSize = required;
            return noErr;
        }
        case kAudioObjectPropertyOwnedObjects:
            if (objectID == kAudioObjectPlugInObject) {
                UInt32 count = activeDeviceCount();
                UInt32 required = sizeof(AudioObjectID) * count;
                if (dataSize < required) return kAudioHardwareBadPropertySizeError;
                for (UInt32 index = 0; index < count; index += 1) {
                    const HeartechoHALSharedDeviceConfig* activeDevice = deviceConfigAtActiveIndex(index);
                    ((AudioObjectID*)outData)[index] = activeDevice != NULL ? activeDevice->deviceObjectID : kDefaultSharedConfig.devices[0].deviceObjectID;
                }
                *outDataSize = required;
                return noErr;
            }

            if (device == NULL) return kAudioHardwareBadObjectError;
            if (dataSize < sizeof(AudioObjectID) * 2) return kAudioHardwareBadPropertySizeError;
            ((AudioObjectID*)outData)[0] = device->inputStreamObjectID;
            ((AudioObjectID*)outData)[1] = device->outputStreamObjectID;
            *outDataSize = sizeof(AudioObjectID) * 2;
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            if (dataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            *((Float64*)outData) = device != NULL && device->sampleRate > 0.0 ? device->sampleRate : 48000.0;
            *outDataSize = sizeof(Float64);
            return noErr;
        case kAudioDevicePropertyDeviceIsAlive:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = device != NULL && device->isEnabled ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyDeviceIsRunning:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = atomic_load(&gIsRunning) ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = address->mSelector == kAudioDevicePropertyLatency
                ? deviceLatencyFrames(device)
                : deviceSafetyOffsetFrames(device);
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyBufferFrameSize:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = deviceBufferFrameSize(device);
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyBufferFrameSizeRange: {
            if (dataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
            AudioValueRange* range = (AudioValueRange*)outData;
            range->mMinimum = 16;
            range->mMaximum = HEARTECHO_HAL_AUDIO_SHARED_CAPACITY_FRAMES;
            *outDataSize = sizeof(AudioValueRange);
            return noErr;
        }
        case kAudioDevicePropertyTransportType:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyStreamConfiguration: {
            UInt32 required = sizeof(AudioBufferList) + sizeof(AudioBuffer);
            if (dataSize < required) return kAudioHardwareBadPropertySizeError;
            AudioBufferList* list = (AudioBufferList*)outData;
            list->mNumberBuffers = 1;
            list->mBuffers[0].mNumberChannels = deviceChannelCount(device);
            list->mBuffers[0].mDataByteSize = 0;
            list->mBuffers[0].mData = NULL;
            *outDataSize = required;
            return noErr;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (dataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            *((AudioStreamBasicDescription*)outData) = streamFormat(device);
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus STDMETHODCALLTYPE SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, const void* data)
{
    (void)driver;
    (void)objectID;
    (void)clientProcessID;
    (void)address;
    (void)qualifierDataSize;
    (void)qualifierData;
    (void)dataSize;
    (void)data;
    return kAudioHardwareIllegalOperationError;
}

static OSStatus STDMETHODCALLTYPE StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID)
{
    (void)driver;
    (void)clientID;

    if (deviceConfigForDeviceObject(deviceObjectID) == NULL) {
        return kAudioHardwareBadObjectError;
    }

    atomic_store(&gIsRunning, true);
    return noErr;
}

static OSStatus STDMETHODCALLTYPE StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID)
{
    (void)driver;
    (void)clientID;

    if (deviceConfigForDeviceObject(deviceObjectID) == NULL) {
        return kAudioHardwareBadObjectError;
    }

    atomic_store(&gIsRunning, false);
    return noErr;
}

static OSStatus STDMETHODCALLTYPE GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)driver;
    (void)clientID;

    if (deviceConfigForDeviceObject(deviceObjectID) == NULL || outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareBadObjectError;
    }

    *outSampleTime = (Float64)atomic_load(&gSampleTime);
    *outHostTime = atomic_load(&gHostTime);
    *outSeed = atomic_load(&gSeed);
    return noErr;
}

static OSStatus STDMETHODCALLTYPE WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)driver;
    (void)clientID;

    if (deviceConfigForDeviceObject(deviceObjectID) == NULL || outWillDo == NULL || outWillDoInPlace == NULL) {
        return kAudioHardwareBadObjectError;
    }

    *outWillDo = operationID == kAudioServerPlugInIOOperationReadInput || operationID == kAudioServerPlugInIOOperationWriteMix;
    *outWillDoInPlace = true;
    return noErr;
}

static OSStatus STDMETHODCALLTYPE BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo)
{
    (void)driver;
    (void)clientID;
    (void)operationID;
    (void)ioBufferFrameSize;
    (void)ioCycleInfo;
    return deviceConfigForDeviceObject(deviceObjectID) != NULL ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)driver;
    (void)streamObjectID;
    (void)clientID;
    (void)ioCycleInfo;
    (void)ioSecondaryBuffer;

    const HeartechoHALSharedDeviceConfig* device = deviceConfigForDeviceObject(deviceObjectID);
    if (device == NULL) {
        return kAudioHardwareBadObjectError;
    }

    if ((operationID == kAudioServerPlugInIOOperationReadInput || operationID == kAudioServerPlugInIOOperationWriteMix) && ioMainBuffer != NULL) {
        UInt32 channelCount = deviceChannelCount(device);
        atomic_fetch_add(&gRealtimeIOOperationCount, 1);
        readAudioFrames(activeAudioSharedState(), deviceObjectID, channelCount, ioBufferFrameSize, (Float32*)ioMainBuffer);
    }

    atomic_fetch_add(&gSampleTime, ioBufferFrameSize);
    return noErr;
}

static OSStatus STDMETHODCALLTYPE EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo)
{
    (void)driver;
    (void)clientID;
    (void)operationID;
    (void)ioBufferFrameSize;
    if (ioCycleInfo != NULL) {
        atomic_store(&gHostTime, ioCycleInfo->mCurrentTime.mHostTime);
    }
    return deviceConfigForDeviceObject(deviceObjectID) != NULL ? noErr : kAudioHardwareBadObjectError;
}
