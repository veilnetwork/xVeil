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
                '  diagnosticJournal.record(DiagnosticEvent.callState, values: {\n'
                '    DiagnosticMetric.state: 2, DiagnosticMetric.direction: 0});\n'
                '  diagnosticJournal.record(DiagnosticEvent.microphoneControl, values: {\n'
                '    DiagnosticMetric.enabled: 1, DiagnosticMetric.success: 0});\n'
                '  diagnosticJournal.recordMediaPermission(video: false);\n'
                '  diagnosticJournal.recordMediaPermission(video: false, granted: true);\n'
                '  diagnosticJournal.recordMediaPermission(video: true, granted: false);\n'
                "  diagnosticJournal.recordMediaStats({'audio_input_level_band': 2, "
                "'audio_output_level_band': 4, 'device': 'PRIVATE_CANARY', "
                "'qtag': 'PRIVATE_CANARY', 'walk_tag': 'PRIVATE_CANARY', "
                "'op': 314159265, 'local': 'PRIVATE_CANARY'});\n"
                "  diagnosticJournal.recordBackgroundState({'serviceForeground': true, "
                "'wakeLockHeld': false, 'notification': 'PRIVATE_CANARY'});\n"
                "  diagnosticJournal.recordAudioOutputState({'schema': 'xveil-audio-output/1', "
                "'success': true, 'sessionState': 1, 'outputVolumePercent': 56, "
                "'appVolumePercent': 100, 'outputMuted': false, 'appMuted': false, "
                "'pid': 314159265, 'deviceId': 'PRIVATE_CANARY', "
                "'path': 'PRIVATE_CANARY'}, duringCall: true);\n"
                "  diagnosticJournal.recordAudioStart(success: false, stats: {"
                "'audio_capture_start_result': 1, 'audio_playout_start_result': 0, "
                "'deviceId': 'PRIVATE_CANARY', 'path': 'PRIVATE_CANARY'});\n"
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
                    self.assertNotIn('PRIVATE_CANARY', json.dumps(report))
                    self.assertNotIn('314159265', json.dumps(report))
                    if enabled:
                        self.assertEqual(len(report['call_state_history']), 1)
                        self.assertEqual(report['call_state_history'][0]['values'], {
                            'state': 2, 'direction': 0,
                        })
                        evidence = report['last_evidence']
                        self.assertEqual(evidence['microphoneControl']['values'], {
                            'enabled': 1, 'success': 0,
                        })
                        self.assertEqual(evidence['audioStart']['values'], {
                            'success': 0, 'audioCaptureStartResult': 1,
                            'audioPlayoutStartResult': 0,
                        })
                        self.assertEqual(evidence['callAudioOutput']['values'], {
                            'supported': 1, 'success': 1, 'appAudioSessionState': 1,
                            'outputVolumePercent': 56, 'appOutputVolumePercent': 100,
                            'outputMuted': 0, 'appOutputMuted': 0,
                        })
                        self.assertEqual(evidence['microphonePermission']['values'], {'state': 1})
                        self.assertEqual(evidence['cameraPermission']['values'], {'state': 0})
                        self.assertEqual(evidence['mediaSample']['values'], {
                            'audioInputLevelBand': 2, 'audioOutputLevelBand': 4,
                        })
                        self.assertEqual(evidence['backgroundSnapshot']['values'], {
                            'supported': 1, 'success': 1,
                            'serviceForeground': 1, 'wakeLockHeld': 0,
                        })
                    else:
                        self.assertNotIn('call_state_history', report)
                        self.assertEqual(report['events'], [])
                        self.assertEqual(report['last_evidence'], {})
                    gate = subprocess.run(
                        [sys.executable, str(root / 'scripts/verify-diagnostic-artifact.py'),
                         str(executable)], capture_output=True, text=True,
                    )
                    self.assertEqual(gate.returncode == 0, enabled, gate.stdout + gate.stderr)
                    if not enabled:
                        self.assertIn('instrumentation missing', gate.stderr)


if __name__ == '__main__':
    unittest.main()
