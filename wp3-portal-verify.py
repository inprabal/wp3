#!/usr/bin/env python3
"""
WP3 captive portal offline verification.
Safe to run while WP3/AP is running.
Does NOT invoke the authorization script or modify networking.
"""

import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path
import sys

from flask import render_template

BASE_DIR = Path(__file__).resolve().parent
APP_FILE = BASE_DIR / "wp3-portal.py.new"

passed = 0


def check(description, condition):
    global passed
    if not condition:
        raise AssertionError(description)
    passed += 1
    print(f"[PASS] {description}")


def main():
    source = APP_FILE.read_text()
    compile(source, str(APP_FILE), "exec")
    check("Python syntax", True)

    loader = SourceFileLoader("wp3_portal_verify", str(APP_FILE))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    portal = importlib.util.module_from_spec(spec)
    loader.exec_module(portal)
    check("Application and configuration loading", True)

    # Validate both Jinja templates.
    portal.app.jinja_env.get_template("login.html")
    portal.app.jinja_env.get_template("success.html")
    check("Login and success template syntax", True)

    client = portal.app.test_client()
    client.environ_base["REMOTE_ADDR"] = "172.16.0.2"

    # Login page.
    response = client.get("/")
    check(
        "Login page renders",
        response.status_code == 200
        and portal.BRANDING["organization"].encode() in response.data
        and portal.LOGIN["heading"].encode() in response.data
    )
    check(
        "Login form and CSRF field present",
        b"<form" in response.data
        and b'name="csrf"' in response.data
    )
    check(
        "Stylesheet linked",
        b"/static/style.css" in response.data
    )

    # Static CSS.
    response = client.get("/static/style.css")
    check(
        "Static CSS delivered",
        response.status_code == 200
        and len(response.data) > 0
    )

    # Invalid CSRF must be rejected.
    response = client.post("/", data={"csrf": "invalid-test-token"})
    check("Invalid CSRF rejected", response.status_code == 403)

    # Captive portal probe.
    response = client.get("/generate_204")
    check(
        "Captive probe redirect",
        response.status_code == 302
        and response.headers.get("Location")
        == "http://172.16.0.1:8080/"
    )

    # External client rejection.
    response = client.get(
        "/",
        environ_overrides={"REMOTE_ADDR": "192.0.2.10"}
    )
    check("Outside subnet rejected", response.status_code == 403)

    # Gateway address rejection.
    response = client.get(
        "/",
        environ_overrides={"REMOTE_ADDR": "172.16.0.1"}
    )
    check("Gateway address rejected", response.status_code == 403)

    # Render success template directly; do not submit valid authorization.
    with portal.app.test_request_context("/"):
        html = render_template(
            "success.html",
            branding=portal.BRANDING,
            success=portal.SUCCESS,
            appearance=portal.APPEARANCE
        )

    check(
        "Success page renders",
        portal.SUCCESS["heading"] in html
        and portal.BRANDING["organization"] in html
    )

    print()
    print(f"All {passed} verification checks passed.")
    print("Offline test only: no client was authorized.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"\n[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
