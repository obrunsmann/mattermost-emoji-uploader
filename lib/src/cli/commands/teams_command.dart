import 'dart:io';

import 'package:args/command_runner.dart';

import '../../core/mattermost_client.dart';
import '../../core/profile_store.dart';
import '../support.dart';

class TeamsCommand extends Command<int> {
  TeamsCommand() {
    addSubcommand(_TeamsListCommand());
    addSubcommand(_TeamsSelectCommand());
  }

  @override
  String get name => 'teams';

  @override
  String get description => 'List and select teams for the stored profile.';
}

class _TeamsListCommand extends Command<int> {
  @override
  String get name => 'list';

  @override
  String get description => 'List teams for the logged in user.';

  @override
  Future<int> run() async {
    final profileStore = ProfileStore(rootDirPath: appRootPath());
    final profile = await profileStore.load();
    if (profile == null) {
      throw UsageException(
        'No profile found. Run `mmemoji login` first.',
        usage,
      );
    }

    final client = MattermostClient(
      baseUrl: profile.server,
      token: profile.token,
    );
    try {
      final userId = profile.userId.isEmpty
          ? await client.getCurrentUserId()
          : profile.userId;
      final teams = await client.getTeamsForUser(userId);

      if (teams.isEmpty) {
        stdout.writeln('No teams found for this user.');
        return 0;
      }

      stdout.writeln('Teams:');
      for (var i = 0; i < teams.length; i++) {
        final team = teams[i];
        final selected = profile.selectedTeamId == team.id ? ' [selected]' : '';
        stdout.writeln(
          '${i + 1}. ${team.displayName} (${team.name}) id=${team.id}$selected',
        );
      }
      return 0;
    } finally {
      client.close();
    }
  }
}

class _TeamsSelectCommand extends Command<int> {
  _TeamsSelectCommand() {
    argParser.addOption(
      'team',
      abbr: 't',
      help: 'Team id, name or display_name',
    );
  }

  @override
  String get name => 'select';

  @override
  String get description => 'Select a team and persist its id in profile.';

  @override
  Future<int> run() async {
    final selector = argResults?['team'] as String?;
    if (selector == null || selector.trim().isEmpty) {
      throw UsageException('Missing required option: --team', usage);
    }

    final profileStore = ProfileStore(rootDirPath: appRootPath());
    final profile = await profileStore.load();
    if (profile == null) {
      throw UsageException(
        'No profile found. Run `mmemoji login` first.',
        usage,
      );
    }

    final client = MattermostClient(
      baseUrl: profile.server,
      token: profile.token,
    );

    try {
      final teams = await client.getTeamsForUser(profile.userId);
      final wanted = selector.toLowerCase();
      final selected = teams.where((team) {
        return team.id.toLowerCase() == wanted ||
            team.name.toLowerCase() == wanted ||
            team.displayName.toLowerCase() == wanted;
      }).toList();

      if (selected.isEmpty) {
        throw UsageException('No matching team found for "$selector".', usage);
      }
      if (selected.length > 1) {
        throw UsageException(
          'Selector "$selector" matched multiple teams. Please use team id.',
          usage,
        );
      }

      final team = selected.first;
      await profileStore.save(profile.copyWith(selectedTeamId: team.id));
      stdout.writeln(
        'Selected team: ${team.displayName} (${team.name}) id=${team.id}',
      );
      return 0;
    } finally {
      client.close();
    }
  }
}
