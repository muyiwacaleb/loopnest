#include "CRing.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

struct CRing {
    float *data;
    uint32_t capacity;
    uint32_t channels;
    _Atomic uint64_t head; // write index (frames)
    _Atomic uint64_t tail; // read index (frames)
};

CRing *cring_create(uint32_t capacityFrames, uint32_t channels) {
    CRing *r = calloc(1, sizeof(CRing));
    r->capacity = capacityFrames;
    r->channels = channels;
    r->data = calloc((size_t)capacityFrames * channels, sizeof(float));
    atomic_init(&r->head, 0);
    atomic_init(&r->tail, 0);
    return r;
}

void cring_destroy(CRing *r) {
    if (!r) return;
    free(r->data);
    free(r);
}

void cring_reset(CRing *r) {
    atomic_store(&r->tail, atomic_load(&r->head));
}

uint32_t cring_channels(const CRing *r) { return r->channels; }

uint32_t cring_available(const CRing *r) {
    uint64_t h = atomic_load_explicit(&((CRing *)r)->head, memory_order_acquire);
    uint64_t t = atomic_load_explicit(&((CRing *)r)->tail, memory_order_acquire);
    return (uint32_t)(h - t);
}

uint32_t cring_write(CRing *r, const float *src, uint32_t frames) {
    uint64_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint64_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    uint32_t freeFrames = r->capacity - (uint32_t)(h - t);
    if (frames > freeFrames) frames = freeFrames;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t idx = (uint32_t)((h + i) % r->capacity);
        memcpy(&r->data[(size_t)idx * r->channels], &src[(size_t)i * r->channels], r->channels * sizeof(float));
    }
    atomic_store_explicit(&r->head, h + frames, memory_order_release);
    return frames;
}

uint32_t cring_read(CRing *r, float *dst, uint32_t frames) {
    uint64_t h = atomic_load_explicit(&r->head, memory_order_acquire);
    uint64_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint32_t avail = (uint32_t)(h - t);
    uint32_t n = frames < avail ? frames : avail;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (uint32_t)((t + i) % r->capacity);
        memcpy(&dst[(size_t)i * r->channels], &r->data[(size_t)idx * r->channels], r->channels * sizeof(float));
    }
    if (n < frames) memset(&dst[(size_t)n * r->channels], 0, (size_t)(frames - n) * r->channels * sizeof(float));
    atomic_store_explicit(&r->tail, t + n, memory_order_release);
    return n;
}
