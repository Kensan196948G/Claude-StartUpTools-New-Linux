# /mcp-memory-check

MCP memory の user scope / project scope 分離が守られているか確認するコマンドです。

実行方針:

- ファイル変更前に必ず dry-run で対象プロジェクトと `.mcp.json` 差分方針を確認する。
- 公式 Memory MCP は user scope 専用として扱い、project `.mcp.json` には原則入れない。
- project memory は ByteRover/Cipher 系を優先し、Serena は大規模な symbol 調査・編集が必要な場合だけ使う。
- token / secret / credential / CI ログ全文 / ブランチ一時メモは memory に保存しない。

確認コマンド:

```bash
node scripts/setup/install-mcp.js --all --dry --prune-disabled-catalog
```

確認項目:

- `memory` が project `.mcp.json` から除外されるか
- `brv` MCP server が ByteRover CLI 導入済み環境で有効化されるか
- `brv` 未導入環境では `brv` が `skipped=brv` として報告されるか
- `serena` が state.json の `mcp.enabled` に明示されている project だけで有効化されるか
- 既存の手作業 MCP エントリが保持されるか

適用コマンド:

```bash
node scripts/setup/install-mcp.js --all --apply --prune-disabled-catalog
```

出力形式:

```text
MCP Memory Scope Check
- Status: ready | partial | blocked
- User-scope memory:
- Project-scope memory:
- Optional Serena:
- Registered projects:
- Dry-run result:
- Apply command:
- Risks:
- Next action:
```

`Status: blocked` の条件:

- `.mcp.json` に secret が平文で含まれる
- user scope と project scope が同じ `MEMORY_FILE_PATH` を共有している
- `state.json.mcp.enabled` が project memory と user memory の境界に反している
- `brv` 未導入だが project memory 必須の作業を始めようとしている
