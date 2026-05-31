#!/usr/bin/env bash
#
# cc-switch-account.sh — 官方 Claude Code 换号脚本
#
# 用途：当前登录的 Claude 账号被封时，删除旧账号的登录记录，以便用新账号重新登录，
#       同时【完整保留】记忆(memory)与历史会话(transcript / session)。
#
# 只动这两处账号身份：
#   1) ~/.claude/.credentials.json  里的 claudeAiOauth（登录凭据本体）
#   2) ~/.claude.json               里的 oauthAccount + userID（账号身份字段）
#
# 绝不触碰（= 你的记忆和历史）：
#   - ~/.claude/projects/**/memory/*.md      （记忆）
#   - ~/.claude/projects/**/*.jsonl          （历史会话 transcript，本机数百条）
#   - ~/.claude/history.jsonl                （prompt 历史）
#   - ~/.claude.json 的 .projects / settings / skills / plugins 等其余一切
#
# 用法：
#   cc-switch-account.sh           # 干跑(dry-run)：只打印将要做什么，不改任何文件
#   cc-switch-account.sh --yes     # 真执行：备份 -> 记录被封账号 -> 摘除账号字段
#
# 执行后：运行 `claude` 会要求重新登录，跑 /login 用新账号即可。记忆和历史照旧。
#
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CRED="$CLAUDE_DIR/.credentials.json"
CONFIG="$HOME/.claude.json"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$CLAUDE_DIR/account-switch-backups/$TS"
APPLY=0

[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && APPLY=1

command -v jq >/dev/null || { echo "ERROR: 需要 jq，请先 apt install jq"; exit 1; }

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }

hr
if [[ $APPLY -eq 0 ]]; then
  say "模式：DRY-RUN（干跑，不改任何文件）。确认无误后加 --yes 真执行。"
else
  say "模式：APPLY（真执行）。"
fi
hr

# --- 0. 先把当前(被封)账号信息打出来，便于核对你删的是哪个号 ---
if [[ -f "$CONFIG" ]]; then
  say "当前登录账号（即将被移除）："
  jq -r '.oauthAccount // {} | "  邮箱:   \(.emailAddress // "?")\n  组织:   \(.organizationName // "?")\n  UUID:   \(.accountUuid // "?")\n  订阅:   \(.seatTier // .billingType // "?")"' "$CONFIG" 2>/dev/null || say "  (无 oauthAccount，可能已是登出态)"
else
  say "未找到 $CONFIG"
fi
hr

# --- 1. 备份（可回滚）---
say "[1/4] 备份 -> $BACKUP_DIR"
if [[ $APPLY -eq 1 ]]; then
  mkdir -p "$BACKUP_DIR"
  [[ -f "$CRED" ]]   && cp -p "$CRED"   "$BACKUP_DIR/.credentials.json"
  [[ -f "$CONFIG" ]] && cp -p "$CONFIG" "$BACKUP_DIR/.claude.json"
fi

# --- 2. 把被封账号留个案底（只记身份，不记 token）---
say "[2/4] 记录被封账号到 $CLAUDE_DIR/banned-accounts.log"
if [[ $APPLY -eq 1 && -f "$CONFIG" ]]; then
  jq -c --arg ts "$TS" '{bannedAt:$ts, account:(.oauthAccount // null), userID:.userID}' "$CONFIG" \
    >> "$CLAUDE_DIR/banned-accounts.log" 2>/dev/null || true
fi

# --- 3. 删除登录凭据本体 ---
say "[3/4] 移除登录凭据 $CRED"
if [[ $APPLY -eq 1 ]]; then
  rm -f "$CRED"
fi

# --- 4. 从 .claude.json 摘除账号身份字段（保留其余一切）---
say "[4/4] 从 .claude.json 摘除 oauthAccount + userID（projects/记忆/历史保持不动）"
if [[ $APPLY -eq 1 && -f "$CONFIG" ]]; then
  tmp="$(mktemp)"
  jq 'del(.oauthAccount) | del(.userID)' "$CONFIG" > "$tmp"
  # 校验生成的 JSON 合法再覆盖，避免把配置写坏
  jq -e . "$tmp" >/dev/null
  mv "$tmp" "$CONFIG"
  chmod 600 "$CONFIG"
fi

hr
if [[ $APPLY -eq 0 ]]; then
  say "DRY-RUN 结束。以上都没真执行。确认后："
  say "    $0 --yes"
else
  say "完成。已退出旧账号，记忆与历史完整保留。"
  say "下一步：运行  claude  并执行  /login  用【新账号】登录。"
  say "回滚：把 $BACKUP_DIR 下的两个文件拷回原位即可。"
fi
hr
