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
                '  diagnosticJournal.recordSpaceDiscoveryFailure(stage: SpaceDiscoveryFailureStage.routeResolve, failure: SpaceDiscoveryFailureKind.nodeUnavailable);\n'
                '  diagnosticJournal.recordCameraStart(success: false, origin: CameraStartOrigin.deviceSelection);\n'
                '  diagnosticJournal.record(DiagnosticEvent.cameraStopped, values: {DiagnosticMetric.cameraCapturing: 0});\n'
                '  diagnosticJournal.recordFolderSavedFailure(action: FolderSavedDiagnosticAction.discarding, failure: FolderSavedDiagnosticFailure.cleanup);\n'
                '  diagnosticJournal.record(DiagnosticEvent.callState, values: {\n'
                '    DiagnosticMetric.state: 2, DiagnosticMetric.direction: 0});\n'
                '  diagnosticJournal.record(DiagnosticEvent.microphoneControl, values: {\n'
                '    DiagnosticMetric.enabled: 1, DiagnosticMetric.success: 0});\n'
                '  diagnosticJournal.recordMediaPermission(video: false);\n'
                '  diagnosticJournal.recordMediaPermission(video: false, granted: true);\n'
                '  diagnosticJournal.recordMediaPermission(video: true, granted: false);\n'
                "  diagnosticJournal.recordMediaStats({'audio_input_level_band': 2, "
                "'audio_aec_enabled': 1, 'audio_ns_enabled': 1, 'audio_agc_enabled': 1, "
                "'audio_jb_target_ms': 260, "
                "'camera_capturing': 0, 'camera_device_id': 'PRIVATE_CANARY', "
                "'camera_driver_path': 'PRIVATE_CANARY', "
                "'audio_output_level_band': 4, 'device': 'PRIVATE_CANARY', "
                "'qtag': 'PRIVATE_CANARY', 'walk_tag': 'PRIVATE_CANARY', "
                "'tcp_handshake_trace': 'PRIVATE_CANARY', 'tcp_trace': 'PRIVATE_CANARY', "
                "'ordered_tcp_binding': 'tcp_ordered_binding PRIVATE_CANARY', "
                "'record_sha256': 'PRIVATE_CANARY', 'child_local': 314159265, "
                "'ordered_record_trace': 'transport.ordered_record PRIVATE_CANARY', "
                "'opaque_record_link': 'delivery.opaque_record PRIVATE_CANARY', "
                "'queue_admission_trace': 'delivery.opaque_trace stage=queue_admission outcome=missing PRIVATE_CANARY', "
                "'queue_outcome': 'PRIVATE_CANARY', "
                "'connection': 314159265, 'local_port': 45678, 'peer_port': 45679, "
                "'written_bytes': 314159265, 'read_bytes': 314159265, "
                "'tcp_kernel_progress': 'PRIVATE_CANARY', 'sent_bytes': 424242421, "
                "'acked_bytes': 424242422, 'received_bytes': 424242423, "
                "'tcp_notsent_lowat': 424242424, "
                "'video_delivery_peers': {'PRIVATE_CANARY': {"
                "'target_delay_ms': 260, 'sample_us': 314159265}}, "
                "'op': 314159265, 'local': 'PRIVATE_CANARY'});\n"
                "  diagnosticJournal.recordBackgroundState({'serviceForeground': true, "
                "'wakeLockHeld': false, 'notification': 'PRIVATE_CANARY', "
                "'networkSnapshotAvailable': true, 'networkPresent': true, "
                "'networkCellular': true, 'networkWifi': false, 'networkVpn': false, "
                "'networkValidated': true, 'processNetworkBound': false, "
                "'restrictBackgroundStatus': 1, 'networkHandle': 314159265, "
                "'uid': 314159265, 'ssid': 'PRIVATE_CANARY', "
                "'interface': 'PRIVATE_CANARY', 'addresses': ['192.0.2.1']});\n"
                "  diagnosticJournal.recordAudioOutputState({'schema': 'xveil-audio-output/1', "
                "'success': true, 'sessionState': 1, 'outputVolumePercent': 56, "
                "'appVolumePercent': 100, 'outputMuted': false, 'appMuted': false, "
                "'pid': 314159265, 'deviceId': 'PRIVATE_CANARY', "
                "'path': 'PRIVATE_CANARY'}, duringCall: true);\n"
                "  diagnosticJournal.recordAudioStart(success: false, stats: {"
                "'audio_capture_start_result': 1, 'audio_playout_start_result': 0, "
                "'audio_aec_enabled': 1, 'audio_ns_enabled': 0, 'audio_agc_enabled': 1, "
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
                    for forbidden in ['tcp_handshake_trace', 'tcp_trace', 'connection',
                                      'ordered_tcp_binding', 'tcp_ordered_binding',
                                      'record_sha256', 'child_local', 'ordered_record',
                                      'opaque_record_link',
                                      'queue_admission_trace', 'stage=queue_admission',
                                      'outcome=missing', 'queue_outcome',
                                      'local_port', 'peer_port', 'written_bytes',
                                      'read_bytes', '45678', '45679',
                                      'tcp_kernel_progress', 'sent_bytes', 'acked_bytes',
                                      'networkHandle', 'uid', 'ssid', 'addresses', '192.0.2.1',
                                      'received_bytes', 'tcp_notsent_lowat',
                                      '424242421', '424242422', '424242423', '424242424']:
                        self.assertNotIn(forbidden, json.dumps(report))
                    if enabled:
                        self.assertEqual(len(report['call_state_history']), 1)
                        self.assertEqual(report['call_state_history'][0]['values'], {
                            'state': 2, 'direction': 0,
                        })
                        evidence = report['last_evidence']
                        self.assertEqual(evidence['folderSavedFailure']['values'], {
                            'origin': 2, 'code': 13, 'success': 0,
                        })
                        self.assertEqual(evidence['cameraStart']['values'], {
                            'success': 0, 'origin': 2,
                        })
                        self.assertEqual(evidence['cameraStopped']['values'], {'cameraCapturing': 0})
                        self.assertEqual(evidence['spaceDiscoveryFailed']['values'], {
                            'state': 1, 'code': 1, 'success': 0,
                        })
                        self.assertEqual(evidence['microphoneControl']['values'], {
                            'enabled': 1, 'success': 0,
                        })
                        self.assertEqual(evidence['audioStart']['values'], {
                            'success': 0, 'audioCaptureStartResult': 1,
                            'audioPlayoutStartResult': 0,
                            'audioAecEnabled': 1, 'audioNsEnabled': 0, 'audioAgcEnabled': 1,
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
                            'audioAecEnabled': 1, 'audioNsEnabled': 1, 'audioAgcEnabled': 1,
                            'audioTargetDelayMs': 260,
                            'cameraCapturing': 0,
                        })
                        self.assertEqual(evidence['backgroundSnapshot']['values'], {
                            'supported': 1, 'success': 1,
                            'serviceForeground': 1, 'wakeLockHeld': 0,
                            'networkSnapshotAvailable': 1, 'networkPresent': 1,
                            'networkCellular': 1, 'networkWifi': 0, 'networkVpn': 0,
                            'networkValidated': 1, 'processNetworkBound': 0,
                            'restrictBackgroundStatus': 1,
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
