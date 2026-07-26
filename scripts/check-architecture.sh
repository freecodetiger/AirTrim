#!/usr/bin/env bash
# AirTrim 分层守卫 —— 与 CLAUDE.md「禁止事项」一一对应，本地与 CI 都跑。
#
# 规则：
#   1) AirTrimCore 不得 import SwiftUI / AppKit（UI 只属于 AirTrimApp）
#   2) 网络代码（URLSession/URLRequest）只允许出现在 Sources/AirTrimCore/LLMProvider/
#      —— 这是「音视频永不上传、云端只见文字稿」的架构级保证
#   3) Analysis/ 是纯值类型层，不得 import AVFoundation
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# check <描述> <正则> <搜索路径> [允许的路径前缀]
check() {
  local desc="$1" pattern="$2" path="$3" allow="${4-}"
  local hits
  hits=$(grep -rn --include='*.swift' -E "$pattern" "$path" 2>/dev/null || true)
  if [[ -n "$allow" && -n "$hits" ]]; then
    hits=$(printf '%s\n' "$hits" | grep -v "^$allow" || true)
  fi
  if [[ -n "$hits" ]]; then
    echo "❌ $desc"
    printf '%s\n' "$hits" | sed 's/^/     /'
    fail=1
  else
    echo "✅ $desc"
  fi
}

check "Core 不含 SwiftUI/AppKit" \
      '^[[:space:]]*import (SwiftUI|AppKit)' \
      Sources/AirTrimCore

check "网络调用仅限 LLMProvider" \
      'URLSession|URLRequest' \
      Sources/AirTrimCore \
      "Sources/AirTrimCore/LLMProvider/"

check "Analysis 纯值类型（无 AVFoundation）" \
      '^[[:space:]]*import AVFoundation' \
      Sources/AirTrimCore/Analysis

exit $fail
