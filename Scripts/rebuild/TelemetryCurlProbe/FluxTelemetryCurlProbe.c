/* Throwaway transport comparison. Not linked into the Flux app. */
#include "FluxTelemetryCurlProbe.h"
#include <curl/curl.h>
#include <string.h>

static size_t receive_body(char *bytes, size_t size, size_t count, void *context) {
    FluxCurlProbeResult *result = context;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > sizeof(result->body) - result->length) return 0;
    if (length) memcpy(result->body + result->length, bytes, length);
    result->length += length;
    return length;
}

const char *FluxCurlProbeVersion(void) { return curl_version(); }

void FluxCurlProbePost(const unsigned char *body, size_t count, FluxCurlProbeResult *result) {
    if (!result) return;
    memset(result, 0, sizeof(*result));
    result->code = CURLE_BAD_FUNCTION_ARGUMENT;
    if (!body || !count || count > 65536) return;
    result->code = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (result->code != CURLE_OK) return;
    CURL *handle = curl_easy_init();
    struct curl_slist *headers = NULL;
    if (!handle) { result->code = CURLE_OUT_OF_MEMORY; goto finish; }
    const char *values[] = {"Content-Type: application/json", "Accept: application/json", "Cache-Control: no-store"};
    for (size_t index = 0; index < sizeof(values) / sizeof(values[0]); index++) {
        struct curl_slist *next = curl_slist_append(headers, values[index]);
        if (!next) { result->code = CURLE_OUT_OF_MEMORY; goto finish; }
        headers = next;
    }
#define SET(option, value) do { \
    CURLcode code = curl_easy_setopt(handle, option, value); \
    if (code != CURLE_OK) { result->code = code; goto finish; } \
} while (0)
    SET(CURLOPT_URL, "https://eu.i.posthog.com/batch/");
    SET(CURLOPT_PROTOCOLS_STR, "https");
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_MAXREDIRS, 0L);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    SET(CURLOPT_CONNECTTIMEOUT_MS, 5000L);
    SET(CURLOPT_TIMEOUT_MS, 8000L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_USERAGENT, "Flux");
    SET(CURLOPT_HTTPHEADER, headers);
    SET(CURLOPT_POST, 1L);
    SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)count);
    SET(CURLOPT_POSTFIELDS, (const char *)body);
    SET(CURLOPT_WRITEFUNCTION, receive_body);
    SET(CURLOPT_WRITEDATA, result);
    result->code = curl_easy_perform(handle);
    if (result->code == CURLE_OK) {
        result->code = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &result->status);
        if (result->code == CURLE_OK) {
            result->code = curl_easy_getinfo(handle, CURLINFO_HTTP_VERSION, &result->protocol_code);
        }
    }
#undef SET
finish:
    if (handle) curl_easy_cleanup(handle);
    curl_slist_free_all(headers);
    curl_global_cleanup();
}
