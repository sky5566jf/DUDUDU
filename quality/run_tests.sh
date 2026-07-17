#!/usr/bin/env bash
# 本地 / CI 运行 MatisuXCS 纯 C 单元测。零 theos / Xcode 依赖，仅需 clang/cc。
set -euo pipefail
cd "$(dirname "$0")"

CC="${CC:-cc}"
rc=0
count=0

# 自动发现所有 *_test.c，按约定与同名实现（去掉 _test 后缀的 .c）一起编译运行。
# 新增纯 C 可测模块只需放 <Name>.c + <Name>_test.c，无需改动本脚本即可纳入 CI。
shopt -s nullglob
for t in *_test.c; do
    impl="${t%_test.c}.c"
    name="${t%_test.c}"
    out="$(mktemp -d)/${name}_test"
    echo ">> [$name] Compiling (strict: -Wall -Wextra -Werror) ..."
    if [ -f "$impl" ]; then
        "$CC" -std=c11 -Wall -Wextra -Werror -o "$out" "$impl" "$t"
    else
        "$CC" -std=c11 -Wall -Wextra -Werror -o "$out" "$t"
    fi
    echo ">> [$name] Running ..."
    "$out" || rc=1
    rm -rf "$(dirname "$out")"
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    echo "!! no *_test.c found"
    rc=1
fi
exit $rc
