#!/usr/bin/env python3
"""
Standalone KasmVNC Secure Audio WebSocket Relay (RFC 6455)
Streams raw stereo PCM (s16le, 44100Hz) from PulseAudio auto_null.monitor
to HTML5 Web Audio API clients over WSS (TLS/HTTPS).
"""

import asyncio
import base64
import hashlib
import os
import signal
import ssl
import struct
import sys
import urllib.parse

PORT = int(os.environ.get("AUDIO_PORT", "4901"))
CERT_FILE = os.environ.get("CERT_FILE", "/config/kasmvnc/certs/kasmvnc.pem")
KEY_FILE = os.environ.get("KEY_FILE", "/config/kasmvnc/certs/kasmvnc.key")
KASM_AUTH_ENABLED = os.environ.get("KASM_AUTH_ENABLED", "false").lower() == "true"
KASMPASSWD_FILE = os.environ.get("KASMPASSWD_FILE", "/config/.kasmpasswd")
PULSE_SOURCE = os.environ.get("PULSE_SOURCE", "auto_null.monitor")

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

connected_clients = set()
audio_subproc = None

def get_allowed_credentials():
    """Reads allowed user:hash or user:password from .kasmpasswd."""
    if not os.path.isfile(KASMPASSWD_FILE):
        return {}
    users = {}
    try:
        with open(KASMPASSWD_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(":", 1)
                if len(parts) == 2:
                    users[parts[0]] = parts[1]
    except Exception as e:
        print(f"[audio-relay] Error reading {KASMPASSWD_FILE}: {e}", file=sys.stderr)
    return users

def check_auth(headers):
    """Validates HTTP Basic Auth header if authentication is enabled."""
    if not KASM_AUTH_ENABLED:
        return True
    auth_header = headers.get("authorization", "")
    if not auth_header.startswith("Basic "):
        return False
    try:
        raw = base64.b64decode(auth_header[6:]).decode("utf-8")
        user, pwd = raw.split(":", 1)
        expected_user = os.environ.get("KASM_USER", "brave")
        expected_pwd = os.environ.get("KASM_PASSWORD", "")
        if expected_pwd:
            return user == expected_user and pwd == expected_pwd
        allowed = get_allowed_credentials()
        return user in allowed
    except Exception:
        return False

def make_ws_accept(key: str) -> str:
    combined = key.strip() + WS_GUID
    hashed = hashlib.sha1(combined.encode("utf-8")).digest()
    return base64.b64encode(hashed).decode("utf-8")

def encode_ws_binary_frame(data: bytes) -> bytes:
    """Encodes binary data into an unmasked RFC 6455 server-to-client frame (opcode 0x02)."""
    length = len(data)
    if length <= 125:
        header = struct.pack("!BB", 0x82, length)
    elif length <= 65535:
        header = struct.pack("!BBH", 0x82, 126, length)
    else:
        header = struct.pack("!BBQ", 0x82, 127, length)
    return header + data

async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info("peername")
    headers = {}
    request_line = await reader.readline()
    if not request_line:
        writer.close()
        return

    # Read HTTP headers
    while True:
        line = await reader.readline()
        if not line or line == b"\r\n" or line == b"\n":
            break
        decoded = line.decode("utf-8", errors="replace").strip()
        if ":" in decoded:
            k, v = decoded.split(":", 1)
            headers[k.lower().strip()] = v.strip()

    # Check authentication
    if not check_auth(headers):
        res = (
            b"HTTP/1.1 401 Unauthorized\r\n"
            b"WWW-Authenticate: Basic realm=\"Kasm Audio\"\r\n"
            b"Content-Length: 12\r\n"
            b"\r\n"
            b"Unauthorized"
        )
        writer.write(res)
        await writer.drain()
        writer.close()
        return

    ws_key = headers.get("sec-websocket-key")
    if not ws_key:
        # Simple HTTP health endpoint
        res = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 15\r\n\r\nKasm Audio Live"
        writer.write(res)
        await writer.drain()
        writer.close()
        return

    # Send WebSocket handshake response
    accept_key = make_ws_accept(ws_key)
    handshake = (
        f"HTTP/1.1 101 Switching Protocols\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept_key}\r\n"
        f"\r\n"
    ).encode("utf-8")
    writer.write(handshake)
    await writer.drain()

    connected_clients.add(writer)
    print(f"[audio-relay] Client connected from {peer}. Total active: {len(connected_clients)}")

    try:
        while True:
            head = await reader.read(2)
            if not head or len(head) < 2:
                break
            b1, b2 = head[0], head[1]
            opcode = b1 & 0x0F
            masked = (b2 & 0x80) != 0
            payload_len = b2 & 0x7F

            if payload_len == 126:
                ext = await reader.read(2)
                if len(ext) < 2:
                    break
                payload_len = struct.unpack("!H", ext)[0]
            elif payload_len == 127:
                ext = await reader.read(8)
                if len(ext) < 8:
                    break
                payload_len = struct.unpack("!Q", ext)[0]

            mask = b""
            if masked:
                mask = await reader.read(4)
                if len(mask) < 4:
                    break

            payload = await reader.read(payload_len) if payload_len > 0 else b""

            if opcode == 0x08:  # Close frame
                break
            elif opcode == 0x09:  # Ping -> Pong
                pong = bytes([0x8A, len(payload)]) + payload
                writer.write(pong)
                await writer.drain()
    except Exception:
        pass
    finally:
        connected_clients.discard(writer)
        print(f"[audio-relay] Client disconnected {peer}. Total active: {len(connected_clients)}")
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass

async def pulse_capture_loop():
    """Captures PulseAudio stream and broadcasts to all connected WebSocket clients."""
    chunk_size = 4096  # ~23ms at 44100Hz 16-bit stereo (4 bytes/sample -> 1024 samples)
    while True:
        if not connected_clients:
            await asyncio.sleep(0.2)
            continue

        cmd = [
            "parec",
            f"-d", PULSE_SOURCE,
            "--rate=44100",
            "--channels=2",
            "--format=s16le",
            "--latency-msec=30"
        ]

        try:
            print(f"[audio-relay] Starting parec capture on {PULSE_SOURCE}...")
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL
            )
            
            while connected_clients and proc.returncode is None:
                chunk = await proc.stdout.read(chunk_size)
                if not chunk:
                    break
                frame = encode_ws_binary_frame(chunk)
                to_remove = []
                for writer in list(connected_clients):
                    try:
                        writer.write(frame)
                    except Exception:
                        to_remove.append(writer)
                for w in to_remove:
                    connected_clients.discard(w)
                    try:
                        w.close()
                    except Exception:
                        pass
                await asyncio.sleep(0)

            if proc.returncode is None:
                try:
                    proc.terminate()
                    await proc.wait()
                except Exception:
                    pass
        except Exception as e:
            print(f"[audio-relay] Capture error: {e}", file=sys.stderr)
            await asyncio.sleep(1)

async def main():
    ssl_ctx = None
    if os.path.isfile(CERT_FILE) and os.path.isfile(KEY_FILE):
        ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_ctx.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        print(f"[audio-relay] Loaded SSL certificate: {CERT_FILE}")
    else:
        print(f"[audio-relay] Warning: SSL certificate not found at {CERT_FILE}, running plain WS")

    server = await asyncio.start_server(
        handle_client,
        "0.0.0.0",
        PORT,
        ssl=ssl_ctx
    )
    print(f"[audio-relay] Listening on port {PORT} (SSL={'Enabled' if ssl_ctx else 'Disabled'})")

    capture_task = asyncio.create_task(pulse_capture_loop())
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        pass
