"""Локальный сервер для build/web с заголовками изоляции.

COOP/COEP включают crossOriginIsolated → skwasm получает
SharedArrayBuffer и рисует многопоточно (плавный скролл).
"""

import http.server
import functools

ROOT = "build/web"


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(
        ("127.0.0.1", 8080),
        functools.partial(Handler, directory=ROOT),
    ).serve_forever()
