#ifndef CRING_H
#define CRING_H
#include <stdint.h>

// Lock-free single-producer / single-consumer ring of interleaved float frames.
typedef struct CRing CRing;

CRing *cring_create(uint32_t capacityFrames, uint32_t channels);
void cring_destroy(CRing *r);
void cring_reset(CRing *r);
uint32_t cring_available(const CRing *r);
// Writes interleaved frames. Returns frames written (drops overflow).
uint32_t cring_write(CRing *r, const float *interleaved, uint32_t frames);
// Reads interleaved frames. Missing frames are zero-filled. Returns frames actually read.
uint32_t cring_read(CRing *r, float *interleaved, uint32_t frames);
uint32_t cring_channels(const CRing *r);

#endif
