#!/usr/bin/env python3
"""Local FTPS server for test/large-deploy.sh. Logs every finished upload and delete to a file."""
import os
import sys
import time

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import TLS_FTPHandler
from pyftpdlib.servers import FTPServer

root, port, cert, log_path = os.path.realpath(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]


class Handler(TLS_FTPHandler):
    certfile = cert
    tls_control_required = True
    tls_data_required = True
    banner = "test server"

    def _log(self, line):
        with open(log_path, "a", encoding="utf-8") as out:
            out.write(line + "\n")

    def on_file_received(self, file):
        # Lets the test slow uploads down, so a short time budget always runs out partway.
        if os.path.exists(log_path + ".slow"):
            time.sleep(0.02)
        self._log("STOR " + file[len(root):].lstrip("/"))

    def ftp_RNFR(self, path):
        # Lets the test check the fallback for a server that refuses renames.
        if os.path.exists(log_path + ".refuse-rename"):
            self.respond("550 Rename refused.")
            return None
        return super().ftp_RNFR(path)

    def ftp_DELE(self, path):
        self._log("DELE " + path[len(root):].lstrip("/"))
        return super().ftp_DELE(path)


auth = DummyAuthorizer()
auth.add_user("deploy", "pa\"ss\\word", root, perm="elradfmwMT")
Handler.authorizer = auth
FTPServer(("127.0.0.1", port), Handler).serve_forever()
