"""Test SYN shedding in a disposable user/network namespace, never the host ruleset."""

from dataclasses import replace
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy"))
from connections import Options, nft_config, write_bundle


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while request := self.request.recv(1):
            self.request.sendall(request)


class Listener(socketserver.ThreadingTCPServer):
    daemon_threads = True


class KernelTests(unittest.TestCase):
    def setUp(self):
        parent = os.environ.get("ZHTPS_TEST_PARENT_NETNS")
        if not parent or parent == os.readlink("/proc/self/ns/net"):
            raise RuntimeError("refuse firewall changes outside the isolated test namespace")
        self.service = Listener(("127.0.0.1", 0), Echo)
        self.thread = threading.Thread(target=self.service.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_listener)
        self.options = Options("127.0.0.1", self.service.server_address[1], "lo", 1, 1, 1, 1)
        subprocess.run(["nft", "-f", "-"], input=nft_config(self.options), text=True, check=True)
        self.addCleanup(subprocess.run, ["nft", "delete", "table", "inet", self.options.table], check=True)

    def close_listener(self):
        self.service.shutdown()
        self.service.server_close()
        self.thread.join()

    def connect(self):
        return socket.create_connection(self.service.server_address, timeout=.15)

    def counters(self):
        result = json.loads(subprocess.check_output(["nft", "-j", "list", "counters", "table", "inet", self.options.table]))
        return {row["counter"]["name"]: row["counter"]["packets"]
                for row in result["nftables"] if "counter" in row}

    def test_reset_then_bounded_drop_preserves_existing_connection_and_recovers(self):
        with self.connect() as established:
            established.sendall(b"a")
            self.assertEqual(b"a", established.recv(1))
            started = time.monotonic()
            with self.assertRaises(ConnectionRefusedError):
                self.connect()
            self.assertLess(time.monotonic() - started, .15)
            with self.assertRaises(TimeoutError):
                self.connect()
            established.sendall(b"b")
            self.assertEqual(b"b", established.recv(1))
            counters = self.counters()
            self.assertEqual(3, counters["syn_attempts"])
            self.assertEqual(2, counters["syn_over_limit"])
            self.assertEqual(1, counters["syn_resets"])
            self.assertEqual(1, counters["syn_drops"])
            time.sleep(1.05)
            with self.connect() as recovered:
                recovered.sendall(b"c")
                self.assertEqual(b"c", recovered.recv(1))

    def test_unrelated_listener_is_not_policed(self):
        with self.connect():
            pass
        other = socket.socket()
        self.addCleanup(other.close)
        other.bind(("127.0.0.1", 0))
        other.listen(16)
        for _ in range(10):
            with socket.create_connection(other.getsockname(), .15):
                accepted, _ = other.accept()
                accepted.close()
        self.assertEqual(1, self.counters()["syn_attempts"])

    def test_ipv6_rules_are_accepted_by_kernel(self):
        options = replace(self.options, listen_address="::1", table="zhtps_ingress_v6")
        subprocess.run(["nft", "-f", "-"], input=nft_config(options), text=True, check=True)
        self.addCleanup(subprocess.run, ["nft", "delete", "table", "inet", options.table], check=True)
        listener = socket.socket(socket.AF_INET6)
        self.addCleanup(listener.close)
        listener.bind(("::1", options.listen_port))
        listener.listen(4)
        with socket.create_connection(("::1", options.listen_port), .15):
            accepted, _ = listener.accept()
            accepted.close()
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(("::1", options.listen_port), .15)

    def test_direct_cli_requires_only_listener_and_connection_budgets(self):
        with tempfile.TemporaryDirectory(prefix="zhtps-direct-policy-") as temporary:
            output = Path(temporary) / "bundle"
            command = [sys.executable, str(ROOT / "deploy/connections.py"),
                       "--output", str(output), "--listen-address", "127.0.0.1",
                       "--listen-port", str(self.options.listen_port), "--interface", "lo",
                       "--connection-rate", "20", "--connection-burst", "3",
                       "--reset-rate", "5", "--reset-burst", "2", "--table", "zhtps_direct_cli"]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual({"connections.nft", "remove-connections.nft", "limits.json"},
                             {path.name for path in output.iterdir()})
            limits = json.loads((output / "limits.json").read_text())
            self.assertEqual(20, limits["connection_rate"])
            self.assertEqual(5, limits["reset_rate"])
            subprocess.run(["nft", "-f", str(output / "connections.nft")], check=True)
            self.addCleanup(subprocess.run, ["nft", "delete", "table", "inet", "zhtps_direct_cli"], check=True)
            self.assertNotEqual(0, subprocess.run(command, capture_output=True).returncode)
            self.assertEqual(limits, json.loads((output / "limits.json").read_text()))

    def test_direct_cli_rejects_invalid_policy_before_writing(self):
        with tempfile.TemporaryDirectory(prefix="zhtps-invalid-policy-") as temporary:
            output = Path(temporary) / "bundle"
            for changes in ({"listen_address": "0.0.0.0"}, {"interface": 'lo"; flush ruleset'},
                            {"table": "bad;table"}, {"connection_rate": 0}, {"reset_burst": 0}):
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    write_bundle(replace(self.options, **changes), output)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    if "--inside" not in sys.argv:
        env = dict(os.environ, ZHTPS_TEST_PARENT_NETNS=os.readlink("/proc/self/ns/net"))
        command = ["unshare", "--user", "--map-root-user", "--net", sys.executable,
                   str(Path(__file__).resolve()), "--inside", *sys.argv[1:]]
        sys.exit(subprocess.run(command, env=env).returncode)
    sys.argv.remove("--inside")
    if os.environ.get("ZHTPS_TEST_PARENT_NETNS") == os.readlink("/proc/self/ns/net"):
        sys.exit("expected a fresh network namespace")
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    unittest.main()
