// Local TTS Mic additions. Apple's driver scaffolding is in vendor/.
#ifndef LOCAL_SPEAK_LOOPBACK_H
#define LOCAL_SPEAK_LOOPBACK_H
#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

enum { LSM_RATE = 48000, LSM_CHANNELS = 2, LSM_RING_FRAMES = 16384, LSM_DELAY = 512 };
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Real-time frame atomics must be lock-free");

typedef struct {
    _Atomic uint64_t frame;
    _Atomic uint64_t stereo;
} LSMFrame;
static LSMFrame lsmRing[LSM_RING_FRAMES];
static _Atomic uint64_t lsmAnchor = 0;
static _Atomic uint64_t lsmSeed = 1;

// Called only before the first IO client starts, while no IO callbacks run.
static void LSMReset(void) {
    for (unsigned i = 0; i < LSM_RING_FRAMES; ++i) {
        atomic_store_explicit(&lsmRing[i].frame, UINT64_MAX, memory_order_relaxed);
        atomic_store_explicit(&lsmRing[i].stereo, 0, memory_order_relaxed);
    }
}

// HAL supplies one mixed output producer. Tag every slot with absolute sample
// time: unwritten frames and old ring revolutions must always produce silence.
// Payloads are atomic too, so readers never race a producer wrapping the ring.
static void LSMWrite(uint64_t start, uint32_t count, const float *samples) {
    for (uint32_t i = 0; i < count; ++i) {
        LSMFrame *slot = &lsmRing[(start + i) % LSM_RING_FRAMES];
        float pair[2] = { samples[2*i], samples[2*i+1] };
        for (unsigned c = 0; c < 2; ++c) {
            if (!isfinite(pair[c])) pair[c] = 0;
            pair[c] = fmaxf(-1, fminf(1, pair[c]));
        }
        uint64_t packed;
        memcpy(&packed, pair, sizeof(packed));
        atomic_store_explicit(&slot->frame, UINT64_MAX, memory_order_release);
        atomic_store_explicit(&slot->stereo, packed, memory_order_release);
        atomic_store_explicit(&slot->frame, start + i, memory_order_release);
    }
}

static void LSMRead(uint64_t start, uint32_t count, float *samples) {
    for (uint32_t i = 0; i < count; ++i) {
        uint64_t packed = 0;
        if (start + i >= LSM_DELAY) {
            uint64_t wanted = start + i - LSM_DELAY;
            LSMFrame *slot = &lsmRing[wanted % LSM_RING_FRAMES];
            if (atomic_load_explicit(&slot->frame, memory_order_acquire) == wanted) {
                packed = atomic_load_explicit(&slot->stereo, memory_order_acquire);
                if (atomic_load_explicit(&slot->frame, memory_order_acquire) != wanted) packed = 0;
            }
        }
        memcpy(samples + 2*i, &packed, sizeof(packed));
    }
}
#endif
