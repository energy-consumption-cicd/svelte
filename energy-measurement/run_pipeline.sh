#!/usr/bin/env bash

set -euo pipefail
# Numeric formatting in awk must not follow the locale of the invoking shell.
export LC_ALL=C

RUN_NUM="${1:?run number required (e.g. 1)}"
PROJECT_NAME="svelte"
IMAGE_NAME="${IMAGE_NAME:-svelte-measurement-5.55.0}"
MEDICAO_DIR="${MEDICAO_DIR:-$HOME/experimentos/medicao/repositorios/svelte-measurement/release-5.55.0}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/experimentos/medicao/resultados/svelte-measurement/release-5.55.0/runs}"
LOGS_DIR="${LOGS_DIR:-$HOME/experimentos/medicao/resultados/svelte-measurement/release-5.55.0/logs}"
RAPL_BASE="/sys/class/powercap/intel-rapl"
# Idle baseline measured before each run; its per-second rate is subtracted
# from every stage so reported energy reflects workload above idle.
BASELINE_DURATION=120
# Pre-condition on the bench, checked before any workload runs: an idle package
# rate above this means the bench is not idle, and the run is not started.
# Exit 90 sits outside every declared workload exit code; ENERGY_BASELINE_GATE=off
# disables it for declared diagnostic sessions only.
BASELINE_GATE_MAX_PKG_W=1.0
BASELINE_GATE_EXIT=90
ENERGY_BASELINE_GATE="${ENERGY_BASELINE_GATE:-on}"
# Stage ceilings: a hung harness costs one run, not the job's 20 h. Exit 91 sits
# outside every declared workload exit code, like 90. Values fixed in the
# pre-registration of this release from its rehearsal on the measurement
# bench: 1.5x the largest wall of each stage, rounded up; the
# real cost is the ceiling plus the 30 s of -k. Non-default values are for
# declared diagnostic sessions only.
STAGE_TIMEOUT_BUILD_DEFAULT=40
STAGE_TIMEOUT_TEST_DEFAULT=130
ENERGY_STAGE_TIMEOUT_BUILD_S="${ENERGY_STAGE_TIMEOUT_BUILD_S:-$STAGE_TIMEOUT_BUILD_DEFAULT}"
ENERGY_STAGE_TIMEOUT_TEST_S="${ENERGY_STAGE_TIMEOUT_TEST_S:-$STAGE_TIMEOUT_TEST_DEFAULT}"
STAGE_TIMEOUT_EXIT=91
# Rehearsal only: pins the container to a CPU set to emulate the bench. Empty
# on the campaign, where no CPU limit is applied.
ENERGY_CPUSET="${ENERGY_CPUSET:-}"
TIME_FILE="/tmp/svelte_5.55.0_time_$$.txt"
CSV_FILE="$RESULTS_DIR/run_$(printf '%02d' "$RUN_NUM").csv"
EXITS_FILE="$RESULTS_DIR/exit_codes_run_$(printf '%02d' "$RUN_NUM").txt"
ARTIFACT_FILE="$RESULTS_DIR/artifact_check_run_$(printf '%02d' "$RUN_NUM").txt"
BASELINE_DISCARD_FILE="$RESULTS_DIR/discarded_baseline_run_$(printf '%02d' "$RUN_NUM").txt"
TIMEOUT_DISCARD_FILE="$RESULTS_DIR/discarded_timeout_run_$(printf '%02d' "$RUN_NUM").txt"

# No swap inside the container: the limit is the bench's usable RAM.
MEM_LIMIT="${MEM_LIMIT:-12g}"
MEM_SWAP="${MEM_SWAP:-$MEM_LIMIT}"

# Files the build writes under /workspace outside node_modules, with their
# sha256, identical in every rehearsal build. The tracked ones equal the
# reference commit, which is what the job's git status check requires.
BUILD_MANIFEST=$(cat <<'EOM'
34ec1090535e4aac1d309e7f49e1b7455ba8f3840dacf576ab06ae57db8c8935 documentation/docs/98-reference/.generated/client-errors.md
971d421df3e305f02b90b327f273bd17259fcbaec3a812236e10825941ba5cb1 documentation/docs/98-reference/.generated/client-warnings.md
a26fdf97a4f3b999a72fefd3aa3456bd8c7feb6a236ce9c2d1bf62b5fe4bf8c9 documentation/docs/98-reference/.generated/compile-errors.md
09fbf019deaacffb230ac81ee25b16d86e2c8c6fac9707d9e544f65181e30f6c documentation/docs/98-reference/.generated/compile-warnings.md
b42a7201f65841154c43300529784f8d7f536e4e19d92f0dfeb72451ee7578d3 documentation/docs/98-reference/.generated/server-errors.md
cbeb399c42bbeff71b5216acbaa04465846dac74fbc4b2888a55758712522afa documentation/docs/98-reference/.generated/server-warnings.md
2a0c6d7929f17f24732bd22e3b52e20efcef11796b802cc69c389e57782fed30 documentation/docs/98-reference/.generated/shared-errors.md
c13248e3d69424a36f3e59022dc8c4f8ea1ef89801b75b0bc1d1bf29f5811e48 documentation/docs/98-reference/.generated/shared-warnings.md
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/action.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/animate.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/compiler.d.ts
a6f1d7ed71830ac2bbc93427f6743373c96c34ab2e9579b1f40cc0dbcd3ca5f7 packages/svelte/compiler/index.js
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/easing.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/index.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/legacy.d.ts
7f120c3e0b99bd566d0c69d0bf23a9cb12fceaaea05fada6862ab4f178acddf0 packages/svelte/messages/client-errors/errors.md
1c74683c355cd5cdb6a7e4b0b36a203b0e83f06cb6adc4559e6b5e9db65a2e18 packages/svelte/messages/client-warnings/warnings.md
fe158cbbe01f9e552e9aae54d83a6c0f22313bd4fc8e4d81f7d60077a23c054b packages/svelte/messages/compile-errors/options.md
f0a9efc5ba558af59b958f82096ffcdaecbe77be582341eb471788256115003d packages/svelte/messages/compile-errors/script.md
76f40e6669f7f6c1c97c9f2122415a96044a45987b29b8eb2240cb110ce34f17 packages/svelte/messages/compile-errors/style.md
61463bdebc49bb1eedab23f8ea5959619709083962d8cc63d9bbc572f1b18c4c packages/svelte/messages/compile-errors/template.md
c1ec07b8b50b7b0c174fd28a5ae285053f4ac3309b08a0a3955a7d27d17da16f packages/svelte/messages/compile-warnings/a11y.md
53ea3262a4297f69155c2a51af6ffc8f54784e9604976827186c837f6bec2534 packages/svelte/messages/compile-warnings/misc.md
c57f6995999d93ab6567d8e444e7e78e840b0cf686adb8e2329fbb8d23342964 packages/svelte/messages/compile-warnings/options.md
4d915c45fbe84d77082f957fbc688310cefb735d92f94dc1ee1cb56a1dc61bd3 packages/svelte/messages/compile-warnings/script.md
62774d11eed09a5ee5bfb6c35341af3485aac144cd79b69b6e11aea8662f7d9f packages/svelte/messages/compile-warnings/style.md
d5c1cab2a8b59875d027a8bf671097adfeafbf17c1314d7a0613c963b38f5101 packages/svelte/messages/compile-warnings/template.md
6073c67448dd6114fa472445ce6a8a10f508fbaf0ac003dbeb5b20b8c60f8900 packages/svelte/messages/server-errors/errors.md
166e371ff5719cfc4e0049a01f4db28a4f3658f3a4b3787496ced89e249cfed1 packages/svelte/messages/server-warnings/warnings.md
3100d29b3618c098115a0f4becc8814646a4b812598017f4d8f7a50ec57be18f packages/svelte/messages/shared-errors/errors.md
12757b112f92aff6a73d1860179aafa2d020d57c80fbc73ebc7a1ca1f5c2409c packages/svelte/messages/shared-warnings/warnings.md
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/motion.d.ts
ab72632e4b6273a84f417d4829c4e7eef010b0e29e1a0b8c572ac77e3594b03a packages/svelte/src/compiler/errors.js
627445d684aef6fa3fdb89e82e1ae33121db31e4abd0d1dc6de4b6656f9e4ba2 packages/svelte/src/compiler/warnings.js
d96c72c370056afe93d81c25cf0414ff87b7a9632ffca63842cb412fb3053a38 packages/svelte/src/internal/client/errors.js
908d85329f513575153a81922d2c3d250e2eef9ed3a13501bf50e7d07ac048d7 packages/svelte/src/internal/client/warnings.js
f2cd54f03a0dac530b5897e4e7f1ff484ea30bfcf9d39dd85f67660be9254e6e packages/svelte/src/internal/server/errors.js
030daa03dfbf35f12cb179532d323ebb12ca8b855e0fba0d293f9d284016a336 packages/svelte/src/internal/server/warnings.js
a2bd1a0dbf5be3dfaa5e324d62a3262ad57278b4ed66603afa857bf59121089d packages/svelte/src/internal/shared/errors.js
af3fb78d28b5aa427d738ccc513559de7699d2be11e3ffb2ed98e250173ce940 packages/svelte/src/internal/shared/warnings.js
c03e66736076d1f9f8031fa2cfa9a5253c431933aea5def43e7cc602d8b7cc2c packages/svelte/src/version.js
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/store.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/transition.d.ts
e873776e929f9ceecb85f4f3fabefa870a9b954f08300c4acb61d12f8b8b67ac packages/svelte/types/compiler/interfaces.d.ts
e873776e929f9ceecb85f4f3fabefa870a9b954f08300c4acb61d12f8b8b67ac packages/svelte/types/compiler/preprocess.d.ts
3260db393c9cc4c907c5a71d1fde1fd6735edeaa8e37ee4cb3eea3c29e91d952 packages/svelte/types/index.d.ts
5ac5b13467b32818013ce6e9e0f93f39f3f30680008cd72a357867564908d3ed packages/svelte/types/index.d.ts.map
EOM
)
BUILD_MANIFEST_N=$(printf '%s\n' "$BUILD_MANIFEST" | grep -c .)
TEST_FILES_EXPECTED="Test Files 31 passed (31)"
TEST_TESTS_EXPECTED="Tests 7419 passed | 51 skipped (7470)"

PIPELINE_EXIT=0
FAILED_STAGES=""
NONCONFORM_STAGES=""

# A signal to the docker client does not stop the container; kill it by name.
# The build container is kept after it exits, so it is removed here as well.
CURRENT_CONTAINER=""
cleanup_container() {
  if [ -n "$CURRENT_CONTAINER" ]; then
    docker kill "$CURRENT_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup_container EXIT INT TERM

mkdir -p "$RESULTS_DIR" "$LOGS_DIR"

if [ ! -d "$RAPL_BASE" ]; then
  echo "RAPL not available at $RAPL_BASE" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Docker image '$IMAGE_NAME' not found." >&2
  echo "  Build it first, from a checkout of this repository:" >&2
  echo "  docker build -t $IMAGE_NAME -f energy-measurement/Dockerfile energy-measurement" >&2
  exit 1
fi

: > "$EXITS_FILE"
: > "$ARTIFACT_FILE"

# Records which RAPL domains the bench exposes, so a zero column is auditable.
for d in "$RAPL_BASE"/*/ "$RAPL_BASE"/*/*/; do [ -f "$d/name" ] && printf '%s,%s\n' "$(basename "$d")" "$(cat "$d/name")"; done > "$RESULTS_DIR/rapl_domains_run_$(printf '%02d' "$RUN_NUM").txt"

read_rapl() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]] || \
       [[ "$name" == "core"      && "$domain_name" == "cores" ]] || \
       [[ "$name" == "uncore"    && "$domain_name" == "gpu" ]] || \
       [[ "$name" == "dram"      && "$domain_name" == "ram" ]]; then
      local energy_file="$dir/energy_uj"
      [ -f "$energy_file" ] && value=$(cat "$energy_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_energy="$subdir/energy_uj"
        [ -f "$sub_energy" ] && value=$(cat "$sub_energy") && break 2
      fi
    done
  done
  echo "$value"
}

read_rapl_max() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]]; then
      local max_file="$dir/max_energy_range_uj"
      [ -f "$max_file" ] && value=$(cat "$max_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_max="$subdir/max_energy_range_uj"
        [ -f "$sub_max" ] && value=$(cat "$sub_max") && break 2
      fi
    done
  done
  [ "$value" -eq 0 ] && value=999999999999
  echo "$value"
}

# Host swap counters and package temperature, read immediately before and
# after each stage's RAPL window, never inside it; recorded as sidecars, not
# CSV columns (the 14-column schema is pre-registered).
read_swap() { awk -v k="$1" '$1==k {print $2}' /proc/vmstat; }
TEMP_SENSOR=""
for hw in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$hw/name" 2>/dev/null)" = "coretemp" ] || continue
  for lbl in "$hw"/temp*_label; do
    [ "$(cat "$lbl" 2>/dev/null)" = "Package id 0" ] && TEMP_SENSOR="${lbl%_label}_input" && break 2
  done
done
read_temp_c() { if [ -n "$TEMP_SENSOR" ] && [ -r "$TEMP_SENSOR" ]; then awk '{printf "%.1f", $1/1000}' "$TEMP_SENSOR"; else echo ""; fi; }

# RAPL counters wrap at max_energy_range_uj; deltas are overflow-corrected.
delta_uj() {
  local ini="$1" fin="$2" max="$3"
  if [ "$fin" -ge "$ini" ]; then
    echo $(( fin - ini ))
  else
    echo $(( max - ini + fin ))
  fi
}

echo ""
echo ""
echo " Run $RUN_NUM - $PROJECT_NAME"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Baseline rest (${BASELINE_DURATION}s)..."

b_pkg_ini=$(read_rapl pkg)
b_cores_ini=$(read_rapl cores)
b_gpu_ini=$(read_rapl gpu)
b_ram_ini=$(read_rapl ram)

sleep "$BASELINE_DURATION"

b_pkg_fin=$(read_rapl pkg)
b_cores_fin=$(read_rapl cores)
b_gpu_fin=$(read_rapl gpu)
b_ram_fin=$(read_rapl ram)

max_pkg=$(read_rapl_max pkg)
max_cores=$(read_rapl_max cores)
max_gpu=$(read_rapl_max gpu)
max_ram=$(read_rapl_max ram)

b_delta_pkg=$(delta_uj "$b_pkg_ini" "$b_pkg_fin" "$max_pkg")
b_delta_cores=$(delta_uj "$b_cores_ini" "$b_cores_fin" "$max_cores")
b_delta_gpu=$(delta_uj "$b_gpu_ini" "$b_gpu_fin" "$max_gpu")
b_delta_ram=$(delta_uj "$b_ram_ini" "$b_ram_fin" "$max_ram")

taxa_pkg=$(awk  "BEGIN {printf \"%.6f\", $b_delta_pkg  / $BASELINE_DURATION}")
taxa_cores=$(awk "BEGIN {printf \"%.6f\", $b_delta_cores / $BASELINE_DURATION}")
taxa_gpu=$(awk  "BEGIN {printf \"%.6f\", $b_delta_gpu  / $BASELINE_DURATION}")
taxa_ram=$(awk  "BEGIN {printf \"%.6f\", $b_delta_ram  / $BASELINE_DURATION}")

# Recorded per run: the rate drives the subtraction, so it has to be auditable
# alongside the energy it produced.
taxa_pkg_w=$(awk   "BEGIN {printf \"%.6f\", $taxa_pkg   / 1e6}")
taxa_cores_w=$(awk "BEGIN {printf \"%.6f\", $taxa_cores / 1e6}")
taxa_ram_w=$(awk   "BEGIN {printf \"%.6f\", $taxa_ram   / 1e6}")

echo "Baseline rate:"
echo "   pkg:   $(awk "BEGIN {printf \"%.2f\", $taxa_pkg_w}") W"
echo "   cores: $(awk "BEGIN {printf \"%.2f\", $taxa_cores_w}") W"
echo "   ram:   $(awk "BEGIN {printf \"%.2f\", $taxa_ram_w}") W"

if [ "$ENERGY_BASELINE_GATE" != "off" ] && \
   awk "BEGIN {exit !($taxa_pkg_w > $BASELINE_GATE_MAX_PKG_W)}"; then
  {
    echo "run,$RUN_NUM"
    echo "timestamp_utc,$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "baseline_rate_pkg_w,$taxa_pkg_w"
    echo "baseline_rate_cores_w,$taxa_cores_w"
    echo "baseline_rate_ram_w,$taxa_ram_w"
    echo "threshold_pkg_w,$BASELINE_GATE_MAX_PKG_W"
  } > "$BASELINE_DISCARD_FILE"
  echo "::error title=Baseline gate::run $RUN_NUM: idle package rate ${taxa_pkg_w} W exceeds ${BASELINE_GATE_MAX_PKG_W} W; the bench is not idle. Run not started; see $BASELINE_DISCARD_FILE"
  rm -f "$EXITS_FILE" "$ARTIFACT_FILE"
  exit "$BASELINE_GATE_EXIT"
fi
if [ "$ENERGY_BASELINE_GATE" = "off" ]; then
  echo "::warning title=Baseline gate disabled::ENERGY_BASELINE_GATE=off for run $RUN_NUM (diagnostic session; must be declared)"
fi
if [ "$ENERGY_STAGE_TIMEOUT_BUILD_S" != "$STAGE_TIMEOUT_BUILD_DEFAULT" ] || \
   [ "$ENERGY_STAGE_TIMEOUT_TEST_S" != "$STAGE_TIMEOUT_TEST_DEFAULT" ]; then
  echo "::warning title=Stage ceiling changed::build ${ENERGY_STAGE_TIMEOUT_BUILD_S}s, test ${ENERGY_STAGE_TIMEOUT_TEST_S}s for run $RUN_NUM (pre-registered ${STAGE_TIMEOUT_BUILD_DEFAULT}s/${STAGE_TIMEOUT_TEST_DEFAULT}s; diagnostic session; must be declared)"
fi
if [ -n "$ENERGY_CPUSET" ]; then
  echo "::warning title=CPU set pinned::ENERGY_CPUSET=$ENERGY_CPUSET for run $RUN_NUM (rehearsal only; the campaign applies no CPU limit)"
fi

echo "run,stage,energy_pkg_j,energy_cores_j,energy_gpu_j,energy_ram_j,wall_time_s,user_time_s,sys_time_s,energy_ram_liquid_raw_j,wall_time_container_s,baseline_rate_pkg_w,baseline_rate_cores_w,baseline_rate_ram_w" \
  > "$CSV_FILE"

total_pkg=0; total_cores=0; total_gpu=0; total_ram=0; total_ram_raw=0
total_wall=0; total_user=0; total_sys=0; total_wall_container=0

# Ceiling reached: no measurement exists, so no CSV row; the sidecar records the
# ceiling applied and the last known progress marker, and the run exits 91.
abort_stage_timeout() {
  local stage="$1" ceiling="$2" texit="$3" cname="$4" start_utc="$5" stage_log="$6" wall="$7"
  local abort_utc kill_result marker last_line last_utc
  abort_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if docker kill "$cname" >/dev/null 2>&1; then kill_result="ok"; else kill_result="no-such-container"; fi
  docker rm -f "$cname" >/dev/null 2>&1 || true
  CURRENT_CONTAINER=""
  # Every lookup below may legitimately find nothing; none may trip errexit.
  marker=$(grep -E '^=== .*: start ' "$stage_log" 2>/dev/null | tail -n 1 || true)
  last_line=$(tail -n 1 "$stage_log" 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | cut -c1-200 || true)
  last_utc=$(date -u -r "$stage_log" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "-")
  {
    echo "run,$RUN_NUM"
    echo "stage,$stage"
    echo "timeout_s,$ceiling"
    echo "timeout_exit,$texit"
    echo "start_utc,$start_utc"
    echo "abort_utc,$abort_utc"
    echo "wall_observed_s,$wall"
    echo "container,$cname"
    echo "docker_kill,$kill_result"
    echo "stage_log,logs/$(basename "$stage_log")"
    echo "last_step_marker,${marker:--}"
    echo "last_log_line_utc,$last_utc"
    echo "last_log_line,${last_line:--}"
    echo "csv_row_written,no"
  } > "$TIMEOUT_DISCARD_FILE"
  echo "$RUN_NUM,$stage,$STAGE_TIMEOUT_EXIT" >> "$EXITS_FILE"
  rm -f "$CSV_FILE" "$TIME_FILE"
  echo "::error title=Stage ceiling::run $RUN_NUM, stage '$stage': ${wall}s exceeded the ${ceiling}s ceiling (timeout exit $texit); container $cname killed ($kill_result). No CSV; see $TIMEOUT_DISCARD_FILE"
  exit "$STAGE_TIMEOUT_EXIT"
}

# Outside the measured window, on the stopped build container: every regular
# file the build added or changed under /workspace, outside node_modules, must
# be a manifest entry with the manifest hash, and nothing may be deleted.
check_build() {
  local cname="$1" stage_exit="$2"
  local kind path rel ftype h expected
  local n_match=0 n_mismatch=0 n_extra=0 n_deleted=0 verdict
  local offenders=""
  while read -r kind path; do
    case "$path" in /workspace/*) ;; *) continue ;; esac
    case "$path" in */node_modules|*/node_modules/*) continue ;; esac
    rel="${path#/workspace/}"
    if [ "$kind" = "D" ]; then
      n_deleted=$((n_deleted + 1)); offenders="${offenders:+$offenders }D:$rel"; continue
    fi
    ftype=$(docker cp "$cname:$path" - 2>/dev/null | tar -tvf - 2>/dev/null | head -n 1 | cut -c1 || true)
    [ "$ftype" = "-" ] || continue
    h=$(docker cp "$cname:$path" - 2>/dev/null | tar -xOf - 2>/dev/null | sha256sum | cut -d' ' -f1 || true)
    expected=$(printf '%s\n' "$BUILD_MANIFEST" | awk -v p="$rel" '$2==p {print $1}')
    if [ -z "$expected" ]; then
      n_extra=$((n_extra + 1)); offenders="${offenders:+$offenders }A:$rel"
    elif [ "$h" = "$expected" ]; then
      n_match=$((n_match + 1))
    else
      n_mismatch=$((n_mismatch + 1)); offenders="${offenders:+$offenders }M:$rel"
    fi
  done < <(docker diff "$cname" 2>/dev/null || true)
  if [ "$stage_exit" -eq 0 ] && [ "$n_match" -eq "$BUILD_MANIFEST_N" ] && \
     [ "$n_mismatch" -eq 0 ] && [ "$n_extra" -eq 0 ] && [ "$n_deleted" -eq 0 ]; then
    verdict="conform"
  else
    verdict="nonconform"
    NONCONFORM_STAGES="${NONCONFORM_STAGES:+$NONCONFORM_STAGES }build"
  fi
  {
    echo "build_exit,$stage_exit"
    echo "build_manifest_entries,$BUILD_MANIFEST_N"
    echo "build_matching,$n_match"
    echo "build_mismatching,$n_mismatch"
    echo "build_unexpected,$n_extra"
    echo "build_deleted,$n_deleted"
    echo "build_offenders,$(printf '%s' "${offenders:--}" | cut -c1-500)"
    echo "build_verdict,$verdict"
  } >> "$ARTIFACT_FILE"
  echo "  build check: $n_match/$BUILD_MANIFEST_N matching, mismatching=$n_mismatch unexpected=$n_extra deleted=$n_deleted -> $verdict"
}

# Outside the measured window, on the stage log: the vitest summary of the
# reference runs, and no failing test.
check_test() {
  local stage_log="$1" stage_exit="$2"
  local clean files_line tests_line n_fail verdict
  clean=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$stage_log" 2>/dev/null || true)
  files_line=$(printf '%s\n' "$clean" | grep -E '^ *Test Files ' | tail -n 1 | sed -E 's/^ +//; s/ +/ /g' || true)
  tests_line=$(printf '%s\n' "$clean" | grep -E '^ *Tests ' | tail -n 1 | sed -E 's/^ +//; s/ +/ /g' || true)
  n_fail=$(printf '%s\n' "$clean" | grep -cE '(^| )FAIL( |$)' || true)
  if [ "$stage_exit" -eq 0 ] && [ "$files_line" = "$TEST_FILES_EXPECTED" ] && \
     [ "$tests_line" = "$TEST_TESTS_EXPECTED" ] && [ "$n_fail" -eq 0 ]; then
    verdict="conform"
  else
    verdict="nonconform"
    NONCONFORM_STAGES="${NONCONFORM_STAGES:+$NONCONFORM_STAGES }test"
  fi
  {
    echo "test_exit,$stage_exit"
    echo "test_files_line,${files_line:--}"
    echo "test_files_expected,$TEST_FILES_EXPECTED"
    echo "test_tests_line,${tests_line:--}"
    echo "test_tests_expected,$TEST_TESTS_EXPECTED"
    echo "test_fail_lines,$n_fail"
    echo "test_verdict,$verdict"
  } >> "$ARTIFACT_FILE"
  echo "  test check: '${files_line:--}' / '${tests_line:--}' FAIL=$n_fail -> $verdict"
}

measure_stage() {
  local stage="$1"
  echo ""
  echo " Stage: $stage - $(date '+%H:%M:%S')"

  local timing_dir
  timing_dir=$(mktemp -d)

  local stage_log="$LOGS_DIR/run_$(printf '%02d' "$RUN_NUM")_${stage}.log"
  local stage_exit=0
  local stage_timeout cname stage_start_utc
  case "$stage" in
    build) stage_timeout="$ENERGY_STAGE_TIMEOUT_BUILD_S" ;;
    *)     stage_timeout="$ENERGY_STAGE_TIMEOUT_TEST_S" ;;
  esac
  cname="svelte-5.55.0-run$(printf '%02d' "$RUN_NUM")-${stage}"
  # A residual container of the same name is exactly the case the ceiling exists for.
  docker rm -f "$cname" >/dev/null 2>&1 || true

  local cpuset_args=()
  if [ -n "$ENERGY_CPUSET" ]; then
    cpuset_args=(--cpuset-cpus="$ENERGY_CPUSET")
  fi
  # The build container is kept after it exits so its file system can be read
  # after the measured window closes; the test container is removed on exit.
  local rm_args=(--rm)
  if [ "$stage" = "build" ]; then
    rm_args=()
  fi

  local swap_in_ini swap_out_ini temp_ini
  swap_in_ini=$(read_swap pswpin); swap_out_ini=$(read_swap pswpout); temp_ini=$(read_temp_c)

  local ini_pkg ini_cores ini_gpu ini_ram
  ini_pkg=$(read_rapl pkg)
  ini_cores=$(read_rapl cores)
  ini_gpu=$(read_rapl gpu)
  ini_ram=$(read_rapl ram)

  CURRENT_CONTAINER="$cname"
  stage_start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  set +e
  # --network none: all inputs are pre-baked into the image; measured energy
  # must not include network traffic (construct definition).
  # fd3 preserves the workload stderr while `time` captures wall/user/sys inside
  # the container, so child CPU time is attributed to the stage.
  /usr/bin/time -f "%e" -o "$TIME_FILE" \
    timeout --foreground -s TERM -k 30 "$stage_timeout" \
    docker run "${rm_args[@]}" --name "$cname" --privileged --network none \
      --memory="$MEM_LIMIT" --memory-swap="$MEM_SWAP" \
      "${cpuset_args[@]}" \
      -v "$MEDICAO_DIR:/medicao:ro" \
      -v "$timing_dir:/timing" \
      -e "STAGE=$stage" \
      "$IMAGE_NAME" \
      bash -c 'exec 3>&2; TIMEFORMAT="%R %U %S"; { time bash /medicao/commands.sh "$STAGE" 2>&3; } 2>/timing/time.txt' \
      2>&1 | tee "$stage_log"
  stage_exit=${PIPESTATUS[0]}
  set -e

  local wall_now
  wall_now=$(tail -n 1 "$TIME_FILE" 2>/dev/null || echo 0)
  [[ "$wall_now" =~ ^[0-9]+(\.[0-9]+)?$ ]] || wall_now=0
  # 124: timeout sent TERM. 137 is also the workload's own SIGKILL exit, so it
  # only counts as the ceiling when the wall actually reached it.
  if [ "$stage_exit" -eq 124 ] || { [ "$stage_exit" -eq 137 ] && awk "BEGIN {exit !($wall_now >= $stage_timeout)}"; }; then
    rm -rf "$timing_dir"
    abort_stage_timeout "$stage" "$stage_timeout" "$stage_exit" "$cname" "$stage_start_utc" "$stage_log" "$wall_now"
  fi

  local fin_pkg fin_cores fin_gpu fin_ram
  fin_pkg=$(read_rapl pkg)
  fin_cores=$(read_rapl cores)
  fin_gpu=$(read_rapl gpu)
  fin_ram=$(read_rapl ram)

  local swap_in_fin swap_out_fin temp_fin
  swap_in_fin=$(read_swap pswpin); swap_out_fin=$(read_swap pswpout); temp_fin=$(read_temp_c)
  {
    echo "pswpin_start,$swap_in_ini"
    echo "pswpout_start,$swap_out_ini"
    echo "pswpin_end,$swap_in_fin"
    echo "pswpout_end,$swap_out_fin"
    echo "swap_in_pages,$(( swap_in_fin - swap_in_ini ))"
    echo "swap_out_pages,$(( swap_out_fin - swap_out_ini ))"
  } > "$RESULTS_DIR/swap_run_$(printf '%02d' "$RUN_NUM")_${stage}.txt"
  {
    echo "sensor,${TEMP_SENSOR:--}"
    echo "label,Package id 0"
    echo "temp_pkg_start_c,$temp_ini"
    echo "temp_pkg_end_c,$temp_fin"
  } > "$RESULTS_DIR/temp_run_$(printf '%02d' "$RUN_NUM")_${stage}.txt"
  echo "  stage log: $stage_log"

  # The exit code is the rejection criterion; the measurement is kept either
  # way. The conformity check below adds the second condition.
  echo "$RUN_NUM,$stage,$stage_exit" >> "$EXITS_FILE"
  if [ "$stage_exit" -ne 0 ]; then
    echo "  stage '$stage': container exited with exit=$stage_exit (measurement PRESERVED, see $EXITS_FILE)"
    PIPELINE_EXIT="$stage_exit"
    FAILED_STAGES="${FAILED_STAGES:+$FAILED_STAGES }$stage(exit=$stage_exit)"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "::warning title=Stage exited non-zero::Run $RUN_NUM, stage '$stage': exit=$stage_exit. The CSV row WAS written."
    fi
  else
    echo "  stage '$stage': container exited 0"
  fi
  if [ "$stage" = "build" ]; then
    check_build "$cname" "$stage_exit"
    docker rm -f "$cname" >/dev/null 2>&1 || true
  else
    check_test "$stage_log" "$stage_exit"
  fi
  CURRENT_CONTAINER=""

  local wall wall_container_t user_t sys_t
  # GNU time prepends a status line on non-zero exit; the elapsed value is last.
  wall=$(tail -n 1 "$TIME_FILE")
  if ! [[ "$wall" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "  non-numeric wall_time ('$wall') - writing 0 and continuing" >&2
    wall="0.00"
  fi
  if [ -f "$timing_dir/time.txt" ]; then
    read -r wall_container_t user_t sys_t < "$timing_dir/time.txt"
  else
    wall_container_t="0.000"; user_t="0.000"; sys_t="0.000"
  fi
  rm -rf "$timing_dir"

  local d_pkg d_cores d_gpu d_ram
  d_pkg=$(delta_uj   "$ini_pkg"   "$fin_pkg"   "$max_pkg")
  d_cores=$(delta_uj "$ini_cores" "$fin_cores" "$max_cores")
  d_gpu=$(delta_uj   "$ini_gpu"   "$fin_gpu"   "$max_gpu")
  d_ram=$(delta_uj   "$ini_ram"   "$fin_ram"   "$max_ram")

  local j_pkg j_cores j_gpu j_ram j_ram_raw
  j_pkg=$(awk   "BEGIN {v=($d_pkg   - $taxa_pkg   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_cores=$(awk "BEGIN {v=($d_cores - $taxa_cores * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_gpu=$(awk   "BEGIN {v=($d_gpu   - $taxa_gpu   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_ram=$(awk   "BEGIN {v=($d_ram   - $taxa_ram   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")

  j_ram_raw=$(awk "BEGIN {printf \"%.6f\", ($d_ram - $taxa_ram * $wall) / 1e6}")

  # Raw delta, baseline share, net and clamped value for every domain, so the
  # closing check does not depend on reconstructing them from the CSV.
  local dom d t j
  for dom in pkg cores gpu ram; do
    case "$dom" in
      pkg)   d="$d_pkg";   t="$taxa_pkg";   j="$j_pkg" ;;
      cores) d="$d_cores"; t="$taxa_cores"; j="$j_cores" ;;
      gpu)   d="$d_gpu";   t="$taxa_gpu";   j="$j_gpu" ;;
      ram)   d="$d_ram";   t="$taxa_ram";   j="$j_ram" ;;
    esac
    echo "  ${dom}: delta=${d}uJ baseline=$(awk "BEGIN {printf \"%.0f\", $t * $wall}")uJ net=$(awk "BEGIN {printf \"%.3f\", ($d - $t * $wall) / 1e6}")J clamped=${j}J"
  done

  echo "$RUN_NUM,$stage,$j_pkg,$j_cores,$j_gpu,$j_ram,$wall,$user_t,$sys_t,$j_ram_raw,$wall_container_t,$taxa_pkg_w,$taxa_cores_w,$taxa_ram_w" >> "$CSV_FILE"

  total_pkg=$(awk   "BEGIN {printf \"%.6f\", $total_pkg   + $j_pkg}")
  total_cores=$(awk "BEGIN {printf \"%.6f\", $total_cores + $j_cores}")
  total_gpu=$(awk   "BEGIN {printf \"%.6f\", $total_gpu   + $j_gpu}")
  total_ram=$(awk   "BEGIN {printf \"%.6f\", $total_ram   + $j_ram}")
  total_ram_raw=$(awk "BEGIN {printf \"%.6f\", $total_ram_raw + $j_ram_raw}")
  total_wall=$(awk  "BEGIN {printf \"%.3f\", $total_wall  + $wall}")
  total_user=$(awk  "BEGIN {printf \"%.3f\", $total_user  + $user_t}")
  total_sys=$(awk   "BEGIN {printf \"%.3f\", $total_sys   + $sys_t}")
  total_wall_container=$(awk "BEGIN {printf \"%.3f\", $total_wall_container + $wall_container_t}")

  echo "    pkg: ${j_pkg}J | cores: ${j_cores}J | ram: ${j_ram}J | wall: ${wall}s"
}

# Two stages from two jobs of the same workflow (D-1); the test does not use
# the build output, as in the Tests job, which builds nothing.
measure_stage build
measure_stage test

if [ -z "$NONCONFORM_STAGES" ]; then
  echo "verdict,conform" >> "$ARTIFACT_FILE"
else
  echo "verdict,nonconform" >> "$ARTIFACT_FILE"
  echo "::warning title=Artifact check failed::run $RUN_NUM, stage(s) $NONCONFORM_STAGES did not meet the pre-registered criterion; see $ARTIFACT_FILE. CSV rows kept, exit unchanged"
fi

echo "$RUN_NUM,total,$total_pkg,$total_cores,$total_gpu,$total_ram,$total_wall,$total_user,$total_sys,$total_ram_raw,$total_wall_container,$taxa_pkg_w,$taxa_cores_w,$taxa_ram_w" \
  >> "$CSV_FILE"

echo ""
echo ""
echo "Run $RUN_NUM finished - $(date '+%H:%M:%S')"
echo " CSV: $CSV_FILE"
echo " Total: pkg=${total_pkg}J | wall=${total_wall}s"
echo ""
echo ""

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<EOS

## Run $RUN_NUM - $PROJECT_NAME

| Stage | pkg (J) | cores (J) | gpu (J) | ram (J) | wall (s) | exit |
|-------|---------|-----------|---------|---------|----------|------|
$(grep "^$RUN_NUM," "$CSV_FILE" | awk -F',' -v ex="$EXITS_FILE" 'BEGIN { while ((getline l < ex) > 0) { split(l, a, ","); e[a[2]] = a[3] } } {printf "| %s | %s | %s | %s | %s | %s | %s |\n", $2,$3,$4,$5,$6,$7,($2 in e ? e[$2] : "-")}')
EOS
fi

rm -f "$TIME_FILE"

if [ "$PIPELINE_EXIT" -ne 0 ]; then
  echo "Run $RUN_NUM: stage(s) with non-zero exit  $FAILED_STAGES"
  echo "  CSV: $CSV_FILE  exit codes: $EXITS_FILE"
  exit "$PIPELINE_EXIT"
fi
