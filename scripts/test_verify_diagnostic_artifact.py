#!/usr/bin/env python3
"""Exercise the artifact gate against actual AOT of the production journal."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class DiagnosticArtifactTest(unittest.TestCase):
    def test_flag_is_required_even_when_schema_is_present(self):
        root = Path(__file__).resolve().parent.parent
        journal = root / 'lib/core/diagnostic_journal.dart'
        with tempfile.TemporaryDirectory(prefix='xveil-diagnostic-aot-') as directory:
            directory = Path(directory)
            source = directory / 'main.dart'
            source.write_text(
                "import 'dart:convert';\n"
                f'import {json.dumps(journal.as_uri())};\n'
                'void main() {\n'
                '  diagnosticJournal.record(DiagnosticEvent.startup);\n'
                '  print(jsonEncode(diagnosticJournal.toJson()));\n'
                '}\n'
            )
            for enabled in [False, True]:
                with self.subTest(enabled=enabled):
                    executable = directory / ('diagnostic' if enabled else 'normal')
                    command = ['dart', 'compile', 'exe']
                    if enabled:
                        command.append('-DXVEIL_DIAGNOSTICS=true')
                    subprocess.run(command + [str(source), '-o', str(executable)],
                                   check=True, capture_output=True, text=True)
                    data = executable.read_bytes()
                    self.assertIn(b'xveil-diagnostics/1', data)
                    report = json.loads(subprocess.check_output([str(executable)], text=True))
                    self.assertEqual(report['enabled'], enabled)
                    gate = subprocess.run(
                        [sys.executable, str(root / 'scripts/verify-diagnostic-artifact.py'),
                         str(executable)], capture_output=True, text=True,
                    )
                    self.assertEqual(gate.returncode == 0, enabled, gate.stdout + gate.stderr)
                    if not enabled:
                        self.assertIn('instrumentation missing', gate.stderr)


if __name__ == '__main__':
    unittest.main()
