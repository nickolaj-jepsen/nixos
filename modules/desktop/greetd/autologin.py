"""greetd greeter that starts a session without a prompt when PAM can
authenticate silently, and otherwise execs the real greeter.

Usage: greetd-autologin USER SESSION-CMD... -- GREETER-CMD...
"""

import json
import os
import socket
import struct
import sys


def autologin(user, cmd):
    """Return True once greetd has accepted SESSION-CMD for USER."""
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(os.environ["GREETD_SOCK"])
        conn = sock.makefile("rwb")

        def call(request):
            body = json.dumps(request).encode()
            conn.write(struct.pack("=I", len(body)) + body)
            conn.flush()
            (length,) = struct.unpack("=I", conn.read(4))
            return json.loads(conn.read(length))

        resp = call({"type": "create_session", "username": user})
        # Info/error lines need no answer; a real prompt means PAM had no
        # cached LUKS passphrase (or it didn't match), so a human must type.
        while (resp["type"] == "auth_message"
               and resp["auth_message_type"] in ("info", "error")):
            resp = call({"type": "post_auth_message_response"})
        if resp["type"] == "success":
            start = {"type": "start_session", "cmd": cmd, "env": []}
            if call(start)["type"] == "success":
                return True
        call({"type": "cancel_session"})
        return False


def main():
    args = sys.argv[1:]
    sep = args.index("--")
    user, cmd, greeter = args[0], args[1:sep], args[sep + 1:]
    try:
        if autologin(user, cmd):
            return
    except Exception as e:  # never leave the seat without a greeter
        print(f"greetd-autologin: {e}", file=sys.stderr)
    os.execvp(greeter[0], greeter)


main()
