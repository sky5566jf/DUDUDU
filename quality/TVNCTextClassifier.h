/*
 * TVNCTextClassifier — 纯 C 文本特征分类（可单测，零 UIKit/theos 依赖）
 *
 * 设计目的：把「文本该走哪种输入通道」的特征判定从 ObjC 运行时提炼成
 * 可机器验证的纯 C 函数。这是 TVNCInputStrategy 输入决策链的「前置特征层」：
 * 先由本模块判定文本特征（是否纯 ASCII / 含非 BMP / 含控制字符），
 * 再由 TVNCInputStrategy 结合运行上下文做最终通道决策。
 *
 * 此文件不参与 daemon 编译（Makefile 未登记），仅由 quality/run_tests.sh
 * 在 CI 与本地用 clang 直接编译运行。未来可作为纯 C 单一真源，让 .mm 的
 * tvncIsAllASCII:/tvncBuildInputContextForText: 直接调用，消灭重复实现。
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>   // NULL / size_t

#ifdef __cplusplus
extern "C" {
#endif

// 纯 ASCII：所有字节 < 0x80。NULL 视为「不可确认」，返回 false。
bool TVNCIsAllASCII(const char *s);

// 含非 BMP 码点（> 0xFFFF，如 emoji、部分罕见汉字）。这类文本经第一响应者
// replaceRange: 直接插入在某些 App 下不稳，建议剪贴板兜底。
bool TVNCContainsNonBMPCodepoint(const char *s);

// 含控制字符（< 0x20 或 0x7F DEL；不含空格 0x20）。输入时需特殊处理。
bool TVNCContainsControlChars(const char *s);

// UTF-8 码点计数（非法字节按单字节计，避免死循环）。
size_t TVNCCountUTF8CodePoints(const char *s);

// 综合建议：文本是否应走「剪贴板 + Cmd+V」兜底，而非第一响应者直接插入。
// 含非 BMP 或控制字符时返回 true；NULL / 纯 ASCII / BMP 文本返回 false。
bool TVNCTextNeedsClipboardFallback(const char *s);

#ifdef __cplusplus
}
#endif
