// Loads our .driver into this disposable process, never the system audio server.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include "MicTransport.h"

static AudioServerPlugInDriverRef driver;
static AudioObjectID device, inputStream, outputStream;
static _Atomic int checks = 0;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while (0)

static UInt32 get(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, void *data, UInt32 size) {
    AudioObjectPropertyAddress a = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 written = 0;
    CHECK((*driver)->GetPropertyData(driver, object, getpid(), &a, 0, NULL, size, &written, data) == noErr);
    CHECK(written <= size);
    return written;
}
static UInt32 getSize(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 result = 0;
    CHECK((*driver)->GetPropertyDataSize(driver, object, getpid(), &a, 0, NULL, &result) == noErr);
    return result;
}
static void io(bool read, UInt32 client, double time, UInt32 frames, float *data) {
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mInputTime.mSampleTime = time; cycle.mOutputTime.mSampleTime = time;
    CHECK((*driver)->DoIOOperation(driver, device, read ? inputStream : outputStream, client,
        read ? kAudioServerPlugInIOOperationReadInput : kAudioServerPlugInIOOperationWriteMix,
        frames, &cycle, data, NULL) == noErr);
}
static void silence(const float *data, unsigned count) {
    for (unsigned i = 0; i < count; ++i) CHECK(data[i] == 0);
}

static void properties(void) {
    AudioObjectID box = 0;
    CHECK(get(kAudioObjectPlugInObject, kAudioPlugInPropertyBoxList, kAudioObjectPropertyScopeGlobal, &box, sizeof(box)) == sizeof(box));
    CHECK(box != 0);
    UInt32 acquired = 0;
    get(box, kAudioBoxPropertyAcquired, kAudioObjectPropertyScopeGlobal, &acquired, sizeof(acquired)); CHECK(acquired == 1);
    get(box, kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal, &device, sizeof(device)); CHECK(device != 0);
    CFStringRef name = NULL, uid = NULL;
    get(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name, sizeof(name));
    CHECK(CFEqual(name, CFSTR("Local TTS Mic"))); CFRelease(name);
    get(device, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uid, sizeof(uid));
    CHECK(CFEqual(uid, CFSTR("local.localspeak.mic.device.v1"))); CFRelease(uid);
    Float64 rate = 0;
    get(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate, sizeof(rate)); CHECK(rate == 48000);
    CHECK(getSize(device, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal) == sizeof(AudioValueRange));
    AudioValueRange range;
    get(device, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, &range, sizeof(range)); CHECK(range.mMinimum == 48000 && range.mMaximum == 48000);
    CHECK(getSize(device, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal) == 0);
    CHECK(getSize(device, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal) == 2 * sizeof(AudioObjectID));
    UInt32 system = 1;
    get(device, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput, &system, sizeof(system)); CHECK(system == 0);
    get(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, &inputStream, sizeof(inputStream));
    get(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, &outputStream, sizeof(outputStream));
    CHECK(inputStream != outputStream);
    AudioStreamBasicDescription format;
    get(outputStream, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, &format, sizeof(format));
    CHECK(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 && format.mBytesPerFrame == 8);
    format.mSampleRate = 44100;
    AudioObjectPropertyAddress a = {kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, 0};
    CHECK((*driver)->SetPropertyData(driver, outputStream, getpid(), &a, 0, NULL, sizeof(format), &format) != noErr);
    a.mSelector = kAudioDevicePropertyNominalSampleRate;
    Float64 badRate = 44100;
    CHECK((*driver)->SetPropertyData(driver, device, getpid(), &a, 0, NULL, sizeof(badRate), &badRate) != noErr);
    CHECK((*driver)->PerformDeviceConfigurationChange(driver, device, 44100, NULL) != noErr);
    puts("PASS bundle factory, acquired box, fixed format, stream enumeration, controls and rate rejection");
}

static void loopback(void) {
    float sent[2048], first[2048], second[2048];
    for (unsigned i = 0; i < 2048; ++i) sent[i] = sinf((float)i * 0.13f) * 0.5f;
    io(true, 2, 0, 1024, first); silence(first, 2048);
    for (uint64_t frame = 0; frame < 48000 * 15; frame += 1024) {
        io(false, 1, frame, 1024, sent);
        io(true, 2, frame + 512, 1024, first);
        io(true, 3, frame + 512, 1024, second);
        CHECK(memcmp(first, sent, sizeof(sent)) == 0);
        CHECK(memcmp(second, sent, sizeof(sent)) == 0);
    }
    io(true, 2, 2000000, 1024, first); silence(first, 2048);
    io(false, 1, 0, 1024, sent);
    io(false, 1, 16384, 1024, sent);
    io(true, 2, 512, 1024, first); silence(first, 2048);
    io(true, 2, 16384 + 512, 1024, first); CHECK(memcmp(first, sent, sizeof(sent)) == 0);
    io(true, 2, -512, 1024, first); silence(first, 2048);
    puts("PASS ring wrap, multiple readers, 512-frame delay, negative preroll and silence after underrun");
}

static void sender(void) {
    LSMTransport *transport = LSMTransportCreate(); CHECK(transport);
    LSMTransportSetVolume(transport, 0.8f);
    float source[1800], pcm[512], captured[512];
    AudioBufferList output = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(pcm), pcm}}};
    uint64_t frame = 3000000;
    for (unsigned job = 0; job < 250; ++job) {
        unsigned length = 100 + job % 800;
        for (unsigned i = 0; i < length * 2; ++i) source[i] = sinf((float)i * 0.17f) * 0.5f;
        uint64_t ticket = LSMTransportAppend(transport, source, length); CHECK(ticket == job + 1);
        unsigned offset = 0;
        while (offset < length) {
            LSMTransportRender(transport, &output);
            io(false, 1, frame, 256, pcm);
            io(true, 2, frame + 512, 256, captured);
            CHECK(memcmp(pcm, captured, sizeof(pcm)) == 0);
            for (unsigned i = 0; i < 256 * 2; ++i) {
                float expected = offset * 2 + i < length * 2 ? source[offset * 2 + i] * 0.8f : 0;
                CHECK(fabsf(captured[i] - expected) < 0.000001f);
            }
            offset += 256; frame += 256;
        }
        CHECK(LSMTransportCompleted(transport) == ticket);
        // Idle gaps keep the device callback alive and must never replay speech.
        for (unsigned i = 0; i < 3; ++i) {
            LSMTransportRender(transport, &output); silence(pcm, 512);
            io(false, 1, frame, 256, pcm);
            io(true, 2, frame + 512, 256, captured); silence(captured, 512);
            frame += 256;
        }
        LSMTransportCollect(transport);
    }
    LSMTransportDestroy(transport);
    transport = LSMTransportCreate(); CHECK(transport);
    for (unsigned i = 0; i < 128; ++i) CHECK(LSMTransportAppend(transport, source, 1) == i + 1);
    CHECK(LSMTransportAppend(transport, source, 1) == 0);
    LSMTransportRender(transport, &output); CHECK(LSMTransportCompleted(transport) == 128);
    CHECK(LSMTransportAppend(transport, source, 1) == 129);
    LSMTransportDestroy(transport);
    puts("PASS 250 utterances through app PCM sender and loaded driver, idle gaps, queue wrap, capacity and reclamation");
}

static _Atomic uint64_t newest = 0;
static _Atomic bool writingDone = false;
static void *writeFrames(void *unused) {
    (void)unused;
    float pcm[512];
    for (unsigned block = 0; block < 4000; ++block) {
        float marker = block % 2 ? 0.25f : 0.75f;
        for (unsigned i = 0; i < 256; ++i) { pcm[2*i] = marker; pcm[2*i+1] = -marker; }
        uint64_t frame = 5000000 + block * 256;
        io(false, 1, frame, 256, pcm);
        atomic_store_explicit(&newest, frame, memory_order_release);
    }
    atomic_store_explicit(&writingDone, true, memory_order_release);
    return NULL;
}
static void *readFrames(void *unused) {
    (void)unused;
    float pcm[512];
    do {
        uint64_t frame = atomic_load_explicit(&newest, memory_order_acquire);
        if (!frame) continue;
        io(true, 2, frame + 512, 256, pcm);
        for (unsigned i = 0; i < 256; ++i) {
            CHECK(pcm[2*i] == -pcm[2*i+1]);
            CHECK(pcm[2*i] == 0 || pcm[2*i] == 0.25f || pcm[2*i] == 0.75f);
        }
    } while (!atomic_load_explicit(&writingDone, memory_order_acquire));
    return NULL;
}
static void concurrentReaders(void) {
    pthread_t writer, readers[2];
    CHECK(pthread_create(&writer, NULL, writeFrames, NULL) == 0);
    for (unsigned i = 0; i < 2; ++i) CHECK(pthread_create(&readers[i], NULL, readFrames, NULL) == 0);
    CHECK(pthread_join(writer, NULL) == 0);
    for (unsigned i = 0; i < 2; ++i) CHECK(pthread_join(readers[i], NULL) == 0);
    puts("PASS simultaneous writer and two readers across ring overwrites");
}

int main(int argc, char **argv) {
    CHECK(argc == 2);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)argv[1], strlen(argv[1]), true);
    CFPlugInRef plugin = CFPlugInCreate(NULL, url); CHECK(plugin);
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    CHECK(factories && CFArrayGetCount(factories) == 1);
    driver = CFPlugInInstanceCreate(NULL, CFArrayGetValueAtIndex(factories, 0), kAudioServerPlugInTypeUUID); CHECK(driver);
    AudioServerPlugInHostInterface host = {0};
    CHECK((*driver)->Initialize(driver, &host) == noErr);
    properties();
    CHECK((*driver)->StartIO(driver, device, 1) == noErr);
    CHECK((*driver)->StartIO(driver, device, 2) == noErr);
    Float64 sample; UInt64 hostTime, seed, oldSeed;
    CHECK((*driver)->GetZeroTimeStamp(driver, device, 1, &sample, &hostTime, &oldSeed) == noErr);
    loopback(); sender(); concurrentReaders();
    CHECK((*driver)->StopIO(driver, device, 1) == noErr);
    CHECK((*driver)->StopIO(driver, device, 2) == noErr);
    CHECK((*driver)->StartIO(driver, device, 1) == noErr);
    CHECK((*driver)->GetZeroTimeStamp(driver, device, 1, &sample, &hostTime, &seed) == noErr);
    CHECK(seed != oldSeed);
    float empty[512]; io(true, 2, 512, 256, empty); silence(empty, 512);
    CHECK((*driver)->StopIO(driver, device, 1) == noErr);
    puts("PASS stop/restart resets samples and clock seed");
    printf("PASS %d assertions; driver loaded only into this test process\n", checks);
    (*driver)->Release(driver);
    CFRelease(factories); CFRelease(plugin); CFRelease(url);
    return 0;
}
