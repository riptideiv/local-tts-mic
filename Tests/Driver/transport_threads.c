#include "MicTransport.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>

enum { PACKETS = 3000, FRAMES = 137 };
static LSMTransport *queue;
static _Atomic bool done = false;

static void *producer(void *ignored) {
    (void)ignored;
    float pcm[FRAMES * 2];
    for (unsigned packet = 0; packet < PACKETS; ++packet) {
        for (unsigned f = 0; f < FRAMES; ++f) {
            float value = (float)(packet * FRAMES + f + 1) / (PACKETS * FRAMES + 1);
            pcm[f * 2] = value; pcm[f * 2 + 1] = -value;
        }
        while (!LSMTransportAppend(queue, pcm, FRAMES)) sched_yield();
        LSMTransportCollect(queue);
    }
    while (LSMTransportCompleted(queue) != PACKETS) { LSMTransportCollect(queue); sched_yield(); }
    atomic_store_explicit(&done, true, memory_order_release);
    return NULL;
}

int main(void) {
    queue = LSMTransportCreate(); assert(queue);
    pthread_t thread; assert(pthread_create(&thread, NULL, producer, NULL) == 0);
    unsigned consumed = 0;
    float pcm[257 * 2];
    AudioBufferList output = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(pcm), pcm}}};
    while (!atomic_load_explicit(&done, memory_order_acquire)) {
        LSMTransportRender(queue, &output);
        for (unsigned f = 0; f < 257; ++f) {
            assert(pcm[2*f] == -pcm[2*f+1]);
            if (pcm[2*f] != 0) {
                float expected = (float)(consumed + 1) / (PACKETS * FRAMES + 1);
                assert(pcm[2*f] == expected);
                ++consumed;
            }
        }
        sched_yield();
    }
    assert(pthread_join(thread, NULL) == 0);
    assert(consumed == PACKETS * FRAMES);
    LSMTransportDestroy(queue);
    printf("PASS concurrent producer/consumer: %u stereo frames, exactly once and in order\n", consumed);
    return 0;
}
