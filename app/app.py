"""Tiny demo API that the pipeline builds, scans and ships."""

import os

from flask import Flask, jsonify

app = Flask(__name__)


@app.after_request
def security_headers(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Content-Security-Policy"] = "default-src 'none'"
    resp.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    resp.headers["Referrer-Policy"] = "no-referrer"
    return resp


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.get("/")
def index():
    return jsonify(service="devsecops-demo", version=os.environ.get("APP_VERSION", "dev"))


if __name__ == "__main__":
    # Local development only; production runs under gunicorn (see Dockerfile).
    app.run(host="127.0.0.1", port=8080)
