"""Exercise integrated aggregation, logging snapshots, and bounded-pool fallback."""

import concurrent.futures
import json
import time
import unittest

from wire import Client, Running

REQUEST = b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'


def metrics(server):
    with Client(server.admin_port) as admin:
        admin.send(b'GET /debug/metrics HTTP/1.1\r\nHost: localhost\r\n\r\n')
        return json.loads(admin.response()[2])['counters']


class ResponseAggregationTests(unittest.TestCase):
    def test_access_logs_keep_each_request_after_parser_and_body_buffer_reuse(self):
        expected = [('GET', 200, b'ZHTPS\n'), ('HEAD', 200, b''),
                    ('OPTIONS', 204, b''), ('POST', 200, b'abc')]
        requests = [REQUEST, b'HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n',
                    b'OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n',
                    b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc']
        with Running('--log-slots', '1024') as server, Client(server.port) as client:
            client.send(b''.join(requests) * 8)
            for method, status, body in expected * 8:
                self.assertEqual(client.response(head=method == 'HEAD')[::2], (status, body))
            deadline = time.monotonic() + 3
            records = []
            while len(records) < 32 and time.monotonic() < deadline:
                records = [event for event in server.events if event.get('event') == 'request_complete']
                time.sleep(.01)
            self.assertEqual(len(records), 32)
            self.assertEqual([(e['method'], e['status'], e['bytes']) for e in records],
                             [(method, status, len(body)) for method, status, body in expected * 8])
            self.assertEqual(len({e['request'] for e in records}), 32)
            self.assertEqual([e['request'] for e in records], sorted(e['request'] for e in records))
            self.assertEqual(len({e['connection'] for e in records}), 1)
            counters = metrics(server)
            self.assertGreaterEqual(counters['responses_batched_total'], 16)
            self.assertGreater(counters['response_batches_total'], 0)
            self.assertEqual(counters['log_dropped_total'], 0)
            self.assertEqual(counters['requests_aborted_total'], 0)

    def test_rate_limit_close_flushes_preceding_admitted_response(self):
        with Running('--rate', '1', '--burst', '1', '--max-rejecting', '0',
                     '--no-access-log') as server, Client(server.port) as client:
            client.send(REQUEST * 8)
            self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            self.assertEqual(client.buffer, b'')
            self.assertEqual(client.socket.recv(1), b'')
            counters = metrics(server)
            self.assertEqual(counters['requests_admitted_total'], 1)
            self.assertEqual(counters['requests_completed_total'], 1)
            self.assertEqual(counters['requests_aborted_total'], 1)
            self.assertEqual(counters['responses_batched_total'], 1)

    def test_zero_pool_uses_ordinary_sends(self):
        with Running('--response-batches', '0', '--no-access-log') as server, Client(server.port) as client:
            client.send(REQUEST * 32)
            for _ in range(32):
                self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            counters = metrics(server)
            self.assertEqual(counters['responses_batched_total'], 0)
            self.assertEqual(counters['response_batch_fallbacks_total'], 0)

    def test_invalid_pipeline_head_preserves_preceding_responses_without_rejection_permits(self):
        for batches in (0, 1):
            with self.subTest(batches=batches), Running(
                    '--response-batches', str(batches), '--max-rejecting', '0',
                    '--no-access-log') as server, Client(server.port) as client:
                client.send(REQUEST * 3 + b'GET / HTTP/1.1\r\nInvalid\r\n\r\n')
                for _ in range(3):
                    self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
                self.assertEqual(client.buffer, b'')
                self.assertEqual(client.socket.recv(1), b'')
                counters = metrics(server)
                self.assertEqual(counters['requests_completed_total'], 3)
                deadline = time.monotonic() + 2
                while counters['requests_aborted_total'] == 0 and time.monotonic() < deadline:
                    time.sleep(.01)
                    counters = metrics(server)
                self.assertEqual(counters['requests_admitted_total'], 3)
                self.assertEqual(counters['requests_aborted_total'], 1)
                self.assertEqual(counters['protocol_errors_total'], 1)
                self.assertEqual(counters['responses_batched_total'], 3 if batches else 0)

    def test_one_buffer_serves_many_pipelines_and_is_recycled_after_disconnects(self):
        with Running('--response-batches', '1', '--max-connections', '128',
                     '--max-active', '128', '--no-access-log') as server:
            def pipeline(_):
                with Client(server.port) as client:
                    for _ in range(4):
                        client.send(REQUEST * 32)
                        for _ in range(32):
                            self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                list(executor.map(pipeline, range(24)))
            before = metrics(server)
            pipeline(0)
            after = metrics(server)
            self.assertGreater(after['responses_batched_total'], before['responses_batched_total'])
            for name in ('requests_rejected_total', 'requests_aborted_total', 'protocol_errors_total',
                         'request_timeouts_total', 'io_errors_total'):
                self.assertEqual(after[name], 0, name)

    def test_stream_completion_does_not_get_counted_as_another_aggregate_response(self):
        with Running('--log-slots', '1024') as server, Client(server.port) as client:
            client.send(REQUEST * 8 + b'GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n' + REQUEST * 8)
            for _ in range(8):
                self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            self.assertEqual(client.response()[::2], (200, b'one\ntwo\nthree\n'))
            for _ in range(8):
                self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            counters = metrics(server)
            self.assertGreater(counters['responses_batched_total'], 0)
            self.assertLessEqual(counters['responses_batched_total'], 16)
            deadline = time.monotonic() + 3
            while not any(e.get('event') == 'request_complete' for e in server.events) and time.monotonic() < deadline:
                time.sleep(.01)
            public_connection = next(e['connection'] for e in server.events if e.get('event') == 'request_complete')
            while len([e for e in server.events if e.get('event') == 'request_complete' and e['connection'] == public_connection]) < 17 and time.monotonic() < deadline:
                time.sleep(.01)
            records = [e for e in server.events if e.get('event') == 'request_complete' and e['connection'] == public_connection]
            self.assertEqual(len(records), 17)
            self.assertEqual([e['bytes'] for e in records], [6] * 8 + [14] + [6] * 8)


if __name__ == '__main__':
    unittest.main(verbosity=2)
