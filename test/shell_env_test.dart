// Tests for the shell-profile parser behind File ▸ Environment. The
// contract it pins down: dbscope reads `export FOO=bar` lines out of a
// file it is NOT allowed to execute, so the parser has to match a
// shell's behaviour on the shapes people actually write (quotes,
// comments, `$HOME` references, `source` lines) and ignore everything
// else rather than guess. Getting a value subtly wrong here means an
// API key that looks present and fails at the provider.

import 'package:flutter_test/flutter_test.dart';

import 'package:dbscope/util/shell_env_io.dart';

void main() {
  group('parseShellEnv', () {
    test('reads plain and exported assignments', () async {
      final vars = await parseShellEnv('''
export GEMINI_API_KEY=AIzaSecret
PLAIN=value
''');
      expect(vars['GEMINI_API_KEY'], 'AIzaSecret');
      expect(vars['PLAIN'], 'value');
    });

    test('strips surrounding quotes', () async {
      final vars = await parseShellEnv('''
export DOUBLE="a value"
export SINGLE='another value'
''');
      expect(vars['DOUBLE'], 'a value');
      expect(vars['SINGLE'], 'another value');
    });

    test('ignores comments and non-assignment lines', () async {
      final vars = await parseShellEnv('''
# a comment
if [[ -f ~/.x ]]; then
  eval "\$(rbenv init -)"
fi
export KEPT=yes # trailing note
''');
      expect(vars['KEPT'], 'yes');
      expect(vars.keys, ['KEPT']);
    });

    test('keeps a # that is part of an unquoted value', () async {
      final vars = await parseShellEnv('export COLOR=#ff0000\n');
      expect(vars['COLOR'], '#ff0000');
    });

    test('expands \$VAR and \${VAR} from earlier lines', () async {
      final vars = await parseShellEnv('''
export BASE=/opt/tools
export BIN=\$BASE/bin
export LIB=\${BASE}/lib
''');
      expect(vars['BIN'], '/opt/tools/bin');
      expect(vars['LIB'], '/opt/tools/lib');
    });

    test('does not expand inside single quotes', () async {
      final vars = await parseShellEnv("export LITERAL='\$BASE/bin'\n");
      expect(vars['LITERAL'], r'$BASE/bin');
    });

    test('expands an unknown name to empty, as a shell would', () async {
      final vars = await parseShellEnv('export X="\$NOT_SET/tail"\n');
      expect(vars['X'], '/tail');
    });

    test('a later assignment wins', () async {
      final vars = await parseShellEnv('A=first\nA=second\n');
      expect(vars['A'], 'second');
    });

    test('layers onto base, which seeds expansion', () async {
      final vars = await parseShellEnv(
        'export CHILD=\$PARENT/sub\n',
        base: {'PARENT': '/root'},
      );
      expect(vars['CHILD'], '/root/sub');
      expect(vars['PARENT'], '/root');
    });

    test('follows source and . includes, in order', () async {
      final vars = await parseShellEnv(
        '''
export FIRST=1
. "\$HOME/.cargo/env"
source /etc/other
export LAST=3
''',
        base: {'HOME': '/home/me'},
        readInclude: (path) async => switch (path) {
          '/home/me/.cargo/env' => 'export CARGO=yes\nexport FIRST=2\n',
          '/etc/other' => 'export OTHER=yes\n',
          _ => null,
        },
      );
      expect(vars['CARGO'], 'yes');
      expect(vars['OTHER'], 'yes');
      // The include ran after FIRST=1, so its own FIRST=2 wins.
      expect(vars['FIRST'], '2');
      expect(vars['LAST'], '3');
    });

    test('ignores an include that cannot be read', () async {
      final vars = await parseShellEnv(
        'source /nope\nexport KEPT=yes\n',
        readInclude: (_) async => null,
      );
      expect(vars['KEPT'], 'yes');
    });

    test('a self-sourcing file terminates', () async {
      final vars = await parseShellEnv(
        'source /loop\n',
        readInclude: (_) async => 'source /loop\nexport DEEP=yes\n',
      );
      expect(vars['DEEP'], 'yes');
    });

    test('does not mistake a relative path for a . include', () async {
      final vars = await parseShellEnv(
        './install.sh\nexport KEPT=yes\n',
        readInclude: (_) async => 'export LEAKED=yes\n',
      );
      expect(vars.containsKey('LEAKED'), isFalse);
      expect(vars['KEPT'], 'yes');
    });
  });
}
