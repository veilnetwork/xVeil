from pathlib import Path
import tempfile
import unittest

from check_hidden_volume_abi import BINDINGS, read_contract, StorageAbiFailure


class StorageAbiMetadataTest(unittest.TestCase):
    def test_current_bindings_include_the_new_constructor(self):
        contract = read_contract()
        self.assertEqual(contract.version, 30)
        self.assertEqual(contract.checksums[
            'uniffi_hidden_volume_ffi_checksum_constructor_spacehandle_create_with_padding'], 7392)
        self.assertIn('uniffi_hidden_volume_ffi_fn_constructor_spacehandle_create_with_padding', contract.symbols)

    def test_missing_checksum_cannot_hide_a_bound_method(self):
        with tempfile.TemporaryDirectory() as work:
            source = BINDINGS.read_text()
            source = '\n'.join(line for line in source.splitlines()
                               if "_checksum_constructor_spacehandle_create_with_padding':" not in line)
            path = Path(work) / 'bindings.dart'
            path.write_text(source)
            with self.assertRaises(StorageAbiFailure):
                read_contract(path)

    def test_nonliteral_checksum_is_not_parsed_as_an_integer_prefix(self):
        with tempfile.TemporaryDirectory() as work:
            source = BINDINGS.read_text().replace("_create_with_padding': 7392,",
                                                  "_create_with_padding': 7392 + 1,")
            path = Path(work) / 'bindings.dart'
            path.write_text(source)
            with self.assertRaises(StorageAbiFailure):
                read_contract(path)

    def test_absent_metadata_fails_closed_without_paths(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'private-fixture.dart'
            path.write_text('')
            for candidate in [path, path.with_suffix('.missing')]:
                with self.assertRaises(StorageAbiFailure) as raised:
                    read_contract(candidate)
                self.assertNotIn(work, str(raised.exception))


if __name__ == '__main__':
    unittest.main()
