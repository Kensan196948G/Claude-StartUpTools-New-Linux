------------------------------- MODULE ship_gate -------------------------------
(*
  ship_gate.tla — Ship Native の Human Gate / Merge Executor の安全性モデル
  (scripts/ship/lib/human-gate.js・merge.js・state-machine.js の意図を形式化)

  世界:
    head      PR の現在の head (コミットのたびに増える整数)
    base      base ブランチの現在の SHA
    gatePass  head/base に対する AI Quality Gate が PASS か (gateHead/gateBase に対して)
    approvals 発行された承認の集合 [h |-> 承認時 head, b |-> 承認時 base, used |-> nonce 使用済み]
    revoked   取り消された承認の集合
    merged    マージされたか / mergedHead マージ時の head
    agentPush AI (Ship watch 含む) がコミットを積める

  行為:
    Push        : AI が head を進める (承認後でも起こり得る)
    BaseMoves   : base が進む
    Gate        : 現在の head/base を判定する (PASS / 非 PASS)
    Approve     : 人間が「現在の head/base かつ gate PASS」の場合だけ承認を発行する
    Revoke      : 人間が承認を取り消す
    Merge       : Merge Executor。有効な承認 (現 head/base 一致・未使用・未取り消し・gate PASS) がある場合だけ、
                  nonce を消費してマージする
    AgentMergeAttempt : AI が承認を経ずにマージを試みる → ruleset の必須 status が無いので常に失敗 (状態不変)

  性質:
    NoMergeWithoutApproval  … マージされたなら、マージ時の head/base に一致する承認が存在した
    MergedHeadWasGated      … マージ時の head は gate PASS を受けている
    NonceSingleUse          … 1 つの承認で 2 回マージしない (マージは高々 1 回 + used)
*)
EXTENDS Naturals, FiniteSets

CONSTANTS MaxHead, MaxBase

VARIABLES head, base, gateHead, gateBase, gatePass, approvals, revoked, merged, mergedHead, mergedBase, merges

vars == <<head, base, gateHead, gateBase, gatePass, approvals, revoked, merged, mergedHead, mergedBase, merges>>

Approval == [h : 0..MaxHead, b : 0..MaxBase, used : BOOLEAN]

Init == /\ head = 0 /\ base = 0
        /\ gateHead = 0 /\ gateBase = 0 /\ gatePass = FALSE
        /\ approvals = {} /\ revoked = {}
        /\ merged = FALSE /\ mergedHead = 0 /\ mergedBase = 0 /\ merges = 0

Push == /\ ~merged /\ head < MaxHead
        /\ head' = head + 1
        /\ UNCHANGED <<base, gateHead, gateBase, gatePass, approvals, revoked, merged, mergedHead, mergedBase, merges>>

BaseMoves == /\ ~merged /\ base < MaxBase
             /\ base' = base + 1
             /\ UNCHANGED <<head, gateHead, gateBase, gatePass, approvals, revoked, merged, mergedHead, mergedBase, merges>>

Gate(pass) == /\ ~merged
              /\ gateHead' = head /\ gateBase' = base /\ gatePass' = pass
              /\ UNCHANGED <<head, base, approvals, revoked, merged, mergedHead, mergedBase, merges>>

GateCurrent == gatePass /\ gateHead = head /\ gateBase = base

Approve == /\ ~merged /\ GateCurrent
           /\ approvals' = approvals \cup {[h |-> head, b |-> base, used |-> FALSE]}
           /\ UNCHANGED <<head, base, gateHead, gateBase, gatePass, revoked, merged, mergedHead, mergedBase, merges>>

Revoke(a) == /\ a \in approvals
             /\ revoked' = revoked \cup {[h |-> a.h, b |-> a.b]}
             /\ UNCHANGED <<head, base, gateHead, gateBase, gatePass, approvals, merged, mergedHead, mergedBase, merges>>

Valid(a) == /\ a \in approvals /\ ~a.used
            /\ a.h = head /\ a.b = base
            /\ [h |-> a.h, b |-> a.b] \notin revoked
            /\ GateCurrent

Merge == /\ ~merged
         /\ \E a \in approvals :
              /\ Valid(a)
              /\ approvals' = (approvals \ {a}) \cup {[a EXCEPT !.used = TRUE]}
         /\ merged' = TRUE /\ mergedHead' = head /\ mergedBase' = base /\ merges' = merges + 1
         /\ UNCHANGED <<head, base, gateHead, gateBase, gatePass, revoked>>

\* 承認経路外のマージ試行: GitHub ruleset が承認 status (SHA 単位) を要求するため失敗する
AgentMergeAttempt == /\ ~merged
                     /\ ~(\E a \in approvals : a.h = head /\ ~a.used)
                     /\ UNCHANGED vars

Next == \/ Push \/ BaseMoves \/ Gate(TRUE) \/ Gate(FALSE) \/ Approve
        \/ \E a \in approvals : Revoke(a)
        \/ Merge \/ AgentMergeAttempt

Spec == Init /\ [][Next]_vars

TypeOK == /\ head \in 0..MaxHead /\ base \in 0..MaxBase
          /\ approvals \subseteq Approval
          /\ merged \in BOOLEAN /\ merges \in 0..1

NoMergeWithoutApproval == merged => \E a \in approvals : a.h = mergedHead /\ a.b = mergedBase /\ a.used
MergedHeadWasGated == merged => (gatePass /\ gateHead = mergedHead /\ gateBase = mergedBase)
NonceSingleUse == merges <= 1
MergeIsFinal == [][merged => merged']_vars
=============================================================================
