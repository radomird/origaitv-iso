#!/usr/bin/env python3
#
# A phone on the home network that looks for the TV, for the image check
# (T25.1), as little of one as it needs:
#   mdns.py browse <own address> <type>
#       asks everyone on the network who has <type>, the way a phone's
#       browse does, and prints what answered as JSON
#   mdns.py ask <own address> <type> <box's address>
#       asks the box alone, straight to its address, the way a phone checks
#       a record it already has
# It runs as root in the phone's own network namespace, which has no Avahi
# of its own. <type> is written "_origaitv._tcp". What it prints is a list
# of {"name", "host", "port", "txt", "addresses"}, one for each instance that
# answered, with every TXT entry as it came.

import json
import socket
import struct
import sys
import time

GROUP, PORT = "224.0.0.251", 5353
PTR, TXT, SRV, A = 12, 16, 33, 1


def encode(name):
    """A name as it goes in a packet, with no compression."""
    out = b""
    for label in split(name):
        raw = label.encode()
        out += bytes([len(raw)]) + raw
    return out + b"\0"


def split(name):
    r"""A name's labels. A dot inside a label is written "\."."""
    labels, label, i = [], "", 0
    while i < len(name):
        if name[i] == "\\" and i + 1 < len(name):
            label += name[i + 1]
            i += 2
        elif name[i] == ".":
            labels.append(label)
            label = ""
            i += 1
        else:
            label += name[i]
            i += 1
    if label:
        labels.append(label)
    return labels


def question(name, kind, unicast=False):
    """One question, as a whole packet. `unicast` asks for the answer to come
    back to the asker alone."""
    return struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0) + encode(name) + struct.pack(">HH", kind, 0x8001 if unicast else 1)


def name_at(data, at):
    """The labels of the name at `at`, following compression, and where the
    record goes on after it."""
    labels, after, hops = [], None, 0
    while True:
        if at >= len(data):
            raise ValueError("a name runs off the end of the packet")
        length = data[at]
        if length == 0:
            at += 1
            break
        if length & 0xC0 == 0xC0:
            if at + 1 >= len(data):
                raise ValueError("a pointer runs off the end of the packet")
            if after is None:
                after = at + 2
            at = ((length & 0x3F) << 8) | data[at + 1]
            hops += 1
            if hops > 32:
                raise ValueError("a name's pointers go in a circle")
            continue
        labels.append(data[at + 1 : at + 1 + length].decode("utf-8", "replace"))
        at += 1 + length
    return labels, at if after is None else after


def records(data):
    """Every record in an answer: (labels, kind, what it holds). A PTR holds
    the labels it points at, an SRV (port, host labels), a TXT its entries,
    an A its address."""
    if len(data) < 12:
        return []
    _, flags, questions, answers, authorities, additionals = struct.unpack(">HHHHHH", data[:12])
    if not flags & 0x8000:
        return []
    at = 12
    for _ in range(questions):
        _, at = name_at(data, at)
        at += 4
    found = []
    for _ in range(answers + authorities + additionals):
        owner, at = name_at(data, at)
        kind, _, _, length = struct.unpack(">HHIH", data[at : at + 10])
        at += 10
        body = at
        at += length
        if at > len(data):
            raise ValueError("a record runs off the end of the packet")
        if kind == PTR:
            found.append((owner, kind, name_at(data, body)[0]))
        elif kind == SRV:
            port = struct.unpack(">H", data[body + 4 : body + 6])[0]
            found.append((owner, kind, (port, name_at(data, body + 6)[0])))
        elif kind == TXT:
            entries, i = [], body
            while i < body + length:
                size = data[i]
                if size:
                    entries.append(data[i + 1 : i + 1 + size].decode("utf-8", "replace"))
                i += 1 + size
            found.append((owner, kind, entries))
        elif kind == A and length == 4:
            found.append((owner, kind, socket.inet_ntoa(data[body : body + 4])))
    return found


def lower(labels):
    return tuple(label.lower() for label in labels)


def instances(found, service):
    """What the records say about each instance of the type."""
    wanted = lower(split(service) + ["local"])
    out = {}
    for owner, kind, held in found:
        if kind == PTR and lower(owner) == wanted and lower(held[1:]) == wanted:
            out.setdefault(lower(held), {"name": held[0], "host": None, "port": None, "txt": [], "addresses": []})
    for owner, kind, held in found:
        one = out.get(lower(owner))
        if one is None:
            continue
        if kind == SRV:
            one["port"], one["host"] = held[0], ".".join(held[1])
        elif kind == TXT:
            one["txt"] = sorted(set(one["txt"]) | set(held))
    for owner, kind, held in found:
        if kind != A:
            continue
        for one in out.values():
            if one["host"] and lower(split(one["host"])) == lower(owner) and held not in one["addresses"]:
                one["addresses"].append(held)
    return sorted(out.values(), key=lambda one: one["name"])


def listen(sock, seconds):
    """Every answer that comes in the next `seconds`."""
    found, until = [], time.time() + seconds
    while True:
        left = until - time.time()
        if left <= 0:
            return found
        sock.settimeout(left)
        try:
            data, _ = sock.recvfrom(9000)
        except socket.timeout:
            return found
        try:
            found += records(data)
        except (ValueError, struct.error):
            continue


def follow_up(found, service):
    """The questions a browse asks next: each instance's port and TXT, and
    its host's address."""
    asks = []
    for one in instances(found, service):
        full = one["name"].replace("\\", "\\\\").replace(".", "\\.") + "." + service + ".local"
        asks += [(full, SRV), (full, TXT)]
        if one["host"]:
            asks.append((one["host"], A))
    return asks


def browse(own, service):
    """Asks the whole network, from mDNS's own port, and hears the answers
    that go to everyone."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("", PORT))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton(GROUP) + socket.inet_aton(own))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(own))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    found = []
    for _ in range(3):
        sock.sendto(question(service + ".local", PTR), (GROUP, PORT))
        found += listen(sock, 1.5)
        for name, kind in follow_up(found, service):
            sock.sendto(question(name, kind), (GROUP, PORT))
        found += listen(sock, 1.5)
        if all(one["port"] and one["txt"] for one in instances(found, service)) and instances(found, service):
            break
    return instances(found, service)


def ask(own, service, box):
    """Asks the box alone, from a port of the moment, and takes the answer
    it sends straight back."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((own, 0))
    found = []
    for _ in range(3):
        sock.sendto(question(service + ".local", PTR), (box, PORT))
        found += listen(sock, 1.5)
        for name, kind in follow_up(found, service):
            sock.sendto(question(name, kind), (box, PORT))
        found += listen(sock, 1.5)
        if all(one["port"] and one["txt"] for one in instances(found, service)) and instances(found, service):
            break
    return instances(found, service)


def main(args):
    if len(args) == 3 and args[0] == "browse":
        print(json.dumps(browse(args[1], args[2])))
    elif len(args) == 4 and args[0] == "ask":
        print(json.dumps(ask(args[1], args[2], args[3])))
    else:
        print("usage: mdns.py browse <own address> <type> | ask <own address> <type> <box's address>", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
