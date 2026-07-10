#!/usr/bin/env bash
#
# cc-switch-account.sh — 官方 Claude Code 换号脚本（优化版）
#
# 用途：当前登录的 Claude 账号被封时，删除旧账号的登录记录，以便用新账号重新登录，
#       同时【完整保留】记忆(memory)与历史会话(transcript / session)。
#       附带：运行时会检查系统时区，若不对则自动纠正为目标时区（默认美西）。
#
# 只动这两处账号身份：
#   1) ~/.claude/.credentials.json  里的 claudeAiOauth（登录凭据本体）
#   2) ~/.claude.json               里的 oauthAccount + userID（账号身份字段）
#
# 绝不触碰（= 你的记忆和历史）：
#   - ~/.claude/projects/**/memory/*.md / **/*.jsonl / ~/.claude/history.jsonl
#   - ~/.claude.json 的 .projects / settings / skills / plugins 等其余一切
#
set -euo pipefail

# ---- 可配置项 ----
SWITCH_TZ="${SWITCH_TZ:-America/Los_Angeles}"   # 目标时区：时间戳 + 系统时区都用它（改这里就换时区）
AUTO_FIX_TZ="${AUTO_FIX_TZ:-1}"                  # 换号时是否顺带纠正系统时区（1=是，0=否）

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CRED="$CLAUDE_DIR/.credentials.json"
CONFIG="$HOME/.claude.json"
BACKUP_ROOT="$CLAUDE_DIR/account-switch-backups"

# 目录名用紧凑时间戳；日志里用带时区偏移的 ISO 时间，方便日后核对
TS="$(TZ="$SWITCH_TZ" date +%Y%m%d-%H%M%S)"
TS_ISO="$(TZ="$SWITCH_TZ" date +%Y-%m-%dT%H:%M:%S%z)"
TZ_ABBR="$(TZ="$SWITCH_TZ" date +%Z)"
BACKUP_DIR="$BACKUP_ROOT/$TS"

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }

usage() {
  cat <<EOF
用法：
  cc-switch-account.sh              # 干跑：只打印将要做什么，不改任何文件
  cc-switch-account.sh --yes        # 真执行：备份 -> 记录被封账号 -> 摘除账号字段（并顺带纠正系统时区）
  cc-switch-account.sh --fix-time   # 只纠正系统时区/对时，不换号
  cc-switch-account.sh --rollback   # 回滚：把最近一次备份恢复回去
  cc-switch-account.sh --help       # 查看帮助

时区：目标时区 = $SWITCH_TZ（自动处理夏令时 PDT/PST）。
  临时换目标时区：      SWITCH_TZ=America/New_York cc-switch-account.sh --fix-time
  换号时不动系统时区：  AUTO_FIX_TZ=0 cc-switch-account.sh --yes
EOF
}

# ---- 检查/纠正系统时区 ----
# $1 = "apply" 才真改（需 root 或免密 sudo）；否则只报告不改。
ensure_system_timezone() {
  local mode="${1:-report}" cur
  cur="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)"
  if [[ "$cur" == "$SWITCH_TZ" ]]; then
    say "系统时区正确：$cur"
    return 0
  fi
  say "检测到系统时区为 [$cur]，应为 [$SWITCH_TZ]。"
  if [[ "$mode" != "apply" ]]; then
    say "  （DRY-RUN：真执行时会自动改成 $SWITCH_TZ；单独纠正可跑  $0 --fix-time）"
    return 0
  fi
  # 优先直接执行（root）；否则试免密 sudo（-n 不会卡住等密码）
  if timedatectl set-timezone "$SWITCH_TZ" 2>/dev/null || sudo -n timedatectl set-timezone "$SWITCH_TZ" 2>/dev/null; then
    timedatectl set-ntp true 2>/dev/null || sudo -n timedatectl set-ntp true 2>/dev/null || true
    say "  ✔ 已把系统时区改为 $SWITCH_TZ（现在：$(TZ="$SWITCH_TZ" date '+%F %T %Z')）"
  else
    say "  ✗ 没权限自动改。请手动执行： sudo timedatectl set-timezone $SWITCH_TZ"
  fi
}

# ---- 参数解析 ----
APPLY=0
MODE="switch"
case "${1:-}" in
  --yes|-y)    APPLY=1 ;;
  --rollback)  MODE="rollback" ;;
  --fix-time)  MODE="fixtime" ;;
  --help|-h)   usage; exit 0 ;;
  "")          APPLY=0 ;;
  *) echo "未知参数：$1（用 --help 查看用法）"; exit 2 ;;
esac

# ===================== 只纠正时区模式 =====================
if [[ "$MODE" == "fixtime" ]]; then
  hr; say "模式：FIX-TIME（只纠正系统时区/对时，不换号）"; hr
  ensure_system_timezone apply
  hr; timedatectl status 2>/dev/null | sed -n '1,6p' || true
  exit 0
fi

# ===================== 回滚模式 =====================
if [[ "$MODE" == "rollback" ]]; then
  hr; say "模式：ROLLBACK（回滚到最近一次备份）"; hr
  [[ -d "$BACKUP_ROOT" ]] || { echo "没有任何备份目录：$BACKUP_ROOT"; exit 1; }
  LATEST="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -n1)"
  [[ -n "$LATEST" ]] || { echo "备份目录为空，无可回滚内容"; exit 1; }
  say "使用备份：$LATEST"
  [[ -f "$LATEST/.credentials.json" ]] && { cp -p "$LATEST/.credentials.json" "$CRED";   say "  已恢复 $CRED"; }
  [[ -f "$LATEST/.claude.json" ]]      && { cp -p "$LATEST/.claude.json" "$CONFIG"; chmod 600 "$CONFIG"; say "  已恢复 $CONFIG"; }
  hr; say "回滚完成。运行  claude  确认是否已恢复登录态。"
  exit 0
fi

# ===================== 换号模式 =====================
command -v jq >/dev/null || { echo "ERROR: 需要 jq，请先 apt install jq（或 brew install jq）"; exit 1; }

hr
if [[ $APPLY -eq 0 ]]; then
  say "模式：DRY-RUN（干跑，不改任何文件）。确认无误后加 --yes 真执行。"
else
  say "模式：APPLY（真执行）。"
fi
say "时间戳时区：$SWITCH_TZ（当前 $TZ_ABBR，$TS_ISO）"
hr

# --- 0a. 先纠正系统时区（AUTO_FIX_TZ=0 可关闭）---
if [[ "$AUTO_FIX_TZ" == "1" ]]; then
  [[ $APPLY -eq 1 ]] && ensure_system_timezone apply || ensure_system_timezone report
  hr
fi

# --- 0b. 打印当前(被封)账号信息，便于核对你删的是哪个号 ---
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
  # 安全闸：源文件存在但没备份成功，就立刻中止，绝不往下删
  if [[ -f "$CRED" && ! -f "$BACKUP_DIR/.credentials.json" ]]; then
    echo "ERROR: 凭据备份失败，已中止（未删除任何东西）"; exit 1
  fi
  if [[ -f "$CONFIG" && ! -f "$BACKUP_DIR/.claude.json" ]]; then
    echo "ERROR: 配置备份失败，已中止（未删除任何东西）"; exit 1
  fi
fi

# --- 2. 把被封账号留个案底（只记身份，不记 token）---
say "[2/4] 记录被封账号到 $CLAUDE_DIR/banned-accounts.log"
if [[ $APPLY -eq 1 && -f "$CONFIG" ]]; then
  jq -c --arg ts "$TS_ISO" '{bannedAt:$ts, account:(.oauthAccount // null), userID:.userID}' "$CONFIG" \
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
  jq -e . "$tmp" >/dev/null          # 校验生成的 JSON 合法再覆盖，避免把配置写坏
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
  say "回滚：$0 --rollback"
fi
hr
