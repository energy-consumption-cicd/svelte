#!/usr/bin/env bash

set -euo pipefail
# Numeric formatting in awk must not follow the locale of the invoking shell.
export LC_ALL=C

RUN_NUM="${1:?run number required (e.g. 1)}"
PROJECT_NAME="svelte"
IMAGE_NAME="${IMAGE_NAME:-svelte-medicao}"
MEDICAO_DIR="${MEDICAO_DIR:-$HOME/experimentos/medicao/repositorios/svelte}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/experimentos/medicao/resultados/svelte/runs}"
LOGS_DIR="${LOGS_DIR:-$HOME/experimentos/medicao/resultados/svelte/logs}"
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
# pre-registration from the rehearsal on the measurement bench: 1.52x the
# largest build wall (125.33 s) and 1.5x the largest test wall (102.63 s); the
# real cost is the ceiling plus the 30 s of -k. Non-default values are for
# declared diagnostic sessions only.
STAGE_TIMEOUT_BUILD_DEFAULT=190
STAGE_TIMEOUT_TEST_DEFAULT=155
ENERGY_STAGE_TIMEOUT_BUILD_S="${ENERGY_STAGE_TIMEOUT_BUILD_S:-$STAGE_TIMEOUT_BUILD_DEFAULT}"
ENERGY_STAGE_TIMEOUT_TEST_S="${ENERGY_STAGE_TIMEOUT_TEST_S:-$STAGE_TIMEOUT_TEST_DEFAULT}"
STAGE_TIMEOUT_EXIT=91
# Rehearsal only: pins the container to a CPU set to emulate the bench. Empty
# on the campaign, where no CPU limit is applied.
ENERGY_CPUSET="${ENERGY_CPUSET:-}"
TIME_FILE="/tmp/svelte_time_$$.txt"
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
0ba974cd0da1a95a6b60768576796b69d0f3e788a1c7484223c8454814749488 documentation/docs/07-misc/.generated/browser-support-features.md
b2a7c0c02920b61890dd6edcf734bca0e5cd0b05ff04b57daae280e01f18452b documentation/docs/07-misc/.generated/browser-support.md
84f2b9fd11a0e517d6b766f82988d7d272b4ea619f9b0f349071f063b17839af documentation/docs/98-reference/.generated/client-errors.md
50ed47a5e23d3b8e4df13f1ac37a82671fc59dd16e9ea11e4e6c5682464934fd documentation/docs/98-reference/.generated/client-warnings.md
85628546367fdaa775f3fa7145b1f6002074b45c8dd36729a3a47b2a138e7076 documentation/docs/98-reference/.generated/compile-errors.md
0be8065b2bc1230394b72c138b5115a79642c21d06100e82a3b9083a6198a002 documentation/docs/98-reference/.generated/compile-warnings.md
4d12f4023be4215474fab5fdfb60e211a1f085f16ab28ca461a89399f5e9f82a documentation/docs/98-reference/.generated/server-errors.md
cbeb399c42bbeff71b5216acbaa04465846dac74fbc4b2888a55758712522afa documentation/docs/98-reference/.generated/server-warnings.md
2ff348a214a05d30a45649b15db7403092685f1a83399472869d9fcbab2ea00f documentation/docs/98-reference/.generated/shared-errors.md
c13248e3d69424a36f3e59022dc8c4f8ea1ef89801b75b0bc1d1bf29f5811e48 documentation/docs/98-reference/.generated/shared-warnings.md
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/action.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/animate.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/compiler.d.ts
14ff0c11c68bd0bb001f3d5e0b7b9fd4e910b8750445069903c83c83bb86cde7 packages/svelte/compiler/index.js
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/easing.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/index.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/legacy.d.ts
28014e85fc1dffb60defa38ee9d58c3536e8c1a0bb7defa27bc9ff9da86f8853 packages/svelte/messages/client-errors/errors.md
79afd28c2c0aab13f06f2d9b76851eedefebf1097d24c41ece570b3a3b1177d2 packages/svelte/messages/client-warnings/warnings.md
fe158cbbe01f9e552e9aae54d83a6c0f22313bd4fc8e4d81f7d60077a23c054b packages/svelte/messages/compile-errors/options.md
17731f33189d32045759646d6fe98747ff90be8526cf957907634b24000ae945 packages/svelte/messages/compile-errors/script.md
76f40e6669f7f6c1c97c9f2122415a96044a45987b29b8eb2240cb110ce34f17 packages/svelte/messages/compile-errors/style.md
71d20cbad1ad0b53acc22a366f9fdc58083299e4ac3fe89ae45e14988e86a4cd packages/svelte/messages/compile-errors/template.md
d3d92bd2d62c21d0167ca35c1caf7376e9d3e3f3dd6c3097a7101ecfdbbe2fe7 packages/svelte/messages/compile-warnings/a11y.md
53ea3262a4297f69155c2a51af6ffc8f54784e9604976827186c837f6bec2534 packages/svelte/messages/compile-warnings/misc.md
c57f6995999d93ab6567d8e444e7e78e840b0cf686adb8e2329fbb8d23342964 packages/svelte/messages/compile-warnings/options.md
4d915c45fbe84d77082f957fbc688310cefb735d92f94dc1ee1cb56a1dc61bd3 packages/svelte/messages/compile-warnings/script.md
62774d11eed09a5ee5bfb6c35341af3485aac144cd79b69b6e11aea8662f7d9f packages/svelte/messages/compile-warnings/style.md
96a22f63b59479fd0af0b679503ac836b29545625953efe4c211000a24d113d7 packages/svelte/messages/compile-warnings/template.md
0c540e23389e78c6282c82a0413c165dfd7b9dc820699cf3b43962aebbdb73d4 packages/svelte/messages/server-errors/errors.md
166e371ff5719cfc4e0049a01f4db28a4f3658f3a4b3787496ced89e249cfed1 packages/svelte/messages/server-warnings/warnings.md
33a641e774f31f28461da2b3ee4ab8e0cd3a1491018c802c8cd753196edc04dc packages/svelte/messages/shared-errors/errors.md
12757b112f92aff6a73d1860179aafa2d020d57c80fbc73ebc7a1ca1f5c2409c packages/svelte/messages/shared-warnings/warnings.md
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/motion.d.ts
587812e92e3354763c39f4f3b424c0df1789cfd4b85ed36b00af5a833e57c86c packages/svelte/src/compiler/errors.js
00a90bab0bba571cebf88b787ac59bf16f6176560af305f637219f8351bc4313 packages/svelte/src/compiler/warnings.js
0a920b99eb2486ac40eeb8788a3920f0640afb039220674c36ed40a2d09b56a2 packages/svelte/src/internal/client/errors.js
9c7221cdd177a1faaad1f772cf66717cfd30c83490fda2491b806e7779c2a7ca packages/svelte/src/internal/client/warnings.js
fc45a794d422f2b987dc3081660a153c2efa3095098a5d5404aee1589dbafcd2 packages/svelte/src/internal/server/errors.js
030daa03dfbf35f12cb179532d323ebb12ca8b855e0fba0d293f9d284016a336 packages/svelte/src/internal/server/warnings.js
5c8c8697675b634e9b5f525e4ab49b69b315a413904673adbb853a2ce6a84dc0 packages/svelte/src/internal/shared/errors.js
af3fb78d28b5aa427d738ccc513559de7699d2be11e3ffb2ed98e250173ce940 packages/svelte/src/internal/shared/warnings.js
cfa63f38ff0bb2180fc971f937b003804efb735982ef74d1d40caa381bcac241 packages/svelte/src/version.js
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/store.d.ts
31181cc10bdc79c0e0a9a618de33d3e59f2626ed3f30a60537023906373802c5 packages/svelte/transition.d.ts
e873776e929f9ceecb85f4f3fabefa870a9b954f08300c4acb61d12f8b8b67ac packages/svelte/types/compiler/interfaces.d.ts
e873776e929f9ceecb85f4f3fabefa870a9b954f08300c4acb61d12f8b8b67ac packages/svelte/types/compiler/preprocess.d.ts
1083ec857d6ba96f07c20efb6832cc7b7089f49b8d0eb956b845ebdc3a093d48 packages/svelte/types/index.d.ts
3dac47bc7fce272236fee91f0844a237164064c1587d93546684468ea7b6114d packages/svelte/types/index.d.ts.map
EOM
)
BUILD_MANIFEST_N=$(printf '%s\n' "$BUILD_MANIFEST" | grep -c .)
TEST_FILES_EXPECTED="Test Files 34 passed (34)"
TEST_TESTS_EXPECTED="Tests 7782 passed | 55 skipped (7837)"

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
  cname="svelte-run$(printf '%02d' "$RUN_NUM")-${stage}"
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
