"""The image check's stand-in phone that looks for the TV (T25.1), without a
VM or a network: the questions it asks, and what it makes of an answer like
the one Avahi gives, with the names in it shortened the way a real answer
shortens them.
"""

from __future__ import annotations

import socket
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "test/origaitv/image"))

import mdns  # noqa: E402

SERVICE = "_origaitv._tcp"
ID = "0123456789abcdef0123456789abcdef"


def answer(instance: str = "origaitv", extra: bytes = b"", count: int = 0) -> bytes:
    """A PTR for the type, with the instance's SRV, TXT and its host's A
    after it. Every name after the first points back into the packet."""
    head = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 3 + count)
    service_at = len(head)
    packet = head + mdns.encode(SERVICE + ".local")
    local_at = service_at + len(mdns.encode(SERVICE + ".local")) - len(mdns.encode("local"))
    pointer = lambda at: struct.pack(">H", 0xC000 | at)  # noqa: E731

    raw = instance.encode()
    target = bytes([len(raw)]) + raw + pointer(service_at)
    packet += struct.pack(">HHIH", mdns.PTR, 1, 4500, len(target))
    instance_at = len(packet)
    packet += target

    host = b"\x08origaitv" + pointer(local_at)
    packet += pointer(instance_at) + struct.pack(">HHIH", mdns.SRV, 0x8001, 120, 6 + len(host)) + struct.pack(">HHH", 0, 0, 3001)
    host_at = len(packet)
    packet += host

    entries = [f"id={ID}".encode(), b"version=1.0.0.r7.gabc1234"]
    txt = b"".join(bytes([len(entry)]) + entry for entry in entries)
    packet += pointer(instance_at) + struct.pack(">HHIH", mdns.TXT, 0x8001, 4500, len(txt)) + txt
    packet += pointer(host_at) + struct.pack(">HHIH", mdns.A, 0x8001, 120, 4) + socket.inet_aton("192.168.77.1")
    return packet + extra


class Questions(unittest.TestCase):
    def test_a_browse_asks_for_the_types_ptr(self):
        packet = mdns.question(SERVICE + ".local", mdns.PTR)
        self.assertEqual(packet[:12], struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0))
        self.assertEqual(packet[12:], b"\x09_origaitv\x04_tcp\x05local\x00" + struct.pack(">HH", 12, 1))

    def test_a_dot_in_an_instances_name_stays_in_its_label(self):
        self.assertEqual(mdns.split("living\\.room tv._origaitv._tcp.local"), ["living.room tv", "_origaitv", "_tcp", "local"])
        self.assertEqual(mdns.encode("origaitv #2._origaitv._tcp.local")[:12], b"\x0borigaitv #2")


class Answers(unittest.TestCase):
    def test_an_answer_gives_the_name_the_port_the_txt_and_the_address(self):
        found = mdns.instances(mdns.records(answer()), SERVICE)
        self.assertEqual(found, [{"name": "origaitv", "host": "origaitv.local", "port": 3001, "txt": [f"id={ID}", "version=1.0.0.r7.gabc1234"], "addresses": ["192.168.77.1"]}])

    def test_a_second_tv_with_the_same_name_is_its_own_instance(self):
        found = mdns.instances(mdns.records(answer()) + mdns.records(answer("origaitv #2")), SERVICE)
        self.assertEqual([one["name"] for one in found], ["origaitv", "origaitv #2"])

    def test_the_same_answer_heard_twice_is_one_instance(self):
        found = mdns.instances(mdns.records(answer()) * 2, SERVICE)
        self.assertEqual(len(found), 1)
        self.assertEqual(len(found[0]["txt"]), 2)
        self.assertEqual(found[0]["addresses"], ["192.168.77.1"])

    def test_another_types_records_are_not_the_tvs(self):
        other = answer().replace(b"_origaitv", b"_printers")
        self.assertEqual(mdns.instances(mdns.records(other), SERVICE), [])

    def test_a_question_is_not_an_answer(self):
        self.assertEqual(mdns.records(mdns.question(SERVICE + ".local", mdns.PTR)), [])
        self.assertEqual(mdns.records(b""), [])

    def test_the_next_questions_are_the_instances_port_txt_and_address(self):
        ptr_only = answer()[: 12 + len(mdns.encode(SERVICE + ".local")) + 10 + len(b"\x08origaitv") + 2]
        ptr_only = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0) + ptr_only[12:]
        found = mdns.records(ptr_only)
        self.assertEqual(mdns.instances(found, SERVICE), [{"name": "origaitv", "host": None, "port": None, "txt": [], "addresses": []}])
        self.assertEqual(mdns.follow_up(found, SERVICE), [("origaitv._origaitv._tcp.local", mdns.SRV), ("origaitv._origaitv._tcp.local", mdns.TXT)])
        self.assertIn(("origaitv.local", mdns.A), mdns.follow_up(mdns.records(answer()), SERVICE))

    def test_a_broken_packet_is_refused_not_followed_forever(self):
        loop = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0) + struct.pack(">H", 0xC00C) + struct.pack(">HHIH", mdns.PTR, 1, 10, 0)
        with self.assertRaises(ValueError):
            mdns.records(loop)
        with self.assertRaises((ValueError, struct.error)):
            mdns.records(answer()[:-3] + b"\xff")


if __name__ == "__main__":
    unittest.main()
