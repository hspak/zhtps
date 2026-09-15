"""Security regressions for generated deployment files; no host changes required."""

from dataclasses import replace
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deploy"))
import connections
import ingress


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zhtps-deploy-security-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.ingress = ingress.Options("127.0.0.1", 8081, "127.0.0.1", 8080,
                                       "lo", 10, 1, 10, 1, 10, 1)
        self.connections = connections.Options("127.0.0.1", 8080, "lo", 10, 1, 10, 1)

    def generators(self):
        return ((ingress.write_bundle, self.ingress, "nginx.conf"),
                (connections.write_bundle, self.connections, "connections.nft"))

    def test_ipv6_scope_cannot_inject_nginx_configuration(self):
        for index, address in enumerate(("::1%lo", "::1%lo];\ninclude injected.conf; #")):
            with self.subTest(address=address):
                output = self.folder / str(index)
                with self.assertRaises(ValueError):
                    ingress.write_bundle(replace(self.ingress, origin_address=address), output)
                self.assertFalse(output.exists())

    def test_equivalent_ipv6_addresses_cannot_proxy_to_self(self):
        options = replace(self.ingress, listen_address="::1", origin_address="0:0:0:0:0:0:0:1",
                          origin_port=self.ingress.listen_port)
        with self.assertRaises(ValueError):
            ingress.write_bundle(options, self.folder / "invalid")
        self.assertFalse((self.folder / "invalid").exists())

    def test_bundle_does_not_follow_dangling_symlinks(self):
        for write, options, filename in self.generators():
            with self.subTest(generator=filename):
                output = self.folder / filename
                output.mkdir()
                target = self.folder / (filename + ".target")
                (output / filename).symlink_to(target)
                with self.assertRaises((ValueError, OSError)):
                    write(options, output)
                self.assertFalse(target.exists())

    def test_bundle_does_not_overwrite_a_file_created_after_the_precheck(self):
        exists = Path.exists
        for write, options, filename in self.generators():
            with self.subTest(generator=filename):
                output = self.folder / filename
                output.mkdir()
                target = output / filename

                def racing_exists(path):
                    result = exists(path)
                    if path == target and not result:
                        path.write_text("concurrent owner\n")
                    return result

                with patch.object(Path, "exists", racing_exists):
                    with self.assertRaises((ValueError, OSError)):
                        write(options, output)
                self.assertEqual(target.read_text(), "concurrent owner\n")


if __name__ == "__main__":
    unittest.main()
