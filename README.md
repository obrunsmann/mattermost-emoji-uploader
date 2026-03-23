# mattermost_emoji_uploader

![GitHub License](https://img.shields.io/github/license/obrunsmann/mattermost-emoji-uploader)
![GitHub Issues or Pull Requests](https://img.shields.io/github/issues/obrunsmann/mattermost-emoji-uploader)
[![Release Binaries](https://github.com/obrunsmann/mattermost-emoji-uploader/actions/workflows/release.yml/badge.svg)](https://github.com/obrunsmann/mattermost-emoji-uploader/actions/workflows/release.yml)

Reliable Dart CLI to upload custom emojis to Mattermost with:

- resumable runs
- retry with backoff
- adaptive rate-limit handling
- persistent tracking in SQLite
- debug logs and JSON report output

## Build

```bash
dart pub get
dart run bin/mattermost_emoji_uploader.dart --help
```

## Commands

```bash
dart run bin/mattermost_emoji_uploader.dart login --server https://chat.example.com --user alice
dart run bin/mattermost_emoji_uploader.dart teams list
dart run bin/mattermost_emoji_uploader.dart teams select --team my-team-id
dart run bin/mattermost_emoji_uploader.dart upload --source brunsi.yaml --rate 4 --concurrency 2 --retries 6 --debug
dart run bin/mattermost_emoji_uploader.dart clear --yes --rate 4 --retries 6 --debug
```

## Notes

- State DB: `.mmemoji/state.db`
- Logs: `.mmemoji/logs/run-<id>.jsonl`
- Report: `.mmemoji/reports/run-<id>.json`
- Clear logs: `.mmemoji/logs/clear-<timestamp>.jsonl`

## Destructive command

`clear` deletes all custom emojis from the server.
Use `--dry-run` to preview and `--yes` to execute.
