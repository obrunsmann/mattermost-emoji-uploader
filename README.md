# mattermost_emoji_uploader

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
```

## Notes

- State DB: `.mmemoji/state.db`
- Logs: `.mmemoji/logs/run-<id>.jsonl`
- Report: `.mmemoji/reports/run-<id>.json`
