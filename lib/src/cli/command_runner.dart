import 'package:args/command_runner.dart';

import 'commands/login_command.dart';
import 'commands/teams_command.dart';
import 'commands/upload_command.dart';

class EmojiCommandRunner extends CommandRunner<int> {
  EmojiCommandRunner()
    : super(
        'mmemoji',
        'Reliable CLI for uploading custom emojis to Mattermost.',
      ) {
    addCommand(LoginCommand());
    addCommand(TeamsCommand());
    addCommand(UploadCommand());
  }
}
