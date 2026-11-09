#ifndef FLUX_HTTP_H
#define FLUX_HTTP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FluxHTTPTransfer FluxHTTPTransfer;

enum FluxHTTPResult {
    FluxHTTPSuccess = 0,
    FluxHTTPCancelled = 1,
    FluxHTTPInvalidRequest = 2,
    FluxHTTPOversizedResponse = 3,
    FluxHTTPNetwork = 4,
    FluxHTTPUnavailable = 5
};

FluxHTTPTransfer *FluxHTTPCreate(void);

/* Cancel may run concurrently with Perform. It never calls into a CURL handle. */
void FluxHTTPCancel(FluxHTTPTransfer *transfer);

/* All Perform, Cancel and result readers must have finished before Destroy. */
void FluxHTTPDestroy(FluxHTTPTransfer *transfer);

/*
 * Exactly one Perform is allowed per transfer. The body and strings must remain
 * valid through this blocking call; run it off the UI thread. Region is EU=0 or
 * US=1; endpoint is batch=0, flags=1 or logs=2. Only logs uses projectToken.
 *
 * Production passes fixturePort=0 and fixtureCAPath=NULL. A nonzero fixture
 * port requires an absolute CA path. This connects only to loopback, keeps the
 * production hostname for TLS verification, and disables proxies.
 */
int FluxHTTPPerform(FluxHTTPTransfer *transfer, int region, int endpoint,
                    const unsigned char *body, size_t count,
                    const char *projectToken, unsigned short fixturePort,
                    const char *fixtureCAPath);

/* Results are readable only after Perform returns and before Destroy. */
long FluxHTTPStatus(const FluxHTTPTransfer *transfer);
size_t FluxHTTPBodyLength(const FluxHTTPTransfer *transfer);
size_t FluxHTTPCopyBody(const FluxHTTPTransfer *transfer,
                       unsigned char *destination, size_t capacity);

/* Initializes libcurl once; returns "unavailable" if required features lack. */
const char *FluxHTTPVersion(void);

#ifdef __cplusplus
}
#endif

#endif
