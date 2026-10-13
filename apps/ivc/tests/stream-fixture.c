#include <axivc/axivc.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct axivc_channel { int unused; };
static struct axivc_channel peer;
static size_t chunk_index;
static int replies;

axivc_channel_t *axivc_publish(uint64_t key, size_t size)
{ (void)key; (void)size; errno = ENOSYS; return NULL; }

axivc_channel_t *axivc_subscribe(uint64_t publisher, uint64_t key, int timeout)
{
    (void)publisher; (void)key; (void)timeout;
    return &peer;
}

int axivc_recv(axivc_channel_t *channel, void *bytes, size_t cap,
               size_t *length, int timeout)
{
    (void)channel; (void)timeout;
    const char *chunks[] = {"request-1\nrequest-2\n", "req",
                             "uest-3\nrequest-4\n", "request-5\n"};
    if (chunk_index == sizeof(chunks) / sizeof(chunks[0])) return -EIO;
    const char *chunk = chunks[chunk_index++];
    if (chunk_index == 1 && getenv("IVC_TEST_BAD_SEQUENCE"))
        chunk = "request-1\nrequest-9\n";
    *length = strlen(chunk);
    if (*length > cap) return -EMSGSIZE;
    memcpy(bytes, chunk, *length);
    return 0;
}

int axivc_send(axivc_channel_t *channel, const void *bytes,
               size_t length, int timeout)
{
    (void)channel; (void)timeout;
    char expected[32];
    snprintf(expected, sizeof(expected), "reply-%d\n", replies + 1);
    if (length != strlen(expected) || memcmp(bytes, expected, length)) return -EPROTO;
    ++replies;
    return 0;
}

int axivc_close(axivc_channel_t *channel)
{ (void)channel; return replies == 5 ? 0 : -EPROTO; }
