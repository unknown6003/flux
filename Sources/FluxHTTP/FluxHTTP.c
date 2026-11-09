#include "FluxHTTP.h"

#include <curl/curl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if LIBCURL_VERSION_NUM < 0x075500
#error FluxHTTP requires libcurl headers 7.85.0 or newer.
#endif

enum {
    bodyLimit = 65536,
    headerLimit = 16384,
    tokenLimit = 1024,
    pathLimit = 4096
};

struct FluxHTTPTransfer {
    atomic_bool claimed;
    atomic_bool cancelled;
    atomic_bool completed;
    bool oversized;
    long status;
    size_t length;
    size_t headerLength;
    unsigned char body[bodyLimit];
};

static pthread_once_t initialization = PTHREAD_ONCE_INIT;
static bool available;
static const char *runtimeVersion = "unavailable";

static void initialize(void) {
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) return;
    const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
    if (!info || info->version_num < 0x075500 || !info->version) return;
    const int required = CURL_VERSION_THREADSAFE | CURL_VERSION_ASYNCHDNS | CURL_VERSION_SSL;
    if ((info->features & required) != required || !info->protocols) return;
    bool https = false;
    for (size_t index = 0; info->protocols[index]; index++) {
        if (strcmp(info->protocols[index], "https") == 0) https = true;
    }
    if (!https) return;
    runtimeVersion = info->version;
    available = true;
    /* The process owns this initialization; per-transfer cleanup must not end it. */
}

static bool initialize_if_needed(void) {
    return pthread_once(&initialization, initialize) == 0 && available;
}

const char *FluxHTTPVersion(void) {
    return initialize_if_needed() ? runtimeVersion : "unavailable";
}

FluxHTTPTransfer *FluxHTTPCreate(void) {
    FluxHTTPTransfer *transfer = calloc(1, sizeof(*transfer));
    if (!transfer) return NULL;
    atomic_init(&transfer->claimed, false);
    atomic_init(&transfer->cancelled, false);
    atomic_init(&transfer->completed, false);
    return transfer;
}

void FluxHTTPCancel(FluxHTTPTransfer *transfer) {
    if (transfer) atomic_store_explicit(&transfer->cancelled, true, memory_order_release);
}

static bool is_cancelled(const FluxHTTPTransfer *transfer) {
    return atomic_load_explicit(&transfer->cancelled, memory_order_acquire);
}

static void erase(void *bytes, size_t length) {
    volatile unsigned char *cursor = bytes;
    while (length--) *cursor++ = 0;
}

void FluxHTTPDestroy(FluxHTTPTransfer *transfer) {
    if (!transfer) return;
    erase(transfer, sizeof(*transfer));
    free(transfer);
}

static bool has_result(const FluxHTTPTransfer *transfer) {
    return transfer && atomic_load_explicit(&transfer->completed, memory_order_acquire)
        && !is_cancelled(transfer);
}

long FluxHTTPStatus(const FluxHTTPTransfer *transfer) {
    return has_result(transfer) ? transfer->status : 0;
}

size_t FluxHTTPBodyLength(const FluxHTTPTransfer *transfer) {
    return has_result(transfer) ? transfer->length : 0;
}

size_t FluxHTTPCopyBody(const FluxHTTPTransfer *transfer,
                       unsigned char *destination, size_t capacity) {
    if (!has_result(transfer) || capacity < transfer->length) return 0;
    size_t length = transfer->length;
    if (length && !destination) return 0;
    if (length) memcpy(destination, transfer->body, length);
    if (is_cancelled(transfer)) {
        if (length) erase(destination, length);
        return 0;
    }
    return length;
}

static size_t receive_body(char *bytes, size_t size, size_t count, void *context) {
    FluxHTTPTransfer *transfer = context;
    if (is_cancelled(transfer)) return 0;
    if ((size && count > SIZE_MAX / size)
        || size * count > bodyLimit - transfer->length) {
        transfer->oversized = true;
        return 0;
    }
    size_t length = size * count;
    if (length) memcpy(transfer->body + transfer->length, bytes, length);
    transfer->length += length;
    return is_cancelled(transfer) ? 0 : length;
}

static size_t receive_header(char *bytes, size_t size, size_t count, void *context) {
    (void)bytes;
    FluxHTTPTransfer *transfer = context;
    if (is_cancelled(transfer)) return 0;
    if ((size && count > SIZE_MAX / size)
        || size * count > headerLimit - transfer->headerLength) {
        transfer->oversized = true;
        return 0;
    }
    size_t length = size * count;
    transfer->headerLength += length;
    return length;
}

static int progress(void *context, curl_off_t total, curl_off_t received,
                    curl_off_t uploadTotal, curl_off_t uploaded) {
    (void)total;
    (void)received;
    (void)uploadTotal;
    (void)uploaded;
    return is_cancelled(context) ? 1 : 0;
}

static bool valid_token(const char *token, size_t *length) {
    if (!token) return false;
    for (size_t index = 0; index <= tokenLimit; index++) {
        unsigned char value = (unsigned char)token[index];
        if (!value) {
            *length = index;
            return index != 0;
        }
        bool alphanumeric = (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z')
            || (value >= '0' && value <= '9');
        if (!alphanumeric && value != '-' && value != '.' && value != '_' && value != '~'
            && value != '+' && value != '/' && value != '=') return false;
    }
    return false;
}

static bool valid_fixture(unsigned short port, const char *path) {
    if (!port) return !path;
    if (!path || path[0] != '/') return false;
    for (size_t index = 1; index <= pathLimit; index++) {
        unsigned char value = (unsigned char)path[index];
        if (!value) return index > 1;
        if (value < 32 || value == 127) return false;
    }
    return false;
}

static bool append_header(struct curl_slist **headers, const char *value) {
    struct curl_slist *next = curl_slist_append(*headers, value);
    if (!next) return false;
    *headers = next;
    return true;
}

int FluxHTTPPerform(FluxHTTPTransfer *transfer, int region, int endpoint,
                    const unsigned char *body, size_t count,
                    const char *projectToken, unsigned short fixturePort,
                    const char *fixtureCAPath) {
    if (!transfer) return FluxHTTPInvalidRequest;
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&transfer->claimed, &expected, true,
                                                  memory_order_acq_rel, memory_order_acquire)) {
        return FluxHTTPInvalidRequest;
    }

    int result = FluxHTTPInvalidRequest;
    CURL *handle = NULL;
    struct curl_slist *headers = NULL;
    struct curl_slist *connections = NULL;
    char authorization[tokenLimit + sizeof("Authorization: Bearer ")];
    memset(authorization, 0, sizeof(authorization));
    size_t tokenLength = 0;

    if (is_cancelled(transfer)) goto finish;
    if (region < 0 || region > 1 || endpoint < 0 || endpoint > 2
        || !body || !count || count > bodyLimit || !valid_fixture(fixturePort, fixtureCAPath)
        || (endpoint == 2 && !valid_token(projectToken, &tokenLength))) goto finish;
    if (!initialize_if_needed()) { result = FluxHTTPUnavailable; goto finish; }
    handle = curl_easy_init();
    if (!handle) { result = FluxHTTPUnavailable; goto finish; }

    const char *urls[2][3] = {
        {"https://eu.i.posthog.com/batch/", "https://eu.i.posthog.com/flags/?v=2", "https://eu.i.posthog.com/i/v1/logs"},
        {"https://us.i.posthog.com/batch/", "https://us.i.posthog.com/flags/?v=2", "https://us.i.posthog.com/i/v1/logs"}
    };
    const char *values[] = {
        "Content-Type: application/json", "Accept: application/json",
        "Accept-Encoding: identity", "Cache-Control: no-store", "Expect:"
    };
    for (size_t index = 0; index < sizeof(values) / sizeof(values[0]); index++) {
        if (!append_header(&headers, values[index])) { result = FluxHTTPUnavailable; goto finish; }
    }
    if (endpoint == 2) {
        const char prefix[] = "Authorization: Bearer ";
        memcpy(authorization, prefix, sizeof(prefix) - 1);
        memcpy(authorization + sizeof(prefix) - 1, projectToken, tokenLength);
        if (!append_header(&headers, authorization)) { result = FluxHTTPUnavailable; goto finish; }
    }

#define SET(option, value) do { \
    if (curl_easy_setopt(handle, option, value) != CURLE_OK) { \
        result = FluxHTTPUnavailable; goto finish; \
    } \
} while (0)
    SET(CURLOPT_URL, urls[region][endpoint]);
    SET(CURLOPT_PROTOCOLS_STR, "https");
    SET(CURLOPT_REDIR_PROTOCOLS_STR, "https");
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_MAXREDIRS, 0L);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_PROXY_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_PROXY_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    SET(CURLOPT_HTTPAUTH, (long)CURLAUTH_NONE);
    SET(CURLOPT_CONNECTTIMEOUT_MS, 5000L);
    SET(CURLOPT_TIMEOUT_MS, 8000L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_VERBOSE, 0L);
    SET(CURLOPT_USERAGENT, "Flux");
    SET(CURLOPT_HTTPHEADER, headers);
    SET(CURLOPT_HTTP_CONTENT_DECODING, 0L);
    SET(CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)bodyLimit);
    SET(CURLOPT_POST, 1L);
    SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)count);
    SET(CURLOPT_POSTFIELDS, (const char *)body);
    SET(CURLOPT_WRITEFUNCTION, receive_body);
    SET(CURLOPT_WRITEDATA, transfer);
    SET(CURLOPT_HEADERFUNCTION, receive_header);
    SET(CURLOPT_HEADERDATA, transfer);
    SET(CURLOPT_XFERINFOFUNCTION, progress);
    SET(CURLOPT_XFERINFODATA, transfer);
    SET(CURLOPT_NOPROGRESS, 0L);
    if (fixturePort) {
        char mapping[96];
        int length = snprintf(mapping, sizeof(mapping), "%s:443:127.0.0.1:%u",
                              region == 0 ? "eu.i.posthog.com" : "us.i.posthog.com",
                              (unsigned int)fixturePort);
        if (length <= 0 || (size_t)length >= sizeof(mapping)) goto finish;
        connections = curl_slist_append(NULL, mapping);
        if (!connections) { result = FluxHTTPUnavailable; goto finish; }
        SET(CURLOPT_CONNECT_TO, connections);
        SET(CURLOPT_CAINFO, fixtureCAPath);
        SET(CURLOPT_PROXY, "");
    }
    if (is_cancelled(transfer)) goto finish;
    CURLcode code = curl_easy_perform(handle);
    if (code == CURLE_OK) {
        code = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &transfer->status);
        result = code == CURLE_OK ? FluxHTTPSuccess : FluxHTTPNetwork;
    } else if (code == CURLE_FILESIZE_EXCEEDED || transfer->oversized) {
        result = FluxHTTPOversizedResponse;
    } else {
        result = code == CURLE_OUT_OF_MEMORY ? FluxHTTPUnavailable : FluxHTTPNetwork;
    }
#undef SET

finish:
    if (handle) curl_easy_cleanup(handle);
    curl_slist_free_all(headers);
    curl_slist_free_all(connections);
    erase(authorization, sizeof(authorization));
    if (is_cancelled(transfer)) result = FluxHTTPCancelled;
    if (result != FluxHTTPSuccess) {
        erase(transfer->body, sizeof(transfer->body));
        transfer->length = 0;
        transfer->status = 0;
    }
    atomic_store_explicit(&transfer->completed, true, memory_order_release);
    return result;
}
