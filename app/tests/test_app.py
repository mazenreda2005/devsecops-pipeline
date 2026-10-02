import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import app  # noqa: E402


def test_health():
    resp = app.test_client().get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_security_headers_present():
    resp = app.test_client().get("/")
    for header in ("X-Content-Type-Options", "X-Frame-Options",
                   "Content-Security-Policy", "Strict-Transport-Security"):
        assert header in resp.headers
