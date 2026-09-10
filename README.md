# lask-terraform

A [Lask](../lask) module that wraps the Terraform / OpenTofu CLI so Lask tasks
can drive `init` / `plan` / `apply` / `destroy` and read outputs as typed,
composable functions. Design rationale lives in [doc/design.md](doc/design.md).

## Quick start

Dependency names must be lower_id identifiers (no `-`), so pick e.g. `terraform`:

```text
lask deps add terraform --git https://github.com/lask-task-runner/lask-terraform --rev v0.1.0
```

```lask
import * as tf from "terraform"

deploy(--version: String = "1.2.3"): String = do {
  tf.init(dir = "infra")
  tf.apply(dir = "infra", vars = {app_version: version})
}
```

```text
lask run deploy --version 1.2.4
```

## API

Every command function takes these keyword parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `--dir` | `"."` | Terraform root module directory (passed as `-chdir`) |
| `--env` | `#docker("hashicorp/terraform:1.16.2")` | Lask execution environment: `#docker(...)` or `#local` (the only two kinds Lask supports) |
| `--bin` | `"terraform"` | CLI binary; use `"tofu"` for OpenTofu |

All commands run with `-input=false` and `-no-color`; nothing ever prompts.

| Function | Returns | Notes |
|---|---|---|
| `version()` | `String` | |
| `init(--upgrade, --reconfigure, --backend_configs)` | `String` | |
| `validate()` | `String` | |
| `fmt()` | `String` | rewrites files, lists changed ones |
| `fmt_check()` | `Bool` | true = already canonical |
| `plan(--vars, --var_files, --targets, --destroy, --out)` | `TfPlan` | `-detailed-exitcode`; `changed: Bool` |
| `apply(--vars, --var_files, --targets, --plan_file)` | `String` | auto-approve; saved-plan mode rejects vars/targets |
| `destroy(--vars, --var_files, --targets, --auto_approve)` | `String` | fails unless `auto_approve = true` |
| `outputs()` | `TfOutputs` | `Map` of name → `{value, type, sensitive}` |
| `output_entry(os, name)` | `TfOutputEntry` | typed view of one entry |
| `output_value(name)` | `Any` | value only; diagnosable error for unknown names |
| `show_json(--plan_file)` | `Any` | parsed state / saved-plan JSON |
| `state_list()` | `Array<String>` | resource addresses |
| `workspace_show()` / `workspace_select(name, --create)` | `String` | `-or-create` needs Terraform >= 1.4 |

Types (named imports): `TfPlan`, `TfOutputs`, `TfOutputEntry`. The output entry
field `type` collides with a Lask reserved word — access it as `entry["type"]`.

## Variables (`--vars`)

`--vars: Map<Any>` is serialized with `to_json` and written to
`<dir>/lask-terraform.generated.tfvars.json` inside the target environment,
referenced via an explicit `-var-file` appended **after** all `--var_files`
(so `--vars` wins), and deleted in a `finally` block.

Limitations:

- The generated file name is fixed and reserved. Two concurrent `plan`/`apply`
  calls **with `vars`** against the same `dir` race on it.
- A crash between write and cleanup can leave the file behind; it only matters
  if you reuse the reserved name yourself.

## Security

**Do not pass secrets through `--vars` or read them via `outputs()`.**
Lask logs every executed command line and relays child output to stderr, so
both the generated-tfvars write and `output -json` (which prints `sensitive`
values in plaintext) are visible in logs. Supply secrets as ambient
`TF_VAR_*` / provider environment variables of the target environment instead.

`destroy` refuses to run without an explicit `auto_approve = true`.

## Environments

By default, commands run in `#docker("hashicorp/terraform:1.16.2")`.

`--env` is forwarded as-is, so you can override with `#local` or another
`#docker(...)` image — `local` and `docker` are the only two execution
environment kinds Lask supports. For `#docker(...)` the image must contain
the selected CLI binary (`terraform` / `tofu`) and the project tree must be
visible at the container cwd; for `#local` the binary must be on the host
running Lask.

## Development

- Static check: `lask check --module main.lask`
- Self-test (needs Docker and internet access for first image pull):
  `lask run --module test/selftest.lask all`
- Example tasks: `lask run --module example/main.lask deploy --version 1.2.3`

## Compatibility

Terraform >= 1.0 (`-chdir`); `workspace_select(create = true)` needs >= 1.4.
OpenTofu is supported via `--bin = "tofu"`.
