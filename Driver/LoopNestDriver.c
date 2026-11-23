// LoopNest virtual audio driver (AudioServerPlugIn).
// Publishes up to 8 loopback devices. Whatever is played to a device's output is available on its input.
// Device names / channel counts come from /Library/Application Support/LoopNest/devices.plist.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define MAX_DEVICES   8
#define MAX_CHANNELS  64
#define RING_FRAMES   16384
#define ZTS_PERIOD    16384
#define PLUGIN_ID     1

static const Float64 kRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define NUM_RATES 4

typedef struct {
    int slot;
    char name[128];
    UInt32 channels;
    Float64 rate;
    UInt64 anchor;
    UInt32 ioCount;
    double ticksPerFrame;
    Float32 *ring;
} Dev;

static Dev gDev[MAX_DEVICES];
static int gCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static double gTicksPerSecond = 0;

static inline AudioObjectID DevObj(int i)    { return 10 + i * 10; }
static inline AudioObjectID InStreamObj(int i)  { return 11 + i * 10; }
static inline AudioObjectID OutStreamObj(int i) { return 12 + i * 10; }

// Resolve an object id to device index + role (0 device, 1 input stream, 2 output stream). Returns -1 if unknown.
static int Resolve(AudioObjectID obj, int *role) {
    if (obj < 10) return -1;
    int idx = (int)((obj - 10) / 10);
    int r = (int)((obj - 10) % 10);
    if (idx >= gCount || r > 2) return -1;
    *role = r;
    return idx;
}

static void UpdateTiming(Dev *d) {
    d->ticksPerFrame = gTicksPerSecond / d->rate;
}

// MARK: - Config
static void LoadConfig(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    gTicksPerSecond = 1.0e9 * (double)tb.denom / (double)tb.numer;
    gCount = 0;

    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/Library/Application Support/LoopNest/devices.plist"), kCFURLPOSIXPathStyle, false);
    CFDataRef data = NULL; CFPropertyListRef plist = NULL;
    if (url) {
        CFURLCreateDataAndPropertiesFromResource(NULL, url, &data, NULL, NULL, NULL);
        CFRelease(url);
    }
    if (data) { plist = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL); CFRelease(data); }
    if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        CFArrayRef list = CFDictionaryGetValue(plist, CFSTR("devices"));
        if (list && CFGetTypeID(list) == CFArrayGetTypeID()) {
            for (CFIndex i = 0; i < CFArrayGetCount(list) && gCount < MAX_DEVICES; i++) {
                CFDictionaryRef e = CFArrayGetValueAtIndex(list, i);
                if (CFGetTypeID(e) != CFDictionaryGetTypeID()) continue;
                int slot = i; SInt32 ch = 2;
                CFNumberRef n = CFDictionaryGetValue(e, CFSTR("slot")); if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &slot);
                n = CFDictionaryGetValue(e, CFSTR("channels")); if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &ch);
                Dev *d = &gDev[gCount];
                memset(d, 0, sizeof(*d));
                d->slot = slot;
                d->channels = (UInt32)(ch < 2 ? 2 : (ch > MAX_CHANNELS ? MAX_CHANNELS : ch));
                CFStringRef nm = CFDictionaryGetValue(e, CFSTR("name"));
                if (nm) CFStringGetCString(nm, d->name, sizeof(d->name), kCFStringEncodingUTF8);
                if (!d->name[0]) snprintf(d->name, sizeof(d->name), "LoopNest %d", slot + 1);
                gCount++;
            }
        }
    }
    if (plist) CFRelease(plist);
    if (gCount == 0) {   // defaults
        for (int i = 0; i < 2; i++) {
            Dev *d = &gDev[gCount++];
            memset(d, 0, sizeof(*d));
            d->slot = i; d->channels = 2;
            snprintf(d->name, sizeof(d->name), "LoopNest %d", i + 1);
        }
    }
    for (int i = 0; i < gCount; i++) {
        Dev *d = &gDev[i];
        d->rate = 48000.0;
        UpdateTiming(d);
        d->ring = (Float32 *)calloc((size_t)RING_FRAMES * d->channels, sizeof(Float32));
    }
}

// MARK: - Helpers
static void FillASBD(const Dev *d, Float64 rate, AudioStreamBasicDescription *f) {
    f->mSampleRate = rate;
    f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f->mBytesPerPacket = 4 * d->channels;
    f->mFramesPerPacket = 1;
    f->mBytesPerFrame = 4 * d->channels;
    f->mChannelsPerFrame = d->channels;
    f->mBitsPerChannel = 32;
    f->mReserved = 0;
}

#define OUT_SCALAR(type, val) do { \
    if (outData) { if (inSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type *)outData = (val); } \
    *outSize = sizeof(type); return kAudioHardwareNoError; } while (0)

#define OUT_STRING(cstr) do { \
    if (outData) { if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; \
        *(CFStringRef *)outData = CFStringCreateWithCString(NULL, (cstr), kCFStringEncodingUTF8); } \
    *outSize = sizeof(CFStringRef); return kAudioHardwareNoError; } while (0)

static OSStatus OutArray(const void *src, UInt32 bytes, UInt32 inSize, UInt32 *outSize, void *outData) {
    if (outData) {
        UInt32 n = bytes < inSize ? bytes : inSize;
        memcpy(outData, src, n);
        *outSize = n;
    } else {
        *outSize = bytes;
    }
    return kAudioHardwareNoError;
}

// MARK: - Property access
static OSStatus GetProp(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                        UInt32 inSize, UInt32 *outSize, void *outData) {
    if (obj == PLUGIN_ID) {
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass: OUT_SCALAR(AudioClassID, kAudioObjectClassID);
            case kAudioObjectPropertyClass:     OUT_SCALAR(AudioClassID, kAudioPlugInClassID);
            case kAudioObjectPropertyOwner:     OUT_SCALAR(AudioObjectID, kAudioObjectUnknown);
            case kAudioObjectPropertyManufacturer: OUT_STRING("LoopNest");
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                AudioObjectID ids[MAX_DEVICES];
                for (int i = 0; i < gCount; i++) ids[i] = DevObj(i);
                return OutArray(ids, gCount * sizeof(AudioObjectID), inSize, outSize, outData);
            }
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                AudioObjectID result = kAudioObjectUnknown;
                if (qData && qSize == sizeof(CFStringRef)) {
                    CFStringRef uid = *(CFStringRef *)qData;
                    for (int i = 0; i < gCount; i++) {
                        char buf[32]; snprintf(buf, sizeof(buf), "LoopNest.%d", gDev[i].slot);
                        CFStringRef s = CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
                        if (CFEqual(uid, s)) result = DevObj(i);
                        CFRelease(s);
                    }
                }
                OUT_SCALAR(AudioObjectID, result);
            }
            case kAudioPlugInPropertyResourceBundle: OUT_STRING("");
        }
        return kAudioHardwareUnknownPropertyError;
    }

    int role = 0;
    int i = Resolve(obj, &role);
    if (i < 0) return kAudioHardwareBadObjectError;
    Dev *d = &gDev[i];

    if (role == 0) {   // device
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass: OUT_SCALAR(AudioClassID, kAudioObjectClassID);
            case kAudioObjectPropertyClass:     OUT_SCALAR(AudioClassID, kAudioDeviceClassID);
            case kAudioObjectPropertyOwner:     OUT_SCALAR(AudioObjectID, PLUGIN_ID);
            case kAudioObjectPropertyName:      OUT_STRING(d->name);
            case kAudioObjectPropertyManufacturer: OUT_STRING("LoopNest");
            case kAudioObjectPropertyOwnedObjects: {
                AudioObjectID ids[2] = { InStreamObj(i), OutStreamObj(i) };
                return OutArray(ids, sizeof(ids), inSize, outSize, outData);
            }
            case kAudioDevicePropertyDeviceUID: { char b[32]; snprintf(b, sizeof(b), "LoopNest.%d", d->slot); OUT_STRING(b); }
            case kAudioDevicePropertyModelUID:  OUT_STRING("LoopNestLoopbackModel");
            case kAudioDevicePropertyTransportType: OUT_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
            case kAudioDevicePropertyRelatedDevices: { AudioObjectID id = DevObj(i); return OutArray(&id, sizeof(id), inSize, outSize, outData); }
            case kAudioDevicePropertyClockDomain: OUT_SCALAR(UInt32, 0);
            case kAudioDevicePropertyDeviceIsAlive: OUT_SCALAR(UInt32, 1);
            case kAudioDevicePropertyDeviceIsRunning: OUT_SCALAR(UInt32, d->ioCount > 0 ? 1 : 0);
            case kAudioDevicePropertyDeviceCanBeDefaultDevice: OUT_SCALAR(UInt32, 1);
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: OUT_SCALAR(UInt32, 1);
            case kAudioDevicePropertyLatency: OUT_SCALAR(UInt32, 0);
            case kAudioDevicePropertySafetyOffset: OUT_SCALAR(UInt32, 0);
            case kAudioDevicePropertyStreams: {
                AudioObjectID ids[2]; UInt32 n = 0;
                if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeInput) ids[n++] = InStreamObj(i);
                if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeOutput) ids[n++] = OutStreamObj(i);
                return OutArray(ids, n * sizeof(AudioObjectID), inSize, outSize, outData);
            }
            case kAudioObjectPropertyControlList: *outSize = 0; return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate: OUT_SCALAR(Float64, d->rate);
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange r[NUM_RATES];
                for (int k = 0; k < NUM_RATES; k++) { r[k].mMinimum = kRates[k]; r[k].mMaximum = kRates[k]; }
                return OutArray(r, sizeof(r), inSize, outSize, outData);
            }
            case kAudioDevicePropertyIsHidden: OUT_SCALAR(UInt32, 0);
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                UInt32 ch[2] = { 1, 2 };
                return OutArray(ch, sizeof(ch), inSize, outSize, outData);
            }
            case kAudioDevicePropertyZeroTimeStampPeriod: OUT_SCALAR(UInt32, ZTS_PERIOD);
        }
        return kAudioHardwareUnknownPropertyError;
    }

    // streams
    bool isInput = (role == 1);
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: OUT_SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     OUT_SCALAR(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:     OUT_SCALAR(AudioObjectID, DevObj(i));
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:  OUT_SCALAR(UInt32, 1);
        case kAudioStreamPropertyDirection: OUT_SCALAR(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType: OUT_SCALAR(UInt32, isInput ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: OUT_SCALAR(UInt32, 1);
        case kAudioStreamPropertyLatency: OUT_SCALAR(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription f; FillASBD(d, d->rate, &f);
            OUT_SCALAR(AudioStreamBasicDescription, f);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r[NUM_RATES];
            for (int k = 0; k < NUM_RATES; k++) {
                FillASBD(d, kRates[k], &r[k].mFormat);
                r[k].mSampleRateRange.mMinimum = kRates[k]; r[k].mSampleRateRange.mMaximum = kRates[k];
            }
            return OutArray(r, sizeof(r), inSize, outSize, outData);
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - Interface implementation
static HRESULT QueryInterface(void *drv, REFIID uuid, LPVOID *out) {
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    CFUUIDRef iface = CFUUIDGetConstantUUIDWithBytes(NULL, 0xEE,0xA5,0x77,0x3D,0xCC,0x43,0x49,0xF1,0x8E,0x00,0x8F,0x96,0xE7,0xD2,0x3B,0x17); // kAudioServerPlugInDriverInterfaceUUID
    CFUUIDRef unk = CFUUIDGetConstantUUIDWithBytes(NULL, 0,0,0,0,0,0,0,0xC0,0,0,0,0,0,0,0,0x46);          // IUnknown
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, iface) || CFEqual(req, unk)) {
        pthread_mutex_lock(&gMutex); gRefCount++; pthread_mutex_unlock(&gMutex);
        *out = drv; r = S_OK;
    }
    CFRelease(req);
    return r;
}
static ULONG AddRef(void *drv) { pthread_mutex_lock(&gMutex); ULONG r = ++gRefCount; pthread_mutex_unlock(&gMutex); return r; }
static ULONG Release(void *drv) { pthread_mutex_lock(&gMutex); if (gRefCount) gRefCount--; ULONG r = gRefCount; pthread_mutex_unlock(&gMutex); return r; }

static OSStatus Initialize(AudioServerPlugInDriverRef drv, AudioServerPlugInHostRef host) { gHost = host; LoadConfig(); return 0; }
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *out) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *ci) { return 0; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *ci) { return 0; }

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt64 action, void *info) {
    int role; int i = Resolve(dev, &role);
    if (i < 0 || role != 0) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    gDev[i].rate = (Float64)action;
    UpdateTiming(&gDev[i]);
    pthread_mutex_unlock(&gMutex);
    return 0;
}
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt64 action, void *info) { return 0; }

static Boolean HasProperty(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    UInt32 sz = 0;
    return GetProp(obj, a, 0, NULL, 0, &sz, NULL) == kAudioHardwareNoError;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    UInt32 sz = 0;
    OSStatus st = GetProp(obj, a, 0, NULL, 0, &sz, NULL);
    if (st != kAudioHardwareNoError) return st;
    *out = (a->mSelector == kAudioDevicePropertyNominalSampleRate ||
            a->mSelector == kAudioStreamPropertyVirtualFormat ||
            a->mSelector == kAudioStreamPropertyPhysicalFormat);
    return 0;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                    UInt32 qs, const void *q, UInt32 *outSize) {
    return GetProp(obj, a, qs, q, 0, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qs, const void *q, UInt32 inSize, UInt32 *outSize, void *outData) {
    return GetProp(obj, a, qs, q, inSize, outSize, outData);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qs, const void *q, UInt32 inSize, const void *inData) {
    int role; int i = Resolve(obj, &role);
    if (i < 0) return kAudioHardwareBadObjectError;
    Float64 newRate = 0;
    if (role == 0 && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        newRate = *(const Float64 *)inData;
    } else if (role != 0 && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        newRate = ((const AudioStreamBasicDescription *)inData)->mSampleRate;
    } else {
        return kAudioHardwareUnsupportedOperationError;
    }
    bool ok = false;
    for (int k = 0; k < NUM_RATES; k++) if (kRates[k] == newRate) ok = true;
    if (!ok) return kAudioDeviceUnsupportedFormatError;
    if (newRate != gDev[i].rate && gHost)
        gHost->RequestDeviceConfigurationChange(gHost, DevObj(i), (UInt64)newRate, NULL);
    return 0;
}

static OSStatus StartIO(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client) {
    int role; int i = Resolve(dev, &role);
    if (i < 0) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    Dev *d = &gDev[i];
    if (d->ioCount == 0) {
        d->anchor = mach_absolute_time();
        memset(d->ring, 0, (size_t)RING_FRAMES * d->channels * sizeof(Float32));
    }
    d->ioCount++;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus StopIO(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client) {
    int role; int i = Resolve(dev, &role);
    if (i < 0) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gDev[i].ioCount > 0) gDev[i].ioCount--;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client,
                                 Float64 *outSample, UInt64 *outHost, UInt64 *outSeed) {
    int role; int i = Resolve(dev, &role);
    if (i < 0) return kAudioHardwareBadObjectError;
    Dev *d = &gDev[i];
    UInt64 now = mach_absolute_time();
    UInt64 ticksPerPeriod = (UInt64)(d->ticksPerFrame * (double)ZTS_PERIOD);
    UInt64 periods = (now - d->anchor) / ticksPerPeriod;
    *outSample = (Float64)(periods * ZTS_PERIOD);
    *outHost = d->anchor + periods * ticksPerPeriod;
    *outSeed = 1;
    return 0;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client, UInt32 op, Boolean *willDo, Boolean *inPlace) {
    *willDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    *inPlace = true;
    return 0;
}
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) { return 0; }
static OSStatus EndIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) { return 0; }

static OSStatus DoIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID dev, AudioObjectID stream, UInt32 client,
                              UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci, void *mainBuf, void *secBuf) {
    int role; int i = Resolve(dev, &role);
    if (i < 0) return kAudioHardwareBadObjectError;
    Dev *d = &gDev[i];
    UInt32 ch = d->channels;
    Float32 *buf = (Float32 *)mainBuf;
    if (op == kAudioServerPlugInIOOperationReadInput) {
        UInt64 t = (UInt64)ci->mInputTime.mSampleTime;
        for (UInt32 f = 0; f < frames; f++) {
            UInt32 idx = (UInt32)((t + f) % RING_FRAMES);
            memcpy(&buf[(size_t)f * ch], &d->ring[(size_t)idx * ch], ch * sizeof(Float32));
        }
    } else if (op == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 t = (UInt64)ci->mOutputTime.mSampleTime;
        for (UInt32 f = 0; f < frames; f++) {
            UInt32 idx = (UInt32)((t + f) % RING_FRAMES);
            memcpy(&d->ring[(size_t)idx * ch], &buf[(size_t)f * ch], ch * sizeof(Float32));
        }
    }
    return 0;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformDeviceConfigurationChange, AbortDeviceConfigurationChange, HasProperty, IsPropertySettable,
    GetPropertyDataSize, GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp,
    WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

void *LoopNest_Create(CFAllocatorRef alloc, CFUUIDRef typeUUID) {
    // kAudioServerPlugInTypeUUID = 443ABAB8-E7B3-491A-B985-BEB9187030DB
    CFUUIDRef plugType = CFUUIDGetConstantUUIDWithBytes(NULL, 0x44,0x3A,0xBA,0xB8,0xE7,0xB3,0x49,0x1A,0xB9,0x85,0xBE,0xB9,0x18,0x70,0x30,0xDB);
    if (CFEqual(typeUUID, plugType)) return gDriverRef;
    return NULL;
}
