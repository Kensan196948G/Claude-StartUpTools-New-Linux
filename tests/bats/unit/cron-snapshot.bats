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

# 「今すぐ実行」を ClaudeOS 管理分だけに限るため、台帳印 (# CLAUDEOS:<id> project=… duration=…) を claudeos として残す
@test "cron-snapshot: 台帳印の直後の cron 行に claudeos (id/project/duration/created/goal) を付け、印なしの行には付けない" {
  cat > "$CRON_TEXT" <<'EOF'
# CLAUDEOS:ab12cd project=Mirai-DX-Project/Beta-Site duration=300 created=2026-11-23T01:00:00 goal=pr-babysit
0 2 * * 1,2 CLAUDEOS_GOAL_TYPE_OVERRIDE=pr-babysit bash /x/cron-launcher.sh Mirai-DX-Project/Beta-Site 300 >> /tmp/l.log 2>&1
0 3 * * * rm -rf /tmp/other
EOF
  _snap
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count == 2'                                    # 印の行そのものはエントリにしない
  echo "$output" | jq -e '.entries[0].claudeos == {id:"ab12cd", project:"Mirai-DX-Project/Beta-Site", duration:300, created:"2026-11-23T01:00:00", goal:"pr-babysit"}'
  echo "$output" | jq -e '.entries[1] | has("claudeos") | not'            # 他用途の生コマンドには付けない
}

@test "cron-snapshot: 印が効くのは直後の 1 行だけ。間に別の行があれば付けない" {
  cat > "$CRON_TEXT" <<'EOF'
# CLAUDEOS:ab12cd project=Alpha duration=60 created=2026-11-23T01:00:00
0 4 * * * /opt/other.sh
0 5 * * * bash /x/cron-launcher.sh Alpha 60
EOF
  _snap
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.entries[0].claudeos.id == "ab12cd"'            # 印の直後の行 (cron__list と同じ対応)
  echo "$output" | jq -e '.entries[1] | has("claudeos") | not'
}

@test "cron-snapshot: 無効化行 (#DISABLED-1#) にも印を付ける。他の接頭辞 (OPENCODE) や読めない印は付けない" {
  cat > "$CRON_TEXT" <<'EOF'
# CLAUDEOS:d1 project=Alpha duration=60 created=2026-11-23T01:00:00
#DISABLED-1# 0 2 * * 1 bash /x/cron-launcher.sh Alpha 60
# OPENCODE:o1 project=Beta duration=60 created=2026-11-23T01:00:00
0 3 * * 1 bash /x/other-launcher.sh Beta 60
# CLAUDEOS:bad1 created=2026-11-23T01:00:00
0 4 * * 1 bash /x/cron-launcher.sh Gamma 60
# CLAUDEOSX:x1 project=Delta duration=60
0 5 * * 1 bash /x/cron-launcher.sh Delta 60
EOF
  _snap
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.entries[0].disabled == true and .entries[0].claudeos.id == "d1"'
  echo "$output" | jq -e '[.entries[1:][] | has("claudeos")] | any | not'  # OPENCODE・project 無し・接頭辞が違う印は管理対象にしない
}

@test "cron-snapshot: project に引用符や制御文字が入っていても JSON は壊れず、値は無害化される" {
  printf '%s\n' '# CLAUDEOS:q1 project=Al"pha\x duration=60 created=2026-11-23T01:00:00' '0 2 * * 1 bash /x/cron-launcher.sh Alpha 60' > "$CRON_TEXT"
  _snap
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.entries[0].claudeos.project == "Al\"pha\\x"'
}
