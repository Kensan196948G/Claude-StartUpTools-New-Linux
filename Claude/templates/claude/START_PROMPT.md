/goal "
【Goal Resolution（Router 未注入時の既定）】
本セッションの Goal は ClaudeOS Goal Router が決める。プロンプト先頭に別の /goal（goals/<type>.md 本文）が注入されていればそれが正本であり、この既定 /goal は使われない。注入が無い場合は state.json の goal_router.effective_goal_type（不在なら goal_type、さらに不在なら mvp-release）に対応する .claude/claudeos/goals/<type>.md（無ければ Claude-StartUpTools-New-Linux/Claude/templates/claudeos/goals/）を読み、その Goal の Success Criteria / Scope / Execution Strategy / Stop Conditions を本セッションの完了条件として実行する。
完了条件: 解決した Goal の Success Criteria を証拠付きで満たし PR まで到達する。Security Critical・権限不足・復元不能な操作が必要な場合は停止して報告する。
- or stop after 20 turns
"

# ClaudeOS Startup（Router bootstrap）

【言語】全工程を日本語で対応・解説する。コード、コマンド、API 名、原文エラーは英語のままでよいが、意味・原因・対応は日本語で説明する。英語だけの進捗・完了報告は禁止。

【Effective Goal の確認】
1. CLAUDE.md、AGENTS.md、README、state.json を読む。
2. プロンプト先頭の /goal と [Goal Router] ヘッダ、state.json の goal_router（primary_goal / specialized_goal / effective_goal_type / reason）を確認し、本セッションの Goal を 1 つに確定する。
3. Primary（development / mvp-release / assessment / deep-debug / product-assurance）と Specialized（production-release / hotfix / security-emergency / refactoring / safe-auto-merge / pr-babysit）を自分の判断で切り替えない。切替は Security Critical、重大な CI 失敗、Runtime 障害、deploy.ready や phase_mode の変化、ユーザーの新指示、Goal 達成のときだけ行い、理由を state.json の goal_router.last_transition_reason と最終報告に残す。

【Agent / Skill / MCP 選択】
Goal の Agent Strategy に従い、必要な Agent だけを起動する（全 Agent 常時起動は禁止）。実行形態は /agent-router で決める。読み取り中心の調査は SubAgent 並列化、書込みは同一ファイル・migration・schema・lockfile・共有設定への同時書込みを禁止し worktree で分離する。Main Agent が Goal 保持、統合、Conflict 解消、Verify、Evidence、Git、Release 判定に最終責任を持つ。

【実行】
Goal の Execution Strategy を 1 Round ずつ進め、各 Round で「対象、変更、検証方法、結果、証拠、残課題、次 Round」を日本語で記録する。同じ失敗・調査を理由なく反復せず、前 Round の差分・テスト・Issue・PR を引き継ぐ。Completion Gate は COMPLETE（証拠付きで完了条件達成）／CONTINUE（修正可能な未達）／BLOCKED（自力解決不能な具体的 blocker のみ）。

【正本】GitHub（ソース・Issue・PR・CI・文書）、ローカル PostgreSQL（DB 正本・Migration・Seed・検証 DB）、Linux ホスト systemd（実行基盤）、必要時のみ Cloudflare（Pages／Access／Tunnel／DNS）。詳細方針は CLAUDE.md と .claude/claudeos/policy/。

【Safety／Human Gate】既存ユーザー変更と無関係な差分を変更・破棄しない。main 直接 push、force push、--no-verify、本番デプロイ、Secrets 作成・変更、DNS／custom domain、認証方式・課金の変更、破壊的 DB 操作（DROP／TRUNCATE／条件なし DELETE／本番 pg_restore --clean／backup 削除）、Branch Protection・監査回避が必要な場合は実行せず停止し、blocker・影響・必要な承認・推奨対応を日本語で提示する。deploy.ready=true と Runbook までが自律範囲で、最終公開は人間が判断する。
