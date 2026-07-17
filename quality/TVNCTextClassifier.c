#include "TVNCTextClassifier.h"

// 单字节是否为 UTF-8 续字节（10xxxxxx）
static bool utf8_is_continuation(unsigned char c) {
    return (c & 0xC0) == 0x80;
}

// 解码 s[0..] 的首个 UTF-8 码点；*advance 返回消耗的字节数。
// 非法首字节按单字节替换符处理，保证不越界、不死循环。
static unsigned int utf8_decode(const char *s, size_t *advance) {
    unsigned char c = (unsigned char)*s;
    if (c < 0x80) {
        *advance = 1;
        return c;
    } else if ((c & 0xE0) == 0xC0 && utf8_is_continuation((unsigned char)s[1])) {
        *advance = 2;
        return ((unsigned int)(c & 0x1F) << 6) |
               ((unsigned int)((unsigned char)s[1] & 0x3F));
    } else if ((c & 0xF0) == 0xE0 && utf8_is_continuation((unsigned char)s[1]) &&
               utf8_is_continuation((unsigned char)s[2])) {
        *advance = 3;
        return ((unsigned int)(c & 0x0F) << 12) |
               ((unsigned int)((unsigned char)s[1] & 0x3F) << 6) |
               ((unsigned int)((unsigned char)s[2] & 0x3F));
    } else if ((c & 0xF8) == 0xF0 && utf8_is_continuation((unsigned char)s[1]) &&
               utf8_is_continuation((unsigned char)s[2]) &&
               utf8_is_continuation((unsigned char)s[3])) {
        *advance = 4;
        return ((unsigned int)(c & 0x07) << 18) |
               ((unsigned int)((unsigned char)s[1] & 0x3F) << 12) |
               ((unsigned int)((unsigned char)s[2] & 0x3F) << 6) |
               ((unsigned int)((unsigned char)s[3] & 0x3F));
    }
    *advance = 1;
    return 0xFFFD; // 替换符
}

size_t TVNCCountUTF8CodePoints(const char *s) {
    if (s == NULL) return 0;
    size_t n = 0;
    for (size_t i = 0; s[i] != '\0'; ) {
        size_t adv = 0;
        (void)utf8_decode(&s[i], &adv);
        i += adv;
        n++;
    }
    return n;
}

bool TVNCIsAllASCII(const char *s) {
    if (s == NULL) return false;  // 无法确认，保守返回 false
    for (size_t i = 0; s[i] != '\0'; i++) {
        if ((unsigned char)s[i] >= 0x80) return false;
    }
    return true;
}

bool TVNCContainsNonBMPCodepoint(const char *s) {
    if (s == NULL) return false;
    size_t i = 0;
    while (s[i] != '\0') {
        size_t adv = 0;
        unsigned int cp = utf8_decode(&s[i], &adv);
        if (cp > 0xFFFF) return true;
        i += adv;
    }
    return false;
}

bool TVNCContainsControlChars(const char *s) {
    if (s == NULL) return false;
    for (size_t i = 0; s[i] != '\0'; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x20 || c == 0x7F) return true;  // 不含空格 0x20
    }
    return false;
}

bool TVNCTextNeedsClipboardFallback(const char *s) {
    if (s == NULL) return false;
    return TVNCContainsNonBMPCodepoint(s) || TVNCContainsControlChars(s);
}
