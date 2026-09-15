"""Wire boundaries exercised with experimental batching enabled (access log off)."""
import json
import socket
import unittest

# wire consumes the executable argument before unittest parses the remaining args.
from wire import Running, Client

REQUEST=b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'

class KernelWorkTests(unittest.TestCase):
    def test_pipeline_request_limit_closes_after_exact_response_count(self):
        with Running('--no-access-log', '--max-requests', '9') as server, Client(server.port) as client:
            client.send(REQUEST * 32)
            for _ in range(9):
                self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            self.assertEqual(client.buffer, b'')
            self.assertEqual(client.socket.recv(1), b'')

    def test_aggregate_flushes_before_fragmented_body_and_interim_response(self):
        with Running('--no-access-log') as server,Client(server.port) as client:
            client.send(REQUEST*8+b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n')
            for _ in range(8):self.assertEqual(client.response()[::2],(200,b'ZHTPS\n'))
            self.assertEqual(client.response()[0],100)
            client.send(b'abc'+REQUEST)
            self.assertEqual(client.response()[::2],(200,b'abc'))
            self.assertEqual(client.response()[::2],(200,b'ZHTPS\n'))

    def test_aggregate_preserves_large_body_stream_and_close_order(self):
        body=bytes(range(256))*256
        with Running('--no-access-log') as server,Client(server.port) as client:
            client.send(REQUEST*8+b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 65536\r\n\r\n'+body+
                        b'GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n'+REQUEST*8+
                        b'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
            for _ in range(8):self.assertEqual(client.response()[::2],(200,b'ZHTPS\n'))
            self.assertEqual(client.response()[::2],(200,body))
            self.assertEqual(client.response()[::2],(200,b'one\ntwo\nthree\n'))
            for _ in range(9):self.assertEqual(client.response()[::2],(200,b'ZHTPS\n'))
            self.assertEqual(client.socket.recv(1),b'')

    def test_pipeline_respects_single_active_permit_and_recovers(self):
        with Running('--no-access-log','--max-active','1') as server,Client(server.port) as client:
            client.send(REQUEST*32)
            for _ in range(32):self.assertEqual(client.response()[::2],(200,b'ZHTPS\n'))
            client.send(REQUEST)
            self.assertEqual(client.response()[::2],(200,b'ZHTPS\n'))
            with Client(server.admin_port) as admin:
                admin.send(b'GET /debug/metrics HTTP/1.1\r\nHost: localhost\r\n\r\n')
                counters=json.loads(admin.response()[2])['counters']
                self.assertEqual(counters['requests_rejected_total'],0)
                self.assertEqual(counters['requests_aborted_total'],0)

    def test_aggregate_flushes_before_incomplete_next_head_and_eof(self):
        with Running('--no-access-log') as server,Client(server.port) as client:
            client.send(REQUEST*8+b'GET / HTTP/1.1\r\nHost:')
            for _ in range(8):self.assertEqual(client.response()[::2],(200,b'ZHTPS\n'))
            client.socket.shutdown(socket.SHUT_WR)
            self.assertEqual(client.response()[0],400)


if __name__=='__main__':unittest.main(verbosity=2)
