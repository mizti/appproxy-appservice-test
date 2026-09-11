import base64
import json
import unittest

from app import app


def _jwt(claims):
    def encode(value):
        payload = json.dumps(value, separators=(",", ":")).encode()
        return base64.urlsafe_b64encode(payload).rstrip(b"=").decode()

    return f"{encode({'alg': 'RS256', 'typ': 'JWT'})}.{encode(claims)}.SIGNATURE_MUST_NOT_RENDER"


class StatusPageTests(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_status_page_shows_safe_connection_details(self):
        response = self.client.get(
            "/",
            headers={
                "X-Ms-Client-Principal-Name": "admin@example.com",
                "X-Ms-Client-Principal-Idp": "aad",
                "X-Forwarded-For": "10.10.1.4",
                "X-Arr-Log-Id": "request-id",
            },
        )

        body = response.get_data(as_text=True)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content_type, "text/html; charset=utf-8")
        self.assertIn("接続に成功しました", body)
        self.assertIn("認証済み", body)
        self.assertIn("admin@example.com", body)
        self.assertIn("10.10.1.4", body)

    def test_missing_easy_auth_header_is_not_reported_as_authenticated(self):
        response = self.client.get("/")

        body = response.get_data(as_text=True)
        self.assertIn("確認できません", body)
        self.assertNotIn(">認証済み<", body)

    def test_status_page_does_not_render_credentials(self):
        self.client.set_cookie("AppServiceAuthSession", "COOKIE_SECRET")
        response = self.client.get(
            "/",
            headers={
                "Authorization": "Bearer AUTHORIZATION_SECRET",
                "X-Ms-Token-Aad-Access-Token": "ACCESS_TOKEN_SECRET",
                "X-Ms-Token-Aad-Id-Token": "ID_TOKEN_SECRET",
                "X-Ms-Client-Principal": "PRINCIPAL_TOKEN_SECRET",
            },
        )

        body = response.get_data(as_text=True)
        for secret in (
            "COOKIE_SECRET",
            "AUTHORIZATION_SECRET",
            "ACCESS_TOKEN_SECRET",
            "ID_TOKEN_SECRET",
            "PRINCIPAL_TOKEN_SECRET",
        ):
            self.assertNotIn(secret, body)

    def test_jwt_payload_claims_are_rendered_without_raw_token(self):
        token = _jwt(
            {
                "aud": "example-client-id",
                "exp": 1789032087,
                "name": "Debug User",
                "roles": ["Reader", "Writer"],
                "unsafe": "<admin>",
            }
        )
        response = self.client.get(
            "/",
            headers={"X-Ms-Token-Aad-Id-Token": token},
        )

        body = response.get_data(as_text=True)
        self.assertIn("JWT claims", body)
        self.assertIn("Easy Auth ID token", body)
        self.assertIn("example-client-id", body)
        self.assertIn("Debug User", body)
        self.assertIn("Reader", body)
        self.assertIn("&lt;admin&gt;", body)
        self.assertNotIn(token, body)
        self.assertNotIn("SIGNATURE_MUST_NOT_RENDER", body)

    def test_non_jwt_token_header_is_not_rendered(self):
        response = self.client.get(
            "/",
            headers={"X-Ms-Token-Aad-Access-Token": "NOT_A_JWT_SECRET"},
        )

        body = response.get_data(as_text=True)
        self.assertNotIn("NOT_A_JWT_SECRET", body)
        self.assertNotIn("Easy Auth access token", body)

    def test_out_of_range_timestamp_claim_remains_displayable(self):
        token = _jwt({"exp": 10**30})
        response = self.client.get(
            "/",
            headers={"X-Ms-Token-Aad-Id-Token": token},
        )

        self.assertEqual(response.status_code, 200)
        self.assertIn(str(10**30), response.get_data(as_text=True))

    def test_status_page_escapes_header_values(self):
        response = self.client.get(
            "/",
            headers={"X-Ms-Client-Principal-Name": "<script>alert(1)</script>"},
        )

        body = response.get_data(as_text=True)
        self.assertNotIn("<script>alert(1)</script>", body)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", body)

    def test_app_proxy_header_changes_route_label(self):
        response = self.client.get(
            "/",
            headers={"X-Ms-Proxy": "AzureAD-Application-Proxy"},
        )

        body = response.get_data(as_text=True)
        self.assertIn("Microsoft Entra Application Proxy", body)
        self.assertIn("App Proxy 経由", body)

    def test_health_endpoint_remains_plain_text(self):
        response = self.client.get("/healthz")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_data(as_text=True), "ok\n")


if __name__ == "__main__":
    unittest.main()