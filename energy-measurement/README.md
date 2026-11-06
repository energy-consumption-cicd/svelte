# Energy measurement

Instrumentation for measuring the energy consumed by this project's CI cell at
release `svelte@5.53.0` (`c2fc95a4674f2db34fd71de70f088810bf2204b4`). It adds five
files and modifies none of the upstream tree (`git diff` against `sveltejs/svelte`
at that tag shows only them). That commit is the measured one: the image clones
it, whatever the tip of this branch. Branch `release-5.53.0` is the tag plus these
files; the HEAD campaign of the study lives on `main`.

```
.github/workflows/energy-measurement.yml
energy-measurement/
├── README.md
├── Dockerfile
├── run_pipeline.sh
└── commands.sh
```

## Measured cell

`.github/workflows/ci.yml` runs on every push to `main`. Its `Tests` job has no
build step: `vitest` runs over the package sources and compiles each test sample
itself. The package build runs in the `Lint` job of the same workflow, and no
test consumes its output. The measured cell takes one step from each job, both
on `ubuntu-latest` and Node 24: the build of `Lint` and the test step of the
`Tests` matrix entry `{node-version: 24, os: ubuntu-latest}`. `TSGo`,
`TestNoAsync`, `Benchmarks`, the type check and lint steps of `Lint`, and the
other five `Tests` entries are outside the cell. The monorepo has one package,
`packages/svelte`, and both stages work on it.

## Stages

| stage | command | source |
|---|---|---|
| `build` | `pnpm build` | `Lint` job, step `build and check generated types` |
| `test` | `pnpm test` | `Tests` job, step `pnpm test` |

Every command in `commands.sh` is literal. At this tag `pnpm build` runs
`process-messages`, `rollup -c`, `generate:types` (with `tsc`) and the
treeshakeability check. The differences against the jobs, and no others:

| # | difference | why |
|---|---|---|
| D-1 | two stages taken from two jobs, run in sequence | the test job does not build, and the test does not depend on the build |
| D-2 | the build is the one of the dedicated step, from a tree with no build output; the `pnpm check` that runs before it in `Lint`, and the step's `git status` check, are outside the measured window | the first build is an effect of the step order of `Lint`; the check reads the result, and is replaced by the manifest below |
| D-3 | Node 24.13.1 from the official tarball (the latest 24.x on the date of the tag's reference run), pnpm 10.4.0 through corepack, Playwright 1.58.0 with Chromium and the system libraries Chromium needs, all baked into the image | the hosted runner provides the libraries and the jobs download the rest; the stages run with `--network none` |
| D-4 | `CI=true` and `GITHUB_ACTIONS=true` in both stages | the runner defines both; `CI` also enables one retry of the browser tests |
| D-5 | no CPU limit on `docker run`; vitest starts 7 workers instead of the runner's 3 | the container sees the 8 cores of the bench and vitest sizes its pool from them |
| D-7 | user `runner` (uid 1000) | the hosted runner is unprivileged |
| D-8 | a run is conforming when both stages exit 0, the build writes exactly the 47 files of the manifest in `run_pipeline.sh` with their sha256, and the test summary reads `Test Files 31 passed (31)` and `Tests 7273 passed \| 60 skipped (7333)` with no `FAIL` line; checked after the measurement and recorded in `artifact_check_run_NN.txt`, and a non-conforming run is substituted | the manifest covers the job's `git status` check, since the tracked outputs equal the reference commit; the build container is read after it exits, outside the measured window |

## Running

```
docker build -t svelte-measurement-5.53.0 -f energy-measurement/Dockerfile energy-measurement
gh workflow run energy-measurement.yml -f campaign=validation
gh workflow run energy-measurement.yml -f campaign=full
```

`validation` runs run 0 only. `full` runs a discarded warm-up plus runs 1..10 and
writes the medians. Each run rests 120 s to measure the idle baseline; an idle
package rate above 1.0 W aborts the run before the first stage (exit 90), since
the bench is then not idle. A stage that exceeds its ceiling (190 s for
`build`, 158 s for `test`) is killed (exit 91) and the run is substituted, at
most twice per campaign. `--network none`, `--privileged`, `--memory=12g` and
`--memory-swap=12g` on every measured container.

## Sidecars outside the measured window

`swap_run_NN_<stage>.txt` records `pswpin` and `pswpout` of `/proc/vmstat`, and
`temp_run_NN_<stage>.txt` the package temperature (hwmon `coretemp`, sensor
`Package id 0`), both read immediately before and after each stage's RAPL
window. Neither enters the run CSV.

## Exit codes

The expected exit of both stages is 0, and the pipeline exit is 0. No test is
expected to fail under `--network none`: the browser tests load their pages with
`page.setContent` and start no server, and no test reads the container hostname.
