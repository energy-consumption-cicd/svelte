# Energy measurement

Instrumentation for measuring the energy consumed by this project's CI cell. It
adds five files and modifies none of the upstream tree (`git diff` against
`sveltejs/svelte` at the tag `svelte@5.56.0`, `70afafe18e48a9973c5f711d62d87d088234655e` shows only them).
That commit is the measured one: the image clones it, whatever the tip of this
branch. This repository is a private copy of the upstream, one branch per measured
release, and the instrumentation of the HEAD campaign (fork `energy-consumption-cicd/svelte`,
`132f97b`) is reused with the values this tag requires.

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
other four `Tests` entries are outside the cell. The monorepo has one package,
`packages/svelte`, and both stages work on it.

## Stages

| stage | command | source |
|---|---|---|
| `build` | `pnpm build` | `Lint` job, step `build and check generated types` |
| `test` | `pnpm test` | `Tests` job, step `pnpm test` |

Every command in `commands.sh` is literal. The differences against the jobs,
and no others (numbered as in the pre-registration; D-6, D-9 and D-10 are
not differences):

| # | difference | why |
|---|---|---|
| D-1 | two stages taken from two jobs, run in sequence | the test job does not build, and the test does not depend on the build |
| D-2 | the build is the one of the dedicated step, from a tree with no build output; the build `pnpm check` runs before it in `Lint`, and the step's `git status` check, are outside the measured window | the first build is an effect of the step order of `Lint`; the check reads the result, and is replaced by the manifest below |
| D-3 | Node 24.16.0 from the official tarball (the latest 24.x on the date of the reference run), pnpm 10.4.0 through corepack, Playwright 1.60.0 with Chromium and Chrome Headless Shell revision 1223 and FFmpeg 1011 and the system libraries Chromium needs, all baked into the image | the hosted runner provides the libraries and the jobs download the rest; the stages run with `--network none` |
| D-4 | `CI=true` and `GITHUB_ACTIONS=true` in both stages | the runner defines both; `CI` also enables one retry of the browser tests, and `GITHUB_ACTIONS` selects the minimal reporter |
| D-5 | no CPU limit on `docker run`; vitest starts 7 workers instead of the runner's 3 | bench decision, recorded as a validity threat |
| D-7 | user `runner` (uid 1000) | the hosted runner is unprivileged |
| D-8 | a run is conforming when both stages exit 0, the build writes exactly the 49 files of the manifest in `run_pipeline.sh` with their sha256, and the test summary reads `Test Files 33 passed (33)` and `Tests 7613 passed \| 63 skipped (7676)` with no `FAIL` line; checked after the measurement and recorded in `artifact_check_run_NN.txt`, and a non-conforming run is substituted | the manifest covers the job's `git status` check, since the tracked outputs equal the reference commit; the build container is read after it exits, outside the measured window |

## Running

```
docker build -t svelte-measurement-5.56.0 -f energy-measurement/Dockerfile energy-measurement
gh workflow run energy-measurement.yml -f campaign=validation
gh workflow run energy-measurement.yml -f campaign=full
```

`validation` runs run 0 only. `full` runs a discarded warm-up plus runs 1..10 and
writes the medians. Each run rests 120 s to measure the idle baseline; an idle
package rate above 1.0 W aborts the run before the first stage (exit 90), since
the bench is then not idle. A stage that exceeds its ceiling (191 s for
`build`, 135 s for `test`) is killed (exit 91) and the run is substituted, at
most twice per campaign. `--network none`, `--privileged`, `--memory=12g` and
`--memory-swap=12g` on every measured container.

## Sidecars outside the measured window

`swap_run_NN_<stage>.txt` records `pswpin` and `pswpout` of `/proc/vmstat`, and
`temp_run_NN_<stage>.txt` the package temperature (hwmon `coretemp`, sensor
`Package id 0`), both read immediately before and after each stage's RAPL
window. Neither enters the run CSV.

## Exit codes

The pre-registered exit of both stages is 0, and the pipeline exit is 0. No
test is expected to fail under `--network none`: the browser tests load their
pages with `page.setContent` and start no server, and no test reads the
container hostname.

The pre-registration and its dated amendments are kept in a private repository,
available on request.
