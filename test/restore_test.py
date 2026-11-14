import io
import json
from pathlib import Path, PurePosixPath
import runpy
import tarfile
import tempfile
import unittest

restore_module = runpy.run_path(str(Path(__file__).resolve().parents[1] / "bin/restore-state.py"))


class RestoreTest(unittest.TestCase):
    def archive(self, directory, extras, **manifest_changes):
        path = Path(directory) / "backup.tar.gz"
        manifest = {"format": 1, "user": "dev", "bundled": True}
        manifest.update(manifest_changes)
        with tarfile.open(path, "w:gz") as output:
            for name, data in [("manifest.json", json.dumps(manifest).encode()), *extras]:
                member = tarfile.TarInfo(name)
                member.mode = 0o600
                member.size = len(data)
                output.addfile(member, io.BytesIO(data))
        return path

    def test_roundtrip_removes_stale_wal_and_keeps_private_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "target"
            data = root / "opt/matron-journal/data"
            data.mkdir(parents=True)
            (data / "matron.db-wal").write_text("old WAL")
            (data / "matron.db-shm").write_text("old SHM")
            archive = self.archive(directory, [("opt/matron-journal/data/matron.db", b"restored data")])
            restore_module["restore"](archive, [PurePosixPath("opt/matron-journal/data")], "dev", True, root)
            self.assertEqual(b"restored data", (data / "matron.db").read_bytes())
            self.assertEqual(0o600, (data / "matron.db").stat().st_mode & 0o777)
            self.assertFalse((data / "matron.db-wal").exists())
            self.assertFalse((data / "matron.db-shm").exists())

    def test_rejects_traversal_outside_paths_links_and_duplicate_members(self):
        for name in ["../etc/passwd", "/etc/passwd", "etc/passwd", "."]:
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    restore_module["validate"]([tarfile.TarInfo(name)], [PurePosixPath("state")])
        for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE]:
            member = tarfile.TarInfo("state/token")
            member.type = kind
            with self.assertRaises(ValueError):
                restore_module["validate"]([member], [PurePosixPath("state")])
        with self.assertRaises(ValueError):
            restore_module["validate"]([tarfile.TarInfo("state/token")] * 2, [PurePosixPath("state")])

    def test_wrong_mode_and_symlink_destination_leave_data_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "target"
            root.mkdir()
            outside = Path(directory) / "outside"
            outside.mkdir()
            (outside / "token").write_text("unchanged")
            (root / "state").symlink_to(outside)
            archive = self.archive(directory, [("state/token", b"replacement")])
            for bundled in [False, True]:
                with self.assertRaises(ValueError):
                    restore_module["restore"](archive, [PurePosixPath("state")], "dev", bundled, root)
            self.assertEqual("unchanged", (outside / "token").read_text())


if __name__ == "__main__":
    unittest.main()
