"""Verify the default startup resolver against real affinity and descriptor limits."""

import json
import os
import subprocess
import unittest

from wire import BINARY, Client, Running


def configuration(server):
    with Client(server.admin_port) as client:
        client.send(b"GET /debug/config HTTP/1.1\r\nHost: localhost\r\n\r\n")
        status, _, body = client.response()
        assert status == 200
        return json.loads(body)


class AutomaticResourcesTests(unittest.TestCase):
    def test_startup_logs_include_every_resolved_budget_without_verbose_or_access_logs(self):
        cpu = min(os.sched_getaffinity(0))
        cases = [
            (),
            ("--max-connections", "17", "--large-buffer-bytes", "2097152",
             "--http2-memory-bytes", "4194304", "--http2-worker-streams", "11",
             "--max-active", "9", "--max-rejecting", "2", "--burst", "13"),
        ]
        for options in cases:
            with self.subTest(options=options):
                with Running("--no-access-log", *options, automatic=True,
                             affinity={cpu}, nofile=128) as server:
                    config = configuration(server)
                events = [event for event in server.events if event["event"] == "resources_resolved"]
                self.assertEqual(len(events), 1)
                self.assertEqual(events[0]["level"], "info")
                fields = events[0]["fields"]
                expected = {
                    "workers": config["workers"],
                    "connections_per_worker": config["max_connections"],
                    "large_buffer_bytes_per_worker": config["large_buffer_bytes"],
                    "http2_memory_bytes_per_worker": config["http2"]["memory_bytes"],
                    "http2_streams_per_worker": config["http2"]["max_streams_per_worker"],
                    "max_active_per_worker": config["admission"]["max_active"],
                    "max_rejecting_per_worker": config["admission"]["max_rejecting"],
                    "burst_per_worker": config["admission"]["burst"],
                    "threads_per_worker": config["resources"]["threads_per_worker"],
                    "memory_budget_bytes": config["resources"]["memory_budget_bytes"],
                    "estimated_bytes": config["resources"]["estimated_bytes"],
                    "placement_source": config["resources"]["detected"]["placement"],
                }
                for name, value in expected.items():
                    self.assertIn(name, fields)
                    self.assertEqual(fields[name], value, name)
                for name in ("large_buffers_automatic", "http2_memory_automatic", "http2_streams_automatic"):
                    self.assertEqual(fields[name], config["resources"][name], name)
                listening = next(index for index, event in enumerate(server.events)
                                 if event["event"] == "listening")
                self.assertLess(server.events.index(events[0]), listening)

    def test_startup_logs_report_each_workers_cpu_and_actual_ring_sizes(self):
        cpus = sorted(os.sched_getaffinity(0))[:2]
        for placement in ("inherit", ",".join(map(str, reversed(cpus)))):
            with self.subTest(placement=placement):
                with Running("--workers", str(len(cpus)), "--worker-cpus", placement,
                             "--max-connections", "9", automatic=True) as server:
                    with Client(server.admin_port) as client:
                        client.send(b"GET /debug/workers HTTP/1.1\r\nHost: localhost\r\n\r\n")
                        status, _, body = client.response()
                        self.assertEqual(status, 200)
                        workers = json.loads(body)["workers"]
                    # Startup records use the asynchronous log queue. Keep the
                    # server alive until every worker's record has been delivered.
                    while sum(event["event"] == "worker_resources_resolved"
                              for event in server.events) < len(cpus):
                        server.ready.get(timeout=3)
                events = [event for event in server.events if event["event"] == "worker_resources_resolved"]
                self.assertEqual(len(events), len(cpus))
                for event in events:
                    worker = workers[event["worker"]]
                    self.assertEqual(event["level"], "info")
                    for name in ("cpu", "sq_entries", "cq_entries"):
                        self.assertEqual(event["fields"][name], worker[name], name)

    def test_startup_cpu_record_fits_with_a_long_valid_mapping(self):
        cpu = min(os.sched_getaffinity(0))
        mapping = "0" * 2048 + str(cpu)
        with Running("--worker-cpus", mapping, automatic=True) as server:
            events = [event for event in server.events if event["event"] == "worker_resources_resolved"]
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["fields"]["cpu"], cpu)
            self.assertLess(len(json.dumps(events[0])), 2048)

    def test_defaults_respect_affinity_and_descriptor_limit_and_serve(self):
        cpu = min(os.sched_getaffinity(0))
        with Running(automatic=True, affinity={cpu}, nofile=128) as server:
            config = configuration(server)
            self.assertEqual(config["workers"], 1)
            self.assertEqual(config["resources"]["detected"]["allowed_cpus"], 1)
            self.assertEqual(config["resources"]["detected"]["nofile_limit"], 128)
            self.assertEqual(config["max_connections"], 84)
            self.assertEqual(config["admission"]["max_active"], 63)
            self.assertEqual(config["admission"]["burst"], 63)
            self.assertEqual(config["resources"]["connections"], "descriptors")
            self.assertLessEqual(config["resources"]["estimated_bytes"],
                                 config["resources"]["memory_budget_bytes"])
            with Client(server.port) as client:
                client.send(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
                self.assertEqual(client.response()[::2], (200, b"ZHTPS\n"))
            self.assertTrue(any(event["event"] == "resources_resolved" for event in server.events))

    def test_explicit_values_override_automatic_choices(self):
        with Running("--workers", "1", "--max-connections", "17",
                     "--large-buffer-bytes", "2097152", "--http2-memory-bytes", "4194304",
                     "--http2-worker-streams", "11", "--max-active", "9", "--burst", "13",
                     automatic=True) as server:
            config = configuration(server)
            self.assertEqual(config["workers"], 1)
            self.assertEqual(config["max_connections"], 17)
            self.assertEqual(config["large_buffer_bytes"], 2097152)
            self.assertEqual(config["http2"]["memory_bytes"], 4194304)
            self.assertEqual(config["http2"]["max_streams_per_worker"], 11)
            self.assertEqual(config["admission"]["max_active"], 9)
            self.assertEqual(config["admission"]["burst"], 13)
            self.assertEqual(config["resources"]["workers"], "explicit")
            self.assertEqual(config["resources"]["connections"], "explicit")

    def test_explicit_mapping_determines_worker_count_and_pins_live_thread(self):
        cpu = min(os.sched_getaffinity(0))
        with Running("--worker-cpus", str(cpu), automatic=True) as server:
            self.assertEqual(configuration(server)["workers"], 1)
            with Client(server.admin_port) as client:
                client.send(b"GET /debug/workers HTTP/1.1\r\nHost: localhost\r\n\r\n")
                worker = json.loads(client.response()[2])["workers"][0]
            self.assertEqual(worker["cpu"], cpu)
            self.assertEqual(os.sched_getaffinity(worker["thread"]), {cpu})

    def test_impossible_memory_budget_fails_before_listening(self):
        result = subprocess.run([BINARY, "--port", "0", "--admin-port", "0",
                                 "--memory-budget-bytes", "1"],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        events = [json.loads(line) for line in result.stderr.splitlines()]
        self.assertEqual([event["event"] for event in events], ["startup_or_runtime_error"])
        self.assertEqual(events[0]["reason"], "MemoryBudgetExceeded")


if __name__ == "__main__":
    unittest.main(verbosity=2)
