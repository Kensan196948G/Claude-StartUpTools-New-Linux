#!/usr/bin/env bats
# ============================================================
# cron-snapshot.bats — bin/cron-snapshot.sh の crontab 解析テスト
#   crontab を PATH スタブ化し、--stdout の JSON を検証する。
#   回帰: 6 語以上の説明コメントを「無効化された cron」と誤認しない (Cron 画面の c01〜c15 化け)。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CRON_TEXT="$TEST_TEMP/crontab.txt"
  make_stub_bin crontab '[[ "${1:-}" == "-l" ]] && cat "${CRON_TEXT:?}"'
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
}
teardown() { _bats_common_teardown; }

_snap() { run bash "$REPO_ROOT/bin/cron-snapshot.sh" --stdout; }

@test "cron-snapshot: 有効行と無効化行(#DISABLED-1#)を解析する" {
  cat > "$CRON_TEXT" <<'EOF'
0 2 * * * /opt/a.sh >> /tmp/a.log 2>&1
#DISABLED-1# */5 1-3 * jan mon-fri /opt/b.sh
EOF
  _snap
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count == 2 and .entries[0].disabled == false and .entries[0].hour == "2" and .entries[1].disabled == true and .entries[1].dow == "mon-fri"'
}

@test "cron-snapshot: 6 語以上の説明コメントはエントリにしない (回帰)" {
  cat > "$CRON_TEXT" <<'EOF'
# 2>&1 then not Do this one at a time please
# [2026-07-11] [STOPPED] 旧プロジェクト名参照のため停止 a b c
# Per-project: 0-5 evidence ingestion for the nightly run
30 3 * * 1 /opt/real.sh
EOF
  _snap
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count == 1 and .entries[0].command == "/opt/real.sh"'
}

@test "cron-snapshot: 環境変数行(# FOO=bar と FOO=bar)は無視する" {
  cat > "$CRON_TEXT" <<'EOF'
MAILTO=root
# PATH=/usr/bin a b c d e f
0 0 * * * /opt/c.sh
EOF
  _snap
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count == 1'
}
