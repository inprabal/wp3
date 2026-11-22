#!/usr/bin/env python3

from flask import Flask, request, session, redirect, url_for, render_template
from pathlib import Path
import configparser
import ipaddress
import re
import secrets
import subprocess

# Resolve all paths relative to this script.
BASE_DIR = Path(__file__).resolve().parent
PORTAL_DIR = BASE_DIR / "portal"
CONFIG_FILE = PORTAL_DIR / "config" / "portal.ini"
TEMPLATE_DIR = PORTAL_DIR / "templates"
STATIC_DIR = PORTAL_DIR / "static"

AUTH_SCRIPT = Path("/usr/local/sbin/wp3-authorize")

# Load portal configuration.
config = configparser.ConfigParser()

if not config.read(CONFIG_FILE):
    raise RuntimeError(f"Cannot read portal configuration: {CONFIG_FILE}")


def required_setting(section, key):
    if not config.has_option(section, key):
        raise RuntimeError(f"Missing configuration: [{section}] {key}")

    value = config.get(section, key).strip()
    if not value:
        raise RuntimeError(f"Empty configuration: [{section}] {key}")

    return value


# Branding settings.
BRANDING = {
    "organization": required_setting("branding", "organization"),
    "page_title": required_setting("branding", "page_title"),
}

# Validate the optional logo path.
logo_value = config.get("branding", "logo", fallback="").strip()
logo_path = Path(logo_value)

if logo_path.is_absolute() or ".." in logo_path.parts:
    raise RuntimeError("Unsafe logo path in portal configuration")

BRANDING["logo"] = (
    logo_value if (STATIC_DIR / logo_path).is_file() else None
)

# Login and success page settings.
LOGIN = {
    key: required_setting("login", key)
    for key in ("heading", "message", "terms", "button_text")
}

SUCCESS = {
    key: required_setting("success", key)
    for key in ("page_title", "heading", "message", "footer")
}

# Validate CSS values before exposing them to templates.
def validated_color(section, key):
    value = required_setting(section, key)

    if not re.fullmatch(r"#[0-9A-Fa-f]{6}", value):
        raise RuntimeError(f"Invalid CSS color: [{section}] {key}")

    return value


font_family = required_setting("appearance", "font_family")

if not re.fullmatch(r"[A-Za-z0-9 ,'-]{1,80}", font_family):
    raise RuntimeError("Invalid CSS font_family in portal configuration")

APPEARANCE = {
    "background_color": validated_color("appearance", "background_color"),
    "card_color": validated_color("appearance", "card_color"),
    "primary_color": validated_color("appearance", "primary_color"),
    "text_color": validated_color("appearance", "text_color"),
    "font_family": font_family,
}

# Explicit template and static asset locations.
app = Flask(
    __name__,
    template_folder=str(TEMPLATE_DIR),
    static_folder=str(STATIC_DIR),
    static_url_path="/static"
)

app.secret_key = secrets.token_bytes(32)

@app.route("/", methods=["GET", "POST"])
def portal():

    client_ip = ipaddress.ip_address(request.remote_addr)

    if client_ip not in ipaddress.ip_network("172.16.0.0/24"):
        return "Invalid client network", 403

    if str(client_ip) == "172.16.0.1":
        return "Invalid client address", 403

    if request.method == "GET":
        csrf = session.get("csrf")
        if not csrf:
            csrf = secrets.token_urlsafe(24)
            session["csrf"] = csrf

        return render_template(
            "login.html",
            branding=BRANDING,
            login=LOGIN,
            appearance=APPEARANCE,
            csrf=csrf
        )

    supplied = request.form.get("csrf", "")

    if not secrets.compare_digest(
        supplied, session.get("csrf", "")
    ):
        return "Invalid request", 403

    if not AUTH_SCRIPT.is_file():
        return "Authorisation service is not configured yet.", 503

    try:
        subprocess.run(
            ["/usr/bin/sudo", "-n", str(AUTH_SCRIPT), str(client_ip)],
            check=True,
            timeout=5,
            capture_output=True,
            text=True
        )
    except (subprocess.SubprocessError, OSError):
        app.logger.exception("Client authorisation failed")
        return "Authorisation failed. Contact the lab administrator.", 500

    session.clear()

    return render_template(
        "success.html",
        branding=BRANDING,
        success=SUCCESS,
        appearance=APPEARANCE
    )


@app.route("/<path:probe_path>", methods=["GET", "HEAD"])
def captive_probe(probe_path):

    client_ip = ipaddress.ip_address(request.remote_addr)

    if client_ip not in ipaddress.ip_network("172.16.0.0/24"):
        return "Invalid client network", 403

    if str(client_ip) == "172.16.0.1":
        return "Invalid client address", 403

    return redirect("http" + "://" + "172.16.0.1:8080/", code=302)


if __name__ == "__main__":
    app.run(
        host="172.16.0.1",
        port=8080,
        debug=False,
        use_reloader=False
    )
