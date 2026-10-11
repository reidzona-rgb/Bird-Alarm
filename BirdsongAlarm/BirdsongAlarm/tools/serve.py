#!/usr/bin/env python3
"""Serve the web app to your phone over Wi-Fi.

    python3 tools/serve.py          (Windows: python tools\\serve.py)

Prints the address to type into Safari on the iPhone. Both devices must be
on the same Wi-Fi network. Press Ctrl+C to stop.
"""
import functools
import http.server
import os
import socket
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def lan_address():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("10.255.255.255", 1))   # no packets are sent; this just picks the Wi-Fi interface
        return probe.getsockname()[0]
    except OSError:
        return None
    finally:
        probe.close()


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # Always hand the phone the newest files while you are still changing things.
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass


def main():
    handler = functools.partial(Handler, directory=ROOT)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), handler)
    address = lan_address()
    print("Birdsong Alarm is being served.\n")
    print(f"  On this computer : http://localhost:{PORT}")
    if address:
        print(f"  On your iPhone   : http://{address}:{PORT}")
    else:
        print("  Could not detect a Wi-Fi address. Check that this computer is on Wi-Fi.")
    print("\nIf the phone cannot connect, allow Python through the firewall for private networks.")
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
