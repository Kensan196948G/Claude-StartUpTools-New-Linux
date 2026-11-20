# formal — 形式検証 (TLA+ / TLC)

## 何を検証しているか

`formal/specs/run_ledger.tla` は **Durable Agent Execution 台帳 (`lib/run-ledger.sh`) の状態機械**を
TLA+ で書いたモデルです。bash 実装の「状態遷移の意図」を形式化し、TLC で全状態を探索して
不変条件と時間性質を機械検証します。

| 性質 | 内容 |
|---|---|
| `TypeOK` | 状態・数値の型 |
| `AttemptsBounded` | `attempts` が上限を超えない |
| `ResumableRequiresCheckpoint` | checkpoint 無しで `attempts` が増えない (= 「checkpoint が無い run を再開成功と偽らない」) |
| `TerminalStable` | 終了状態 (`completed`/`failed`/`blocked`) に入ったら二度と遷移しない (`[]` の時間性質) |

## 実行方法

```bash
bash scripts/tools/tla-check.sh check          # 前提 (java / jar) の確認
bash scripts/tools/tla-check.sh run            # 既定: formal/specs/run_ledger.tla を検証
bash scripts/tools/tla-check.sh run --json     # 機械可読な結果
bash scripts/tools/tla-check.sh run --dry-run  # 実行するコマンドだけ表示
bash scripts/tools/tla-check.sh run --no-download   # jar を取得しない (未取得なら明示的に失敗)
```

- TLC (`tla2tools.jar`) は `${CCSU_FORMAL_CACHE:-~/.cache/claudeos/formal}` にキャッシュされます。
  取得元は TLA+ 公式リリース (`tlaplus/tlaplus` の latest `tla2tools.jar`)。
- `CCSU_TLA_JAR_SHA256` を設定すると取得物のハッシュを検証します。
- 終了コード: `0` 検証成功 / `1` 反例あり / `2` 解析失敗・前提エラー / `3` jar 取得不可。
  **解析失敗を「反例あり」と混同しません** (どちらも「検証成功」とは報告しません)。

## 実測結果 (2026-09-25, このホスト)

```
$ bash scripts/tools/tla-check.sh run --json | jq -c '{result,states_generated,distinct_states}'
{"result":"verified","states_generated":146,"distinct_states":60}
```

- TLC: `No error has been found`, 146 states generated / 60 distinct / depth 7, 約 2 秒。

## 検出力の証明 (この検査が本当に反例を出すこと)

「検証が通った」だけでは検査が機能している証拠になりません。`Resume` の前提
(`status \in NonTerminal`) を `status \in Statuses` に緩めた壊れた仕様を渡すと:

```
$ bash scripts/tools/tla-check.sh run <broken>/run_ledger.tla --json | jq -r .result
violation
$ echo $?   # 1
```

TLC が返した反例 (抜粋):

```
Error: Temporal properties were violated.
Error: The following behavior constitutes a counter-example:
State 3: <Finish ...>       /\ checkpoints = 1  /\ attempts = 1  /\ status = "blocked"
State 4: <Resume ...>       /\ checkpoints = 1  /\ attempts = 2  /\ status = "running"
```

終了状態 `blocked` から `running` へ復活する挙動が、まさに `TerminalStable` の違反として
検出されています。**bash 実装の状態遷移を緩める変更を入れた場合、同じ種類の穴を
この仕様側で先に検出できます** (テストの「通った」だけで安心しないための層)。

## 仕様を増やすとき

1. `formal/specs/<name>.tla` を追加する (**モジュール名はファイル名と一致させる**。
   TLA+ は一致しないと解析エラーになる)。
2. 同名の `<name>.cfg` に `SPECIFICATION` / `INVARIANT` / `PROPERTY` を書く。
3. `bash scripts/tools/tla-check.sh run formal/specs/<name>.tla` で検証する。
4. 検出力を確かめる: 仕様の前提を 1 つ緩めた版で `violation` になることを確認する。
