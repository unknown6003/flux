#ifndef FLUX_TELEMETRY_CURL_PROBE_H
#define FLUX_TELEMETRY_CURL_PROBE_H
#include <stddef.h>
#include <stdint.h>

/* Diagnostic only. A single fixed EU batch endpoint, no caller-supplied URL. */
typedef struct {
    int code;
    long status;
    long protocol_code;
    size_t length;
    unsigned char body[65536];
} FluxCurlProbeResult;

void FluxCurlProbePost(const unsigned char *body, size_t count, FluxCurlProbeResult *result);
const char *FluxCurlProbeVersion(void);
#endif
