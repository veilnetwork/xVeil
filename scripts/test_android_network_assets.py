#!/usr/bin/env python3
"""Release APKs must carry the configured deployment assets exactly."""
import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import builder


class AndroidNetworkAssets(unittest.TestCase):
    def check(self, network, staged, packaged):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, data in staged.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            output = root / 'build/app/outputs/flutter-apk'
            output.mkdir(parents=True)
            for abi in builder._RELEASE_APK_ABIS:
                with zipfile.ZipFile(output / f'app-{abi}-release.apk', 'w') as apk:
                    for name, data in packaged[abi].items():
                        apk.writestr('assets/flutter_assets/' + name, data)
            # This fixture isolates the deployment gate; native ELF/symbol
            # requirements have their own real-library and packaging tests.
            with patch.object(builder, 'ROOT', tmp), \
                 patch.object(builder, '_REQUIRED_EVERY_ABI', ()), \
                 patch.object(builder, '_MEDIA_ABIS', ()), \
                 patch.dict(os.environ, {'XVEIL_NETWORK': network}), \
                 contextlib.redirect_stdout(io.StringIO()):
                builder._check_android_native_libs()

    def packaged(self, staged):
        return {abi: dict(staged) for abi in builder._RELEASE_APK_ABIS}

    def test_missing_stale_or_unexpected_network_material_refuses_release(self):
        cases = [
            ('prod', 'arm64-v8a', 'obfs4_psk.b64', 'missing'),
            ('prod', 'armeabi-v7a', 'obfs4_psk.b64', 'different'),
            ('testnet', 'x86_64', 'obfs4_psk.b64', 'missing'),
            ('testnet', 'arm64-v8a', 'seeds.json', 'different'),
            ('prod', 'armeabi-v7a', 'obfs4_psk.b64', 'unexpected'),
            ('testnet', 'x86_64', 'seeds.json', 'unexpected'),
        ]
        for network, abi, filename, mode in cases:
            with self.subTest(network=network, abi=abi, filename=filename, mode=mode):
                name = f'assets/{network}/{filename}'
                staged = {name: b'current-private-fixture'}
                packaged = self.packaged(staged)
                if mode == 'missing':
                    del packaged[abi][name]
                elif mode == 'different':
                    packaged[abi][name] = b'previous-private-fixture'
                else:
                    del staged[name]
                with self.assertRaises(RuntimeError) as refusal:
                    self.check(network, staged, packaged)
                message = str(refusal.exception)
                self.assertIn(abi, message)
                self.assertIn(name, message)
                self.assertNotIn('private-fixture', message)

    def test_matching_assets_on_every_shipped_abi_pass(self):
        for network in ('prod', 'testnet'):
            staged = {
                f'assets/{network}/seeds.json': b'[]\n',
                f'assets/{network}/obfs4_psk.b64': b'configured-private-fixture\n',
            }
            with self.subTest(network=network):
                self.check(network, staged, self.packaged(staged))

    def test_explicitly_unconfigured_deployment_remains_supported(self):
        self.check('prod', {}, self.packaged({}))

    def test_unselected_network_is_not_this_builds_configuration(self):
        staged = {'assets/prod/obfs4_psk.b64': b'current-private-fixture'}
        packaged = self.packaged(staged)
        for files in packaged.values():
            files['assets/testnet/obfs4_psk.b64'] = b'other-network-fixture'
        self.check('prod', staged, packaged)


if __name__ == '__main__':
    unittest.main()
