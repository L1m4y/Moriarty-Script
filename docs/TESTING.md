# Testing

```bash
make check       # syntax + shellcheck + shfmt
make test        # tests/run.sh
```

`tests/run.sh` validates CLI options and manifest validation. Root-only checks
create synthetic v2 manifests and verify checksum, path, ownership, mode, and
symlink rejection.

CI uses an Arch Linux container to install `shellcheck` and `shfmt`, then runs
`make check` and `tests/run.sh`.
