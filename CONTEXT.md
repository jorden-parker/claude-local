# claude-local

Configuration for running Claude Code against a locally hosted open-weight model on a work MacBook Pro (M4, 48 GB).

## Glossary

- **Local model**: the open-weight model served on the laptop instead of Anthropic's API. Currently Qwen3.8-27B.
- **Runtime**: the program that loads the local model and serves it over an Anthropic-compatible HTTP API. Currently Rapid-MLX.
- **Launcher**: the single command a person runs to start the runtime if needed and open Claude Code pointed at it.
- **Profile**: the chosen combination of model, quantisation, reasoning level, and context length that the launcher applies.
- **MTP (multi-token prediction)**: the model's built-in draft head that lets the runtime guess several tokens per step. The main speed lever on Apple Silicon.
- **Dashboard**: a local web page, for the person at the laptop only, that shows the runtime's state and can start or stop the runtime and change the profile.
- **Profile file**: the single place the chosen profile is stored, read by both the launcher and the dashboard. Environment variables still override it for one run.
- **Prefill**: the runtime reading the whole prompt before it writes the first token. On a cache miss this dominates the wait for long Claude Code prompts.
- **Cache hit**: the runtime reused an already-prefilled prompt prefix instead of prefilling it again.
