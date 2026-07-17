/*
 * 纯 C 单元测试：覆盖 MatisuXCS 文本特征分类的边界不变式。
 * 不依赖任何测试框架（仅 <stdio.h>/<stdbool.h>），用简单断言计数。
 * 运行：bash quality/run_tests.sh
 *
 * 注：中文 / emoji 字面量此处一律用 UTF-8 字节转义（\xe4\xbd\xa0... / \xf0\x9f\x98\x80），
 * 避免源文件编码差异导致的误判，保证跨编译器一致。
 */
#include <stdio.h>
#include <stdbool.h>
#include "TVNCTextClassifier.h"

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (cond) { g_pass++; }                                               \
        else { g_fail++; printf("  FAIL: %s  [%s:%d]\n", msg, __FILE__, __LINE__); } \
    } while (0)

int main(void) {
    printf("=== TVNCTextClassifier unit tests ===\n");

    // ---- ASCII 判定 ----
    CHECK(TVNCIsAllASCII("hello") == true,  "hello 是纯 ASCII");
    CHECK(TVNCIsAllASCII("") == true,       "空串是纯 ASCII");
    CHECK(TVNCIsAllASCII(NULL) == false,    "NULL 不是纯 ASCII");
    // "你好" UTF-8 = E4 BD A0 E5 A5 BD
    CHECK(TVNCIsAllASCII("\xe4\xbd\xa0\xe5\xa5\xbd") == false, "中文含非 ASCII 字节");

    // ---- 非 BMP（emoji）判定 ----
    // "😀" UTF-8 = F0 9F 98 80
    CHECK(TVNCContainsNonBMPCodepoint("\xf0\x9f\x98\x80") == true,  "emoji 含非 BMP 码点");
    CHECK(TVNCContainsNonBMPCodepoint("hello") == false,           "ASCII 不含非 BMP");
    // "你好" 是 BMP 汉字
    CHECK(TVNCContainsNonBMPCodepoint("\xe4\xbd\xa0\xe5\xa5\xbd") == false, "BMP 汉字不含非 BMP");

    // ---- UTF-8 码点计数 ----
    CHECK(TVNCCountUTF8CodePoints("\xf0\x9f\x98\x80") == 1, "emoji 计 1 码点");
    CHECK(TVNCCountUTF8CodePoints("hi") == 2,              "hi 计 2 码点");
    CHECK(TVNCCountUTF8CodePoints("\xe4\xbd\xa0\xe5\xa5\xbd") == 2, "中文 2 字计 2 码点");
    CHECK(TVNCCountUTF8CodePoints("") == 0,               "空串 0 码点");
    CHECK(TVNCCountUTF8CodePoints(NULL) == 0,             "NULL 0 码点");

    // ---- 控制字符判定 ----
    CHECK(TVNCContainsControlChars("a\nb") == true, "含换行是控制字符");
    CHECK(TVNCContainsControlChars("a\tb") == true, "含 tab 是控制字符");
    CHECK(TVNCContainsControlChars("hello") == false, "普通文本无控制字符");
    CHECK(TVNCContainsControlChars("a b") == false,  "空格不是控制字符");

    // ---- 剪贴板兜底建议（输入通道前置特征层）----
    CHECK(TVNCTextNeedsClipboardFallback("\xf0\x9f\x98\x80") == true, "emoji 建议剪贴板兜底");
    CHECK(TVNCTextNeedsClipboardFallback("a\nb") == true,           "含控制字符建议剪贴板兜底");
    CHECK(TVNCTextNeedsClipboardFallback("hello") == false,        "纯 ASCII 无需兜底");
    CHECK(TVNCTextNeedsClipboardFallback("\xe4\xbd\xa0\xe5\xa5\xbd") == false, "BMP 中文无需兜底");
    CHECK(TVNCTextNeedsClipboardFallback(NULL) == false,          "NULL 无需兜底");

    printf("=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
