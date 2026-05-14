"""Echo stub app for App Proxy + App Service verification.

Returns request method, path, query string, headers, and body in the response body
as plain text. Useful to confirm what headers are propagated through App Proxy /
Easy Auth.
"""
from flask import Flask, request

app = Flask(__name__)


def _format_request() -> str:
    lines = []
    lines.append(f"{request.method} {request.full_path}")
    lines.append("")
    lines.append("=== Headers ===")
    for name, value in request.headers.items():
        lines.append(f"{name}: {value}")
    lines.append("")
    lines.append("=== Body ===")
    try:
        body = request.get_data(as_text=True)
    except Exception as exc:  # pragma: no cover
        body = f"<failed to read body: {exc}>"
    lines.append(body if body else "<empty>")
    return "\n".join(lines) + "\n"


@app.route("/healthz", methods=["GET"])
def healthz():
    return "ok\n", 200, {"Content-Type": "text/plain; charset=utf-8"}


@app.route("/", defaults={"path": ""}, methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
@app.route("/<path:path>", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
def echo(path: str):
    return _format_request(), 200, {"Content-Type": "text/plain; charset=utf-8"}


if __name__ == "__main__":
    import os

    port = int(os.environ.get("PORT", "8000"))
    app.run(host="0.0.0.0", port=port)
