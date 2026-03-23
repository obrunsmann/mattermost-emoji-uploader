import 'dart:io';

import 'package:args/command_runner.dart';

import '../../core/mattermost_client.dart';
import '../../core/models.dart';
import '../../core/profile_store.dart';
import '../support.dart';

class LoginCommand extends Command<int> {
  LoginCommand() {
    argParser
      ..addOption(
        'server',
        abbr: 's',
        help: 'Mattermost server URL, e.g. https://chat.example.com',
      )
      ..addOption('user', abbr: 'u', help: 'Login id (email/username/LDAP id)')
      ..addOption('password', abbr: 'p', help: 'Password')
      ..addFlag(
        'password-stdin',
        negatable: false,
        help: 'Read password from stdin pipe.',
      );
  }

  @override
  String get name => 'login';

  @override
  String get description =>
      'Login and store token locally in .mmemoji/profile.json';

  @override
  Future<int> run() async {
    final server = argResults?['server'] as String?;
    final user = argResults?['user'] as String?;

    if (server == null || server.trim().isEmpty) {
      throw UsageException('Missing required option: --server', usage);
    }
    if (user == null || user.trim().isEmpty) {
      throw UsageException('Missing required option: --user', usage);
    }

    final password = await _resolvePassword();
    final login = await MattermostClient.login(
      baseUrl: server,
      loginId: user,
      password: password,
    );

    final profileStore = ProfileStore(rootDirPath: appRootPath());
    final profile = Profile(
      server: server,
      loginId: user,
      userId: login.userId,
      token: login.token,
      createdAtIso: DateTime.now().toUtc().toIso8601String(),
    );
    await profileStore.save(profile);

    stdout.writeln('Login successful.');
    stdout.writeln('Profile saved: ${profileStore.profilePath}');
    return 0;
  }

  Future<String> _resolvePassword() async {
    final inline = argResults?['password'] as String?;
    if (inline != null && inline.isNotEmpty) {
      return inline;
    }

    final fromStdin = argResults?['password-stdin'] as bool? ?? false;
    if (fromStdin) {
      return readPasswordFromStdinPipe();
    }

    return readPasswordFromStdinPrompt();
  }
}
