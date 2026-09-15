"""Slot pressure may close only eligible completed public keepalives."""

import socket
import time
import unittest

from buffer_pools import REQUEST, metrics
from wire import Client, Running


class IdleReclamationTests(unittest.TestCase):
    def test_disabled_policy_waits_for_the_original_client_to_close(self):
        with Running('--no-access-log', '--max-connections', '1', '--idle-reclaim-ms', '0') as server:
            with Client(server.port) as idle, Client(server.port) as waiting:
                idle.send(REQUEST)
                self.assertEqual(idle.response()[0], 200)
                waiting.send(REQUEST)
                waiting.socket.settimeout(.08)
                with self.assertRaises(socket.timeout):
                    waiting.response()
                idle.send(REQUEST)
                self.assertEqual(idle.response()[0], 200)
                self.assertEqual(metrics(server)['counters']['connections_reclaimed_total'], 0)
                idle.socket.close()
                waiting.socket.settimeout(2)
                self.assertEqual(waiting.response()[::2], (200, b'ZHTPS\n'))

    def test_reclaimed_original_client_can_reconnect_and_displace_the_newcomer(self):
        with Running('--no-access-log', '--max-connections', '1', '--idle-reclaim-ms', '50') as server:
            with Client(server.port) as original:
                original.send(REQUEST)
                self.assertEqual(original.response()[::2], (200, b'ZHTPS\n'))
                with Client(server.port) as newcomer:
                    newcomer.socket.settimeout(.5)
                    newcomer.send(REQUEST)
                    self.assertEqual(newcomer.response()[::2], (200, b'ZHTPS\n'))
                    self.assertEqual(original.socket.recv(1), b'')
                    with Client(server.port) as returning:
                        returning.socket.settimeout(.5)
                        returning.send(REQUEST)
                        self.assertEqual(returning.response()[::2], (200, b'ZHTPS\n'))
                        self.assertEqual(newcomer.socket.recv(1), b'')
                captured = metrics(server)['counters']
                self.assertEqual(captured['connections_reclaimed_total'], 2)
                self.assertEqual(captured['connection_reclaim_timeouts_total'], 0)

    def test_reclamation_reuses_a_single_slot_through_many_receive_cancellations(self):
        with Running('--no-access-log', '--max-connections', '1',
                     '--idle-reclaim-ms', '5') as server:
            previous = Client(server.port)
            try:
                previous.send(REQUEST)
                self.assertEqual(previous.response()[0], 200)
                for _ in range(24):
                    following = Client(server.port)
                    try:
                        following.send(REQUEST)
                        self.assertEqual(following.response()[::2], (200, b'ZHTPS\n'))
                        self.assertEqual(previous.socket.recv(1), b'')
                    except BaseException:
                        following.socket.close()
                        raise
                    previous.socket.close()
                    previous = following
                captured = metrics(server)['counters']
                self.assertEqual(captured['connections_reclaimed_total'], 24)
                self.assertEqual(captured['connection_reclaim_timeouts_total'], 0)
            finally:
                previous.socket.close()

    def test_active_body_and_admin_survive_pressure_on_an_idle_peer(self):
        with Running('--no-access-log', '--max-connections', '2', '--max-active', '2',
                     '--idle-reclaim-ms', '5') as server:
            with Client(server.port) as active, Client(server.port) as idle:
                active.send(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n'
                            b'Content-Length: 4\r\nExpect: 100-continue\r\n\r\n')
                self.assertEqual(active.response()[0], 100)
                idle.send(REQUEST)
                self.assertEqual(idle.response()[0], 200)
                with Client(server.port) as newcomer:
                    newcomer.send(REQUEST)
                    self.assertEqual(newcomer.response()[::2], (200, b'ZHTPS\n'))
                    self.assertEqual(idle.socket.recv(1), b'')
                    self.assertEqual(metrics(server)['counters']['connections_reclaimed_total'], 1)
                    active.send(b'body')
                    self.assertEqual(active.response()[::2], (200, b'body'))

    def test_initial_idle_and_recent_keepalive_are_not_reclaimed(self):
        with Running('--no-access-log', '--max-connections', '1',
                     '--idle-reclaim-ms', '1000') as server:
            with Client(server.port) as original, Client(server.port) as waiting:
                waiting.send(REQUEST)
                waiting.socket.settimeout(.06)
                with self.assertRaises(socket.timeout):
                    waiting.response()
                original.send(REQUEST)
                self.assertEqual(original.response()[0], 200)
                with self.assertRaises(socket.timeout):
                    waiting.response()
                self.assertEqual(metrics(server)['counters']['connections_reclaimed_total'], 0)

    def test_oldest_eligible_keepalive_is_selected(self):
        with Running('--no-access-log', '--max-connections', '3', '--max-active', '3',
                     '--idle-reclaim-ms', '5') as server:
            with Client(server.port) as oldest, Client(server.port) as second, Client(server.port) as third:
                for client in (oldest, second, third):
                    client.send(REQUEST)
                    self.assertEqual(client.response()[0], 200)
                time.sleep(.01)
                with Client(server.port) as newcomer:
                    newcomer.send(REQUEST)
                    self.assertEqual(newcomer.response()[0], 200)
                    self.assertEqual(oldest.socket.recv(1), b'')
                    for client in (second, third):
                        client.send(REQUEST)
                        self.assertEqual(client.response()[0], 200)


if __name__ == '__main__':
    unittest.main(verbosity=2)
