# cc-switch-account

官方 **Claude Code** 换号脚本：当前登录的 Claude 账号被封（或想换号）时，删除旧账号的本地登录记录，以便用新账号重新登录，**同时完整保留记忆（memory）与历史会话（transcript / session）**。

> 适用于官方 Claude Code 的本地 OAuth 登录。与第三方账号池/代理网关无关。

## 它为什么安全

官方 Claude Code 把「账号身份」和「记忆/历史」**物理分开**存。换号只需摘掉账号身份那两处，其余一律不碰。

**只动这两处账号身份：**

| 文件 | 内容 |
| --- | --- |
| `~/.claude/.credentials.json` | `claudeAiOauth`（access/refresh token、订阅档位）= 登录凭据本体 |
| `~/.claude.json` 的 `oauthAccount` + `userID` | 账号 UUID、邮箱、组织信息 |

**绝不触碰（= 你的记忆和历史）：**

- `~/.claude/projects/**/memory/*.md` — 记忆
- `~/.claude/projects/**/*.jsonl` — 历史会话 transcript
- `~/.claude/history.jsonl` — prompt 历史
- `~/.claude.json` 的 `.projects` / `settings` / `skills` / `plugins` 等其余一切

## 用法

```bash
# 干跑(dry-run)：只打印将要做什么，不改任何文件
./cc-switch-account.sh

# 真执行：备份 -> 记录被封账号 -> 摘除账号字段
./cc-switch-account.sh --yes
```

执行后运行 `claude` 并执行 `/login`，用**新账号**登录即可。记忆和历史照旧。

## 它做的事（`--yes` 时）

1. **备份** `.credentials.json` + `.claude.json` 到 `~/.claude/account-switch-backups/<时间戳>/`（可一键回滚）
2. **记案底** 把被封账号身份（不含 token）追加到 `~/.claude/banned-accounts.log`
3. **删凭据** `rm ~/.claude/.credentials.json`
4. **摘字段** `jq del(.oauthAccount) | del(.userID)`，校验生成的 JSON 合法后才覆盖

## 回滚

把 `~/.claude/account-switch-backups/<时间戳>/` 下的两个文件拷回原位即可。

## 注意

- **别在正在使用的会话里直接 `--yes`**：它删的就是当前登录凭据，会把当前会话登出。等真要换号时、或新开窗口再执行。
- 内置的 `/logout` 也能做「清凭据、保留 transcript/记忆」；本脚本是它的**非交互 + 自动备份 + 记录被封账号**加强版。

## 依赖

- `bash`、`jq`
