#ifndef LSM_TRANSPORT_H
#define LSM_TRANSPORT_H
#include <stdint.h>
#include <stdbool.h>
#include <CoreAudio/CoreAudioTypes.h>

typedef struct LSMTransport LSMTransport;
LSMTransport *LSMTransportCreate(void);
// Only call destruction after AudioDeviceStop has stopped all callbacks.
void LSMTransportDestroy(LSMTransport *transport);
// One control-queue producer; copies PCM off the real-time thread.
uint64_t LSMTransportAppend(LSMTransport *transport, const float *stereo, uint32_t frames);
void LSMTransportSetVolume(LSMTransport *transport, float volume);
// Render is the sole consumer: no allocation, locks, Swift calls or file IO.
void LSMTransportRender(LSMTransport *transport, AudioBufferList *output);
uint64_t LSMTransportCompleted(LSMTransport *transport);
// Reclaims completed PCM off the audio thread. Append also calls it.
void LSMTransportCollect(LSMTransport *transport);
#endif
