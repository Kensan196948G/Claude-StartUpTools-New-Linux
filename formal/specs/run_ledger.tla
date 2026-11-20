------------------------------- MODULE run_ledger ------------------------------
(*
  run_ledger.tla — Durable Agent Execution 台帳 (lib/run-ledger.sh) の状態機械モデル。

  目的: bash 実装の「状態遷移の意図」を形式化し、TLC で機械検証する。
        実装と仕様が食い違ったら、仕様側の観点で反例が出る (人が読むだけでは
        見落とす遷移の穴を潰すため)。

  状態 (lib/run-ledger.sh の status と一致させる):
    running / stale / interrupted       … 進行中 (resume 可能な集合 NonTerminal)
    completed / failed / blocked        … 終了 (Terminal)

  遷移:
    Heartbeat         : running のまま生存通知 (状態は変わらない)
    Checkpoint        : running のまま checkpoint を 1 つ積む
    LoseHeartbeat     : running -> stale        (heartbeat 途絶を reconcile が検出)
    ProcessGone       : running -> interrupted  (PID 消滅を reconcile が検出)
    Resume            : NonTerminal -> running  (checkpoint がある場合のみ、attempts を増やす)
    Finish(s)         : NonTerminal -> s (s \in Terminal)

  検証する性質:
    TypeOK                       … 状態と数値の型
    AttemptsBounded              … attempts は上限を超えない
    ResumableRequiresCheckpoint  … checkpoint 無しで attempts が増えることはない
                                   (= 「checkpoint が無い run を再開成功と偽らない」)
    TerminalStable               … 終了状態に入ったら二度と遷移しない ([] の時間性質)
*)
EXTENDS Naturals

CONSTANTS MaxAttempts, MaxCheckpoints

Terminal == {"completed", "failed", "blocked"}
NonTerminal == {"running", "stale", "interrupted"}
Statuses == Terminal \cup NonTerminal

VARIABLES status, checkpoints, attempts

vars == <<status, checkpoints, attempts>>

TypeOK == /\ status \in Statuses
          /\ checkpoints \in Nat
          /\ attempts \in Nat

AttemptsBounded == attempts <= MaxAttempts

ResumableRequiresCheckpoint == (status = "running" /\ attempts > 1) => checkpoints > 0

Init == /\ status = "running"
        /\ checkpoints = 0
        /\ attempts = 1

Heartbeat == /\ status = "running"
             /\ UNCHANGED vars

Checkpoint == /\ status = "running"
              /\ checkpoints < MaxCheckpoints
              /\ checkpoints' = checkpoints + 1
              /\ UNCHANGED <<status, attempts>>

LoseHeartbeat == /\ status = "running"
                 /\ status' = "stale"
                 /\ UNCHANGED <<checkpoints, attempts>>

ProcessGone == /\ status = "running"
               /\ status' = "interrupted"
               /\ UNCHANGED <<checkpoints, attempts>>

Resume == /\ status \in NonTerminal
          /\ checkpoints > 0
          /\ attempts < MaxAttempts
          /\ status' = "running"
          /\ attempts' = attempts + 1
          /\ UNCHANGED checkpoints

Finish(s) == /\ status \in NonTerminal
             /\ s \in Terminal
             /\ status' = s
             /\ UNCHANGED <<checkpoints, attempts>>

Next == \/ Heartbeat
        \/ Checkpoint
        \/ LoseHeartbeat
        \/ ProcessGone
        \/ Resume
        \/ \E s \in Terminal : Finish(s)

Spec == Init /\ [][Next]_vars /\ WF_vars(\E s \in Terminal : Finish(s))

TerminalStable == [](status \in Terminal => [](status \in Terminal))

=============================================================================
