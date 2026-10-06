"""Локальный сервер для build/web: заголовки изоляции + gzip.

COOP/COEP включают crossOriginIsolated → skwasm получает
SharedArrayBuffer и рисует многопоточно (плавный скролл).
gzip для .wasm/.js/.json/.ttf заметно режет трафик
(main.dart.wasm 2.6M→~1M, strongs.json 3.6M→~400K).
"""

import gzip
import http.server
import functools
import os

ROOT = "build/web"
COMPRESSIBLE = {".wasm", ".js", ".mjs", ".json", ".ttf", ".otf", ".html", ".css"}


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def send_head(self):
        path = self.translate_path(self.path)
        if (
            os.path.isfile(path)
            and os.path.splitext(path)[1] in COMPRESSIBLE
            and os.path.getsize(path) > 4096
            and "gzip" in self.headers.get("Accept-Encoding", "")
        ):
            with open(path, "rb") as f:
                body = gzip.compress(f.read(), compresslevel=6)
            self.send_response(200)
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            import io
            return io.BytesIO(body)
        return super().send_head()


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(
        ("127.0.0.1", 8080),
        functools.partial(Handler, directory=ROOT),
    ).serve_forever()
