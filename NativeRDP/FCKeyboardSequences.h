#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t scancode;
    bool down;
} FCKeyboardStroke;

static inline uint32_t FCMakeExtendedScanCode(uint32_t scancode) {
    return (scancode & 0x7F) | 0x100;
}

static inline size_t FCMakeSecureAttentionSequence(uint32_t control, uint32_t alt,
                                                    uint32_t end, FCKeyboardStroke strokes[6]) {
    if (!control || !alt || !end || !strokes) return 0;
    strokes[0] = (FCKeyboardStroke){ control, true };
    strokes[1] = (FCKeyboardStroke){ alt, true };
    strokes[2] = (FCKeyboardStroke){ end, true };
    strokes[3] = (FCKeyboardStroke){ end, false };
    strokes[4] = (FCKeyboardStroke){ alt, false };
    strokes[5] = (FCKeyboardStroke){ control, false };
    return 6;
}
