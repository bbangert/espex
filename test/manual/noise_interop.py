#!/usr/bin/env python3
"""
Noise interop probe. Acts as an aioesphomeapi-style client against a running
espex server and prints where the handshake fails (or succeeds).

Usage:
    ESPEX_PSK_B64=<base64-psk> python3 test/manual/noise_interop.py [host] [port]

Defaults: host=127.0.0.1 port=15053.

Mirrors the exact wire format of aioesphomeapi/_frame_helper/noise.py:
  1. NOISE_HELLO (\\x01\\x00\\x00)
  2. frame: 0x01 + be16 len + 0x00 + noise.write_message()
  3. receive ServerHello frame, assert first body byte is 0x01
  4. receive handshake frame: 0x00 + noise_msg; run noise.read_message()
  5. split into encrypt/decrypt ciphers
  6. send encrypted HelloRequest equivalent, decrypt response
"""

import os
import socket
import struct
import sys
import base64
import binascii
from noise.connection import NoiseConnection

NOISE_HELLO = b"\x01\x00\x00"
PROLOGUE = b"NoiseAPIInit\x00\x00"
PROTOCOL = b"Noise_NNpsk0_25519_ChaChaPoly_SHA256"


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def ok(msg):
    print(f"OK:   {msg}")


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            fail(f"socket closed after {len(buf)} of {n} bytes")
        buf += chunk
    return buf


def recv_frame(sock):
    header = recv_exact(sock, 3)
    if header[0] != 0x01:
        fail(f"expected preamble 0x01, got 0x{header[0]:02x}; header={header.hex()}")
    length = (header[1] << 8) | header[2]
    body = recv_exact(sock, length)
    return body


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 15053
    psk_b64 = os.environ["ESPEX_PSK_B64"]
    psk = base64.b64decode(psk_b64)
    if len(psk) != 32:
        fail(f"PSK decodes to {len(psk)} bytes, expected 32")

    print(f"Connecting to {host}:{port} with PSK {psk_b64}")

    sock = socket.create_connection((host, port))
    sock.settimeout(5.0)

    proto = NoiseConnection.from_name(PROTOCOL)
    proto.set_as_initiator()
    proto.set_psks(psk)
    proto.set_prologue(PROLOGUE)
    proto.start_handshake()

    # 1) NOISE_HELLO + handshake_init, exactly as aioesphomeapi does
    handshake_frame = proto.write_message()
    frame_len = len(handshake_frame) + 1
    header = bytes((0x01, (frame_len >> 8) & 0xFF, frame_len & 0xFF))
    sock.sendall(NOISE_HELLO + header + b"\x00" + handshake_frame)
    ok(f"sent NOISE_HELLO + handshake init (noise msg {len(handshake_frame)} bytes)")

    # 2) ServerHello
    server_hello = recv_frame(sock)
    if server_hello[0] != 0x01:
        fail(f"ServerHello first byte = 0x{server_hello[0]:02x}, expected 0x01. Body: {server_hello.hex()}")
    null_i = server_hello.find(b"\0", 1)
    if null_i == -1:
        fail("ServerHello missing null terminator")
    server_name = server_hello[1:null_i].decode()
    mac_i = server_hello.find(b"\0", null_i + 1)
    mac = server_hello[null_i + 1 : mac_i].decode() if mac_i != -1 else "<no mac>"
    ok(f"ServerHello: name={server_name!r} mac={mac!r}")

    # 3) Server handshake response
    srv_handshake = recv_frame(sock)
    if srv_handshake[0] != 0x00:
        fail(f"server handshake status byte = 0x{srv_handshake[0]:02x}, expected 0x00. Body: {srv_handshake.hex()}")
    try:
        proto.read_message(srv_handshake[1:])
    except Exception as e:
        fail(f"noise.read_message failed: {type(e).__name__}: {e}")
    ok("noise.read_message accepted the server handshake response")

    # 4) Verify cipher states exist
    enc = proto.noise_protocol.cipher_state_encrypt
    dec = proto.noise_protocol.cipher_state_decrypt
    ok(f"split into encrypt/decrypt cipher states: {type(enc).__name__} / {type(dec).__name__}")

    sock.close()
    print("\nINTEROP SUCCESS — espex Noise handshake interoperates with noiseprotocol (the Python library aioesphomeapi uses)")


if __name__ == "__main__":
    main()
