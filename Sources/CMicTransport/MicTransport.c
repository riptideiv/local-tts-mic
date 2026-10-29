#include "MicTransport.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

enum { SLOT_COUNT = 128 };
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio callback requires lock-free atomics");
typedef struct { float *data; uint32_t frames; } Packet;
struct LSMTransport {
    Packet slots[SLOT_COUNT];
    _Atomic uint64_t produced;
    _Atomic uint64_t consumed;
    _Atomic uint32_t volumeBits;
    uint64_t collected; // producer only
    uint32_t offset; // consumer only
};

LSMTransport *LSMTransportCreate(void) {
    LSMTransport *p = calloc(1, sizeof(*p));
    if (p) LSMTransportSetVolume(p, 1);
    return p;
}

void LSMTransportCollect(LSMTransport *p) {
    uint64_t end = atomic_load_explicit(&p->consumed, memory_order_acquire);
    while (p->collected < end) {
        Packet *slot = &p->slots[p->collected % SLOT_COUNT];
        free(slot->data); slot->data = NULL;
        ++p->collected;
    }
}

void LSMTransportDestroy(LSMTransport *p) {
    if (!p) return;
    uint64_t end = atomic_load_explicit(&p->produced, memory_order_acquire);
    while (p->collected < end) { free(p->slots[p->collected % SLOT_COUNT].data); ++p->collected; }
    free(p);
}

uint64_t LSMTransportAppend(LSMTransport *p, const float *data, uint32_t frames) {
    if (!p || !data || !frames || frames > UINT32_MAX / 8) return 0;
    LSMTransportCollect(p);
    uint64_t next = atomic_load_explicit(&p->produced, memory_order_relaxed);
    if (next - p->collected >= SLOT_COUNT) return 0;
    float *copy = malloc((size_t)frames * 8);
    if (!copy) return 0;
    memcpy(copy, data, (size_t)frames * 8);
    p->slots[next % SLOT_COUNT] = (Packet){copy, frames};
    atomic_store_explicit(&p->produced, next + 1, memory_order_release);
    return next + 1;
}

void LSMTransportSetVolume(LSMTransport *p, float volume) {
    if (!isfinite(volume)) volume = 0;
    volume = fmaxf(0, fminf(1, volume));
    uint32_t bits; memcpy(&bits, &volume, sizeof(bits));
    atomic_store_explicit(&p->volumeBits, bits, memory_order_relaxed);
}

uint64_t LSMTransportCompleted(LSMTransport *p) {
    return atomic_load_explicit(&p->consumed, memory_order_acquire);
}

void LSMTransportRender(LSMTransport *p, AudioBufferList *output) {
    if (!output) return;
    for (uint32_t i = 0; i < output->mNumberBuffers; ++i) {
        AudioBuffer *buffer = &output->mBuffers[i];
        if (buffer->mData) memset(buffer->mData, 0, buffer->mDataByteSize);
    }
    if (!p || output->mNumberBuffers != 1 || output->mBuffers[0].mNumberChannels != 2 || !output->mBuffers[0].mData) return;
    uint32_t bits = atomic_load_explicit(&p->volumeBits, memory_order_relaxed);
    float volume; memcpy(&volume, &bits, sizeof(volume));
    float *target = output->mBuffers[0].mData;
    uint32_t capacity = output->mBuffers[0].mDataByteSize / 8, filled = 0;
    uint64_t current = atomic_load_explicit(&p->consumed, memory_order_relaxed);
    while (filled < capacity && current < atomic_load_explicit(&p->produced, memory_order_acquire)) {
        Packet *slot = &p->slots[current % SLOT_COUNT];
        uint32_t available = slot->frames - p->offset;
        uint32_t count = available < capacity - filled ? available : capacity - filled;
        for (uint32_t i = 0; i < count * 2; ++i) {
            float sample = slot->data[p->offset * 2 + i];
            target[filled * 2 + i] = isfinite(sample) ? sample * volume : 0;
        }
        filled += count; p->offset += count;
        if (p->offset == slot->frames) {
            p->offset = 0;
            ++current;
            atomic_store_explicit(&p->consumed, current, memory_order_release);
        }
    }
}
