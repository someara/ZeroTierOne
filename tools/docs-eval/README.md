# Docs Eval

Small harness for testing whether models understand the repo docs.

Targets:

- Claude Code via `claude`
- OpenCode via `opencode`

Modes:

- Claude: routed-doc behavior through `CLAUDE.md`
- OpenCode: bundled-doc comprehension

Run from repo root:

```sh
./test_docs_claude.sh sonnet
./test_docs_claude.sh --timeout 60 haiku
./test_docs_opencode.sh github-copilot/gpt-5-mini
./test_docs_models.sh --timeout 60 --claude sonnet --opencode github-copilot/gpt-5-mini
```

Outputs go to `tools/docs-eval/out/`.

Each run writes:

- `*.json` - final model output
- `*.status` - `ok`, `timeout`, or `error`
- `*.stderr.txt` - stderr from the model CLI
- `*.partial.txt` - partial captured output if the run timed out or errored

The matrix runner also writes:

- `matrix-*.tsv` - machine-readable summary
- `matrix-*.txt` - human-readable summary

Note: a non-zero exit can mean either:

- the model timed out or errored, or
- the model answered, but failed the scorer
