# lask-terraform Design Document

`lask-terraform` is a Lask module that wraps the Terraform CLI so that Lask tasks
(CI/CD pipelines, operational automation) can drive `init` / `plan` / `apply` /
`destroy` and read outputs with typed, composable functions.

This document defines the goals, public API, internal structure, and the design
decisions that follow from the Lask language specification
(`lask/doc/spec.md`; section numbers below refer to it).

## 1. Goals

- Provide the standard Terraform lifecycle (`init`, `validate`, `plan`, `apply`,
  `destroy`, `output`, workspaces) as Lask functions with sensible defaults.
- Always non-interactive: every wrapped command runs with `-input=false` and
  `-no-color`; nothing ever blocks on a prompt.
- Preserve Terraform's exit-code semantics through Lask's error contract
  (spec 6.9, 8.10): a failed Terraform run becomes an `Error` whose `code` is
  Terraform's exit code and whose `message` is Terraform's stderr, so it can be
  caught with `try`/`catch` or propagated to the process exit code unchanged.
- Make `plan -detailed-exitcode` a first-class typed result (`changed: Bool`)
  instead of an error.
- Work in any Lask execution environment (`#local`, `#docker(...)`,
  `#env(...)`; spec ch. 10) via a pass-through `--env` keyword parameter.
- Support OpenTofu by parameterizing the binary name (`--bin = "tofu"`).

## 2. Non-Goals

- No management of Terraform binary installation (use the target environment's
  image/host provisioning for that).
- No HCL generation or templating.
- No parsing of the full plan/state JSON schema into rich record types in v1
  (`show_json` returns `Any`; a typed diff summary is future work, §10).
- No secret management. Secrets must come from the target environment's ambient
  variables (`TF_VAR_*`, provider credentials); see §8 for why the module must
  not carry secrets through its arguments.

## 3. Distribution and Consumption

The module is published as a git tree dependency (spec ch. 5, 11.5) with the
public API at `main.lask` (the bare-name entry-point convention).

Consumer setup:

```text
lask deps add terraform --git https://github.com/lask-task-runner/lask-terraform --rev v0.1.0
```

```lask
import * as tf from "terraform"        // functions
import { TfPlan } from "terraform"     // types need named imports (spec ch. 5)

deploy(): String = do {
  tf.init(dir = "infra")
  tf.apply(dir = "infra", vars = {app_version: "1.2.3"})
}
```

Design notes:

- **Namespace import is the recommended style.** Several function names
  (`init`, `plan`, `apply`, `output_value`, ...) are generic and would pollute
  the consumer's scope under named import. Types (`TfPlan`, ...) can only be
  brought in by named import (spec ch. 5), so both import forms appear together.
- **All public functions live directly in `main.lask`, not re-exported.**
  Lask has no re-export: binding `plan = impl.plan` would turn `plan` into a
  function *value*, and calls through function values cannot use keyword
  arguments (spec 6.1, 7.5) — every `--dir`/`--vars` option would silently be
  replaced by its default. Declaring the real functions in `main.lask` keeps
  keyword arguments working. Internal helpers live in `lib/` and are imported
  by `main.lask`; imports are not public symbols, so they do not leak.

## 4. Public API

### 4.1 Common keyword parameters

Every command function takes these keyword parameters (defaults shown):

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `--dir` | `String` | `"."` | Terraform root module directory, passed as `-chdir=<dir>`. Relative to the environment's cwd (spec 10.5); for `#local` the current implementation uses the executed module's base directory, so consumer defaults should be module-relative. |
| `--env` | `Environment` | `#docker("alpine/terragrunt:1.5.7")` | Execution environment for the command (spec ch. 10). |
| `--bin` | `String` | `"terraform"` | CLI binary; set `"tofu"` for OpenTofu. |

Making `env` a keyword parameter (never positional) matters for two reasons:

- Functions with **positional** `Environment` parameters cannot be invoked from
  the CLI at all (spec 11.2). As keyword parameters they are completed with the
  Docker default above, so thin consumer wrappers stay CLI-invocable.
- `lask envs <fn> --check` (spec 11.4) over-approximates environments reachable
  through function values, so pass-through `env` still gets enumerated.

### 4.2 Types

```lask
type TfPlan        = Record<changed: Bool, log: String>
type TfOutputs     = Map<Any>
type TfOutputEntry = Record<sensitive: Bool, "type": Any, value: Any>
```

- `TfPlan.changed` reflects `-detailed-exitcode` (0 → `false`, 2 → `true`);
  `log` is the human-readable plan text (stdout).
- `TfOutputEntry` mirrors one entry of `terraform output -json`. The field
  `type` collides with a Lask reserved word, so it is declared in string-literal
  form and accessed as `entry["type"]` (spec 4.2, 6.8).

### 4.3 Functions

Common parameters (`--dir`, `--env`, `--bin`) are elided below.

```lask
version(): String
// `<bin> version`; stdout as-is.

init(--upgrade: Bool = false,
     --reconfigure: Bool = false,
     --backend_configs: Array<String> = []): String
// `init -input=false -no-color [-upgrade] [-reconfigure] [-backend-config=<v>]...`

validate(): String
// `validate -no-color`; stdout on success, Error(code, stderr) on failure.

fmt(): String
// `fmt -recursive`; rewrites files, returns the list of changed files (stdout).

fmt_check(): Bool
// `fmt -check -recursive` via `$*`; exit 0 → true, exit 3 → false, else fail.

plan(--vars: Map<Any> = {},
     --var_files: Array<String> = [],
     --targets: Array<String> = [],
     --destroy: Bool = false,
     --out: String = ""): TfPlan
// `plan -input=false -no-color -detailed-exitcode [-destroy] [-out=<f>]
//       [-var-file=<f>]... [-target=<t>]... [generated -var-file]`
// exit 0 → {changed: false, ...}; exit 2 → {changed: true, ...};
// anything else → fail(error(code, stderr)).

apply(--vars: Map<Any> = {},
      --var_files: Array<String> = [],
      --targets: Array<String> = [],
      --plan_file: String = ""): String
// plan_file == "": `apply -input=false -no-color -auto-approve <var/target args>`
// plan_file != "": `apply -input=false -no-color <plan_file>`
//   (vars/var_files/targets are rejected with a usage Error in this mode,
//    matching Terraform's own restriction on saved plans).

destroy(--vars: Map<Any> = {},
        --var_files: Array<String> = [],
        --targets: Array<String> = [],
        --auto_approve: Bool = false): String
// Guard: fails with error(2, "destroy requires auto_approve = true") unless
// explicitly opted in; then `destroy -input=false -no-color -auto-approve ...`.

outputs(): TfOutputs
// `output -json` |> from_json |> cast to Map<Any>.

decode_outputs(raw: String): TfOutputs
output_entry(os: TfOutputs, name: String): TfOutputEntry
// Cast helpers. They are public by necessity: `cast` needs an expected type,
// BindStmt has no type annotation (spec 6.5), and main.lask cannot hide
// top-level declarations — so the typed positions are function signatures.

output_value(name: String): Any
// outputs()[name].value, with a has_key pre-check for a diagnosable
// error(3, "no such output: <name>") instead of a bare E-RUNTIME-ACCESS.

show_json(--plan_file: String = ""): Any
// `show -json [<plan_file>]` |> from_json. State when plan_file omitted.

state_list(): Array<String>
// `state list` stdout split into non-empty lines.

workspace_show(): String
workspace_select(name: String, --create: Bool = false): String
// -or-create when create = true (Terraform >= 1.4 / OpenTofu).
```

Naming follows Lask snake_case, so the CLI kebab-case mapping (spec 11.2) works
for consumer wrappers (`lask run infra-plan`, etc.).

## 5. Variable Passing (`--vars`)

`-var 'key=value'` on the command line is rejected as the primary mechanism:
values containing quotes/newlines break shell quoting inside a Lask command
string (spec 6.6), and the full values would be embedded in the logged command
line.

Instead, when `vars != {}` the module:

1. Serializes `vars` with `to_json` (JSON is what `*.tfvars.json` expects, and
   `Map<Any>` values are exactly the directly-serializable types, spec 4.5).
2. Writes it to a fixed, documented path inside the root module directory:
   `<dir>/lask-terraform.generated.tfvars.json`, using
   `printf '%s' '<escaped-json>' > <path>` in the **same** `env` (the file must
   exist where Terraform runs — local, container, or remote host). Single
   quotes in the payload are escaped as `'\''`.
3. Appends `-var-file=lask-terraform.generated.tfvars.json` **after** all user
   `--var_files`, so `--vars` wins over file-supplied values (Terraform's
   last-one-wins rule) — an explicit, documented precedence.
4. Deletes the file in a `finally` block (`rm -f`, unconditional, via `$*` so
   cleanup never masks the primary failure).

An explicit `-var-file` (not an `*.auto.tfvars.json`) is used so behavior does
not depend on auto-loading rules and stray files never silently affect later
manual runs.

Known limitations (documented in the README):

- The generated file has a fixed name, so two concurrent `plan`/`apply` calls
  **with `vars`** against the same `dir` race on it. (Lask provides no
  randomness/timestamps to generate unique names; Terraform's state lock
  already serializes `apply`.) Concurrent runs without `vars` are unaffected.
- If the process is killed between write and cleanup, a stale file may remain;
  it is ignored by Terraform unless `--vars` is used again (which overwrites it).

## 6. Error Mapping

| Situation | Behavior |
|---|---|
| Command exits 0 | Success; stdout (or typed record) returned. |
| `plan`/`fmt_check` detailed exit codes (2 / 3) | Mapped to data (`changed` / `Bool`), not errors — these are results, not failures. |
| Any other non-zero exit | `fail(error(code, stderr))` (for `$*`-based calls) or the equivalent built-in failure of `$` (spec 6.6). Uncaught, the Terraform exit code becomes the `lask` process exit code (spec 11.3) — CI semantics are preserved for free. |
| Misuse (e.g. `apply(plan_file=..., vars=...)`, `destroy` without opt-in) | `fail(error(2, <message>))` before running anything. |
| Missing output name | `fail(error(3, "no such output: <name>"))` after `has_key` check. |
| Environment resolution / SSH / Docker daemon failures | Left to the runtime (`E-IO-ENV-RESOLVE` etc., spec 10.4, ch. 14); the module adds nothing. |

Guards use the early-return form so the happy path stays flat (spec 6.5):

```lask
plan(...): TfPlan = do {
  vf = tfvars_arg(dir, env, vars)
  r = try {
    $*[env] #{bin} -chdir=#{dir} plan -input=false -no-color -detailed-exitcode #{args(...)} #{vf}
  } finally {
    cleanup_tfvars(dir, env)
  }
  if (r.code == 0) { return {changed: false, log: r.stdout} }
  if (r.code == 2) { return {changed: true, log: r.stdout} }
  fail(error(r.code, r.stderr))
}
```

## 7. Internal Structure

```text
lask-terraform/
  LICENSE
  README.md                 # usage, precedence rules, limitations, security notes
  main.lask                 # entire public API (types + functions)
  lib/
    args.lask               # pure arg-string builders
    tfvars.lask             # generated tfvars write/cleanup (effectful)
  example/
    main.lask               # consumer-shaped tasks: plan/deploy/teardown
    infra/main.tf           # fixture using terraform_data (builtin provider,
                            #   works offline after `terraform init`)
  test/
    selftest.lask           # `lask run --module test/selftest.lask all`
    fixture/main.tf
```

`lib/args.lask` (internal, pure):

```lask
flag(cond: Bool, s: String): String            // "" or s
opt(name: String, value: String): String       // "" or "-<name>=<value>"
prefix_each(xs: Array<String>, p: String): Array<String>   // ["-target=a", ...]
join_args(parts: Array<String>): String        // join(filter(_, != ""), " ")
count(xs: Array<String>): Number               // reduce-based (no array length builtin)
```

`lib/tfvars.lask` (internal, effectful):

```lask
tfvars_file: String                             // "lask-terraform.generated.tfvars.json"
tfvars_arg(dir: String, env: Environment, vars: Map<Any>): String
cleanup_tfvars(dir: String, env: Environment, vf: String): String
// no-op when vf == ""; rm -f via $* so cleanup never masks the primary failure
```

Constraint note: helpers stay **monomorphic** — user code cannot declare type
variables (spec 4.4), so a generic `with_tfvars(body: Function<..., T>)` bracket
is impossible. Each command function therefore does its own `try/finally`
around the generated var-file; the pattern is three lines and appears in only
four functions (`plan`, `apply`, `destroy`, and nothing else touches vars).

## 8. Security and Observability Notes

- **Do not pass secrets through `--vars`.** Two unavoidable leaks exist at the
  language level: (1) the `printf` command line that writes the generated
  tfvars file is subject to command-execution logging (spec 12.1, 12.3), and
  (2) Lask relays child stdout to stderr logs in real time (spec 9.1), so
  `output -json` — which includes `sensitive` values in plaintext — appears in
  logs. The README must state: supply secrets as ambient `TF_VAR_*`/provider
  environment variables of the target environment (spec 10.6), and treat
  `outputs()`/`output_value` on sensitive outputs as log-visible.
- The module never stores credentials; `environments.lask.json` rules
  (spec 10.3) and SSH settings (spec 10.9, 11.1) apply unchanged.
- `destroy` requires an explicit `auto_approve = true`; the default fails fast.
- Everything else is inherited: command start/exit/output events give full
  audit visibility of every Terraform invocation with zero module code.

## 9. Compatibility

- Terraform >= 1.0 (for `-chdir`); `workspace select -or-create` needs >= 1.4
  and is only emitted when `create = true`.
- OpenTofu: fully supported via `--bin = "tofu"`; no other differences in the
  wrapped surface.
- Docker environments must use an image containing the Terraform binary and
  must have the project tree visible at the container cwd (mount semantics are
  implementation-defined, spec 10.5); `remote` requires the binary and the
  checked-out tree on the host. The module only forwards `env`.

## 10. Testing Plan

- **Fixture**: `terraform_data`-only configuration (builtin provider — `init`
  needs no registry access), with variables and outputs exercising `--vars`
  precedence, `plan.changed` in both directions, `outputs`/`output_value`
  (including a `sensitive = true` output), and `destroy` guard behavior.
- **Selftest**: `test/selftest.lask` runs the full lifecycle against the
  fixture under the default Docker environment and asserts with `fail` on
  mismatch; runnable in CI as
  `lask run --module test/selftest.lask all` (exit code carries the result).
- **Static gate**: `lask check --module main.lask` and `lask check` on
  `example/` as the cheapest CI step.

## 11. Future Work

- Typed plan summary: `plan_summary(show_json(...))` returning
  `Record<add: Number, change: Number, destroy_: Number>` parsed from
  `resource_changes` (field name `destroy` needs care only as a *parameter*
  name; as a record field it is fine — to be verified).
- `import_resource`, `taint`/`untaint`, `force-unlock`, `providers lock`.
- `--lock_timeout`, `--parallelism` pass-through options.
- Per-call unique tfvars filenames if the language ever exposes randomness or
  process ids.
- A `backend_configs`-style structured `Map<String>` form once real usage shows
  which backend types dominate.
