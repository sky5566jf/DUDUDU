#!/usr/bin/env bash
# 本地 / CI 运行 MatisuXCS 纯 C 单元测。零 theos / Xcode 依赖，仅需 clang/cc。
set -euo pipefail
cd "$(dirname "$0")"

CC="${CC:-cc}"
OUT="$(mktemp -d)/tvnc_strategy_test"

echo ">> Compiling TVNCInputStrategy (strict warnings: -Wall -Wextra -Werror) ..."
"$CC" -std=c11 -Wall -Wextra -Werror -o "$OUT" TVNCInputStrategy.c TVNCInputStrategy_test.c

echo ">> Running tests ..."
"$OUT"
rc=$?
rm -rf "$(dirname "$OUT")"
exit $rc
