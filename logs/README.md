# Local logs

Build, codegen, runtime, GDB and bounded boot logs are written here.
Generated diagnostics and frame captures are intentionally ignored by Git.

Useful commands:

```bash
./test-boot.sh
./run.sh --debug
./gdb.sh
```

When sharing a bug report, include only the smallest relevant sanitized log.
Do not commit extracted game data or large local captures.
