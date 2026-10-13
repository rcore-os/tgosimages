#include <axivc/axivc.h>
#include <axivc/demo_config.h>

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int parse_id(const char *text, uint64_t *value)
{
    char *end;
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, 0);
    if (errno || !*text || *text == '-' || *end) return -1;
    *value = parsed;
    return 0;
}

struct receive_buffer {
    char pending[AXIVC_SLOT_PAYLOAD_SIZE * 2];
    size_t used;
};

static int receive_expected(axivc_channel_t *channel,
                            struct receive_buffer *reader, const char *expected)
{
    for (;;) {
        char *end = memchr(reader->pending, '\n', reader->used);
        if (end) {
            size_t length = (size_t)(end - reader->pending) + 1;
            if (length != strlen(expected) ||
                memcmp(reader->pending, expected, length)) {
                fprintf(stderr, "IVC_ROUNDTRIP_FAILED expected=%s received=%.*s\n",
                        expected, (int)length, reader->pending);
                return -EPROTO;
            }
            reader->used -= length;
            memmove(reader->pending, reader->pending + length, reader->used);
            return 0;
        }
        char chunk[AXIVC_SLOT_PAYLOAD_SIZE];
        size_t length = 0;
        int ret = axivc_recv(channel, chunk, sizeof(chunk), &length,
                             AXIVC_DEMO_TIMEOUT_MS);
        if (ret < 0) return ret;
        if (length > sizeof(chunk)) return -EPROTO;
        /* Match the SDK demo's byte-stream framing and legacy slot padding. */
        while (length && chunk[length - 1] == '\0') --length;
        if (!length || length > sizeof(reader->pending) - reader->used)
            return -EMSGSIZE;
        memcpy(reader->pending + reader->used, chunk, length);
        reader->used += length;
    }
}

int main(int argc, char **argv)
{
    int publisher = argc > 1 && !strcmp(argv[1], "publish");
    int subscriber = argc > 1 && !strcmp(argv[1], "subscribe");
    int required = publisher ? 5 : 6;
    uint64_t peer = 0, key = 0;
    if ((!publisher && !subscriber) || argc != required ||
        (!publisher && parse_id(argv[2], &peer)) ||
        parse_id(argv[publisher ? 2 : 3], &key)) {
        fprintf(stderr, "Usage: ivc-roundtrip publish KEY REQUEST_PREFIX REPLY_PREFIX\n"
                        "       ivc-roundtrip subscribe VM KEY REQUEST_PREFIX REPLY_PREFIX\n");
        return 2;
    }
    const char *request_prefix = argv[publisher ? 3 : 4];
    const char *reply_prefix = argv[publisher ? 4 : 5];
    if (!*request_prefix || !*reply_prefix || strlen(request_prefix) > 32 ||
        strlen(reply_prefix) > 32) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    axivc_channel_t *channel = publisher
        ? axivc_publish(key, AXIVC_DEMO_CHANNEL_SIZE)
        : axivc_subscribe(peer, key, AXIVC_DEMO_TIMEOUT_MS);
    if (!channel) {
        fprintf(stderr, "IVC_ROUNDTRIP_FAILED open: %s\n", strerror(errno));
        return 1;
    }
    printf("IVC_ROUNDTRIP_READY role=%s peer=%" PRIu64 " key=0x%" PRIx64 "\n",
           argv[1], peer, key);
    int ret = 0;
    struct receive_buffer reader = {0};
    for (int seq = 1; seq <= AXIVC_DEMO_MESSAGE_COUNT; ++seq) {
        char request[AXIVC_SLOT_PAYLOAD_SIZE + 1];
        char reply[AXIVC_SLOT_PAYLOAD_SIZE + 1];
        snprintf(request, sizeof(request), "%s-%d\n", request_prefix, seq);
        snprintf(reply, sizeof(reply), "%s-%d\n", reply_prefix, seq);
        if (publisher) {
            ret = axivc_send(channel, request, strlen(request), AXIVC_DEMO_TIMEOUT_MS);
            if (!ret) ret = receive_expected(channel, &reader, reply);
        } else {
            ret = receive_expected(channel, &reader, request);
            if (!ret) ret = axivc_send(channel, reply, strlen(reply), AXIVC_DEMO_TIMEOUT_MS);
        }
        if (ret) break;
        printf("IVC_ROUNDTRIP_SEQ role=%s key=0x%" PRIx64 " seq=%d\n", argv[1], key, seq);
    }
    if (!ret && reader.used) ret = -EPROTO;
    int close_ret = axivc_close(channel);
    if (!ret) ret = close_ret;
    if (ret) {
        fprintf(stderr, "IVC_ROUNDTRIP_FAILED role=%s key=0x%" PRIx64 " ret=%d\n",
                argv[1], key, ret);
        return 1;
    }
    printf("IVC_ROUNDTRIP_PASSED role=%s key=0x%" PRIx64 " count=%d\n",
           argv[1], key, AXIVC_DEMO_MESSAGE_COUNT);
    return 0;
}
