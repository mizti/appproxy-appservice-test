"""Connection status page for App Proxy + App Service verification."""
import base64
import binascii
import json
from datetime import datetime, timezone
from html import escape

from flask import Flask, request

app = Flask(__name__)


def _header(name: str, fallback: str = "未取得") -> str:
    return escape(request.headers.get(name, fallback))


def _decode_jwt_claims(token: str) -> dict | None:
    parts = token.split(".")
    if len(parts) != 3:
        return None

    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
    except (binascii.Error, ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None

    return claims if isinstance(claims, dict) else None


def _format_claim_value(name: str, value: object) -> str:
    if name in {"auth_time", "exp", "iat", "nbf"} and isinstance(value, (int, float)):
        try:
            timestamp = datetime.fromtimestamp(value, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
            return escape(f"{value} ({timestamp})")
        except (OverflowError, OSError, ValueError):
            pass
    if isinstance(value, (dict, list)):
        return escape(json.dumps(value, ensure_ascii=False, sort_keys=True))
    if value is None:
        return "null"
    return escape(str(value))


def _render_jwt_claims() -> str:
    token_sources = (
        ("X-Ms-Token-Aad-Id-Token", "Easy Auth ID token"),
        ("X-Ms-Token-Aad-Access-Token", "Easy Auth access token"),
        ("Authorization", "Authorization bearer token"),
    )
    token_tables = []

    for header_name, display_name in token_sources:
        token = request.headers.get(header_name, "")
        if header_name == "Authorization":
            scheme, separator, credential = token.partition(" ")
            token = credential if separator and scheme.lower() == "bearer" else ""

        claims = _decode_jwt_claims(token) if token else None
        if not claims:
            continue

        rows = "".join(
            f'<tr><th scope="row">{escape(str(name))}</th><td>{_format_claim_value(str(name), value)}</td></tr>'
            for name, value in sorted(claims.items())
        )
        token_tables.append(
            f"""<div class="token-claims">
                <h3>{display_name}</h3>
                <p class="token-source">Source: <code>{header_name}</code></p>
                <div class="table-scroll">
                    <table>
                        <thead><tr><th scope="col">Claim</th><th scope="col">Value</th></tr></thead>
                        <tbody>{rows}</tbody>
                    </table>
                </div>
            </div>"""
        )

    if not token_tables:
        return ""

    return f"""<section class="claims-section">
        <h2>JWT claims</h2>
        <p class="claims-intro">JWT本体と署名は表示せず、デバッグ用にpayloadのclaimだけを表示しています。</p>
        {''.join(token_tables)}
    </section>"""


def _render_status_page() -> str:
    raw_principal_name = request.headers.get("X-Ms-Client-Principal-Name")
    principal_name = escape(raw_principal_name) if raw_principal_name else "未取得"
    auth_status = "認証済み" if raw_principal_name else "確認できません"
    auth_status_class = "value ok" if raw_principal_name else "value"
    identity_provider = _header("X-Ms-Client-Principal-Idp")
    app_proxy_header = request.headers.get("X-Ms-Proxy", "")
    route_name = "Microsoft Entra Application Proxy" if app_proxy_header else "Connector VM からの直接確認"
    route_detail = "App Proxy 経由" if app_proxy_header else "App Service のプライベート接続"
    request_path = escape(request.full_path.rstrip("?") or "/")
    jwt_claims = _render_jwt_claims()

    return f"""<!doctype html>
<html lang="ja">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>接続に成功しました</title>
    <style>
        :root {{
            color-scheme: light;
            --ink: #17322b;
            --muted: #586a65;
            --line: #c8d8d1;
            --surface: #ffffff;
            --success: #087f5b;
            --success-dark: #075f48;
            --success-soft: #dff5ea;
            --accent: #e4a11b;
        }}
        * {{ box-sizing: border-box; }}
        body {{
            margin: 0;
            min-height: 100vh;
            color: var(--ink);
            font-family: "IBM Plex Sans", "Noto Sans JP", sans-serif;
            background-color: #edf3f0;
            background-image:
                linear-gradient(rgba(23, 50, 43, 0.045) 1px, transparent 1px),
                linear-gradient(90deg, rgba(23, 50, 43, 0.045) 1px, transparent 1px);
            background-size: 28px 28px;
        }}
        main {{
            width: min(920px, calc(100% - 32px));
            margin: 0 auto;
            padding: 56px 0;
        }}
        .status {{
            border-top: 6px solid var(--success);
            border-bottom: 1px solid var(--line);
            background: var(--surface);
            padding: 38px 40px 34px;
        }}
        .eyebrow {{
            display: flex;
            align-items: center;
            gap: 10px;
            margin: 0 0 18px;
            color: var(--success-dark);
            font-size: 14px;
            font-weight: 700;
        }}
        .check {{
            display: inline-grid;
            width: 26px;
            height: 26px;
            place-items: center;
            border-radius: 50%;
            color: #fff;
            background: var(--success);
            font-size: 17px;
        }}
        h1 {{
            margin: 0;
            max-width: 700px;
            font-size: clamp(34px, 6vw, 58px);
            line-height: 1.08;
            letter-spacing: 0;
        }}
        .lead {{
            max-width: 660px;
            margin: 18px 0 0;
            color: var(--muted);
            font-size: 17px;
            line-height: 1.75;
        }}
        .summary {{
            display: grid;
            grid-template-columns: repeat(3, minmax(0, 1fr));
            border: 1px solid var(--line);
            border-top: 0;
            background: var(--surface);
        }}
        .summary-item {{
            min-width: 0;
            padding: 24px;
            border-right: 1px solid var(--line);
        }}
        .summary-item:last-child {{ border-right: 0; }}
        .label {{
            display: block;
            margin-bottom: 8px;
            color: var(--muted);
            font-size: 12px;
            font-weight: 700;
            text-transform: uppercase;
        }}
        .value {{
            display: block;
            overflow-wrap: anywhere;
            font-size: 16px;
            font-weight: 700;
            line-height: 1.45;
        }}
        .ok {{ color: var(--success-dark); }}
        section {{
            margin-top: 24px;
            border: 1px solid var(--line);
            background: var(--surface);
            padding: 28px 32px;
        }}
        h2 {{
            margin: 0 0 18px;
            font-size: 19px;
            letter-spacing: 0;
        }}
        dl {{
            display: grid;
            grid-template-columns: minmax(150px, 0.8fr) minmax(0, 2fr);
            gap: 0;
            margin: 0;
        }}
        dt, dd {{
            margin: 0;
            padding: 13px 0;
            border-top: 1px solid #e7eeeb;
            overflow-wrap: anywhere;
        }}
        dt {{ color: var(--muted); font-size: 14px; }}
        dd {{ font-family: "IBM Plex Mono", "Cascadia Code", monospace; font-size: 14px; }}
        .claims-intro {{
            margin: -8px 0 24px;
            color: var(--muted);
            font-size: 14px;
            line-height: 1.65;
        }}
        .token-claims + .token-claims {{
            margin-top: 30px;
            padding-top: 26px;
            border-top: 1px solid var(--line);
        }}
        h3 {{ margin: 0; font-size: 16px; letter-spacing: 0; }}
        .token-source {{
            margin: 7px 0 14px;
            color: var(--muted);
            font-size: 12px;
        }}
        .token-source code {{ font-family: "IBM Plex Mono", "Cascadia Code", monospace; }}
        .table-scroll {{ max-width: 100%; overflow-x: auto; }}
        table {{ width: 100%; border-collapse: collapse; table-layout: fixed; }}
        th, td {{
            padding: 11px 12px;
            border: 1px solid #dbe5e1;
            text-align: left;
            vertical-align: top;
            overflow-wrap: anywhere;
            font-size: 13px;
            line-height: 1.5;
        }}
        thead th {{ color: var(--muted); background: #f3f7f5; font-size: 12px; }}
        th:first-child {{ width: 28%; }}
        tbody th {{ font-family: "IBM Plex Mono", "Cascadia Code", monospace; font-weight: 600; }}
        tbody td {{ font-family: "IBM Plex Mono", "Cascadia Code", monospace; }}
        .note {{
            margin: 18px 0 0;
            padding-left: 14px;
            border-left: 3px solid var(--accent);
            color: var(--muted);
            font-size: 13px;
            line-height: 1.65;
        }}
        @media (max-width: 700px) {{
            main {{ padding: 24px 0; }}
            .status {{ padding: 30px 24px; }}
            h1 {{ font-size: 30px; }}
            .summary {{ grid-template-columns: 1fr; }}
            .summary-item {{ border-right: 0; border-bottom: 1px solid var(--line); }}
            .summary-item:last-child {{ border-bottom: 0; }}
            section {{ padding: 24px; }}
            dl {{ grid-template-columns: 1fr; }}
            dt {{ padding-bottom: 4px; }}
            dd {{ padding-top: 0; border-top: 0; }}
            th, td {{ padding: 9px 8px; font-size: 12px; }}
            th:first-child {{ width: 38%; }}
        }}
    </style>
</head>
<body>
    <main>
        <header class="status">
            <p class="eyebrow"><span class="check" aria-hidden="true">&#10003;</span> CONNECTION ESTABLISHED</p>
            <h1>接続に成功しました</h1>
            <p class="lead">Azure App Service がリクエストを受信し、Microsoft Entra ID による認証情報を確認できました。</p>
        </header>

        <div class="summary" aria-label="接続結果">
            <div class="summary-item">
                <span class="label">App Service</span>
                <span class="value ok">到達成功</span>
            </div>
            <div class="summary-item">
                <span class="label">Easy Auth</span>
                <span class="{auth_status_class}">{auth_status}</span>
            </div>
            <div class="summary-item">
                <span class="label">Connection</span>
                <span class="value">{route_detail}</span>
            </div>
        </div>

        <section>
            <h2>接続情報</h2>
            <dl>
                <dt>サインインユーザー</dt><dd>{principal_name}</dd>
                <dt>Identity Provider</dt><dd>{identity_provider}</dd>
                <dt>経路</dt><dd>{route_name}</dd>
                <dt>Host</dt><dd>{_header("Host")}</dd>
                <dt>Client IP</dt><dd>{_header("X-Forwarded-For")}</dd>
                <dt>Request</dt><dd>{escape(request.method)} {request_path}</dd>
                <dt>Request ID</dt><dd>{_header("X-Arr-Log-Id")}</dd>
            </dl>
            <p class="note">CookieやJWT本体などの機密ヘッダーは表示していません。JWTがある場合はpayloadのclaimだけを下に表示します。</p>
        </section>
        {jwt_claims}
    </main>
</body>
</html>"""


@app.route("/healthz", methods=["GET"])
def healthz():
    return "ok\n", 200, {"Content-Type": "text/plain; charset=utf-8"}


@app.route("/", defaults={"path": ""}, methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
@app.route("/<path:path>", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
def echo(path: str):
    return _render_status_page(), 200, {"Content-Type": "text/html; charset=utf-8"}


if __name__ == "__main__":
    import os

    port = int(os.environ.get("PORT", "8000"))
    app.run(host="0.0.0.0", port=port)
