#!/usr/bin/env python3
"""Small App Store Connect API helper for CI.

    asc.py ensure-bundle <identifier> <name>   register a bundle ID (iOS and macOS) if it isn't yet
    asc.py bundle <identifier>                 show a bundle ID's platform and capabilities
    asc.py capability <identifier> <TYPE>      make sure a capability is on (e.g. ACCESS_WIFI_INFORMATION)
    asc.py certs                               list the team's signing certificates
    asc.py revoke-ci-dev [keep id]             revoke the "Created via API" development certificates
                                               that CI runners left behind (their keys are gone)
    asc.py dev-cert <csr file> <out file>      a development certificate for CI's own lasting key
    asc.py devid-profile <identifier> <name> <cert serial hex> <out file>
                                               a fresh Developer ID (Mac, direct) provisioning profile
    asc.py dist-cert <csr file> <out file>     an Apple Distribution certificate for CI's own lasting key
    asc.py store-profile <identifier> <name> <cert serial hex> <out file>
                                               a fresh App Store (iOS) provisioning profile
    asc.py testflight <identifier>             the app's builds, and an internal "Owner" group that
                                               gets every build, with the team's users in it

Reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file). Needs PyJWT
with its crypto extra.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token():
    key = open(os.environ["ASC_KEY_PATH"]).read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method, path, body=None):
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def bundle(identifier):
    status, out = call("GET", f"/bundleIds?filter[identifier]={identifier}&include=bundleIdCapabilities")
    if status != 200:
        sys.exit(f"cannot read bundle IDs ({status}): {out}")
    match = [b for b in out["data"] if b["attributes"]["identifier"] == identifier]
    if not match:
        sys.exit(f"no bundle ID {identifier}")
    caps = sorted(i["attributes"]["capabilityType"] for i in out.get("included", []) if i["type"] == "bundleIdCapabilities")
    return match[0], caps


def devid_profile(identifier, name, serial, out):
    make_profile(identifier, name, serial, out, "MAC_APP_DIRECT", ("DEVELOPER_ID_APPLICATION",))


def make_profile(identifier, name, serial, out, profile_type, cert_types):
    b, _ = bundle(identifier)
    status, certs = call("GET", "/certificates?limit=200")
    if status != 200:
        sys.exit(f"cannot list certificates ({status}): {certs}")
    want = serial.lower().lstrip("0")
    match = [c for c in certs["data"]
             if c["attributes"]["certificateType"].startswith(cert_types)
             and c["attributes"]["serialNumber"].lower().lstrip("0") == want]
    if not match:
        sys.exit(f"no {' or '.join(cert_types)} certificate with serial {serial} on the team")
    # replace any profile of the same name, so it always carries today's capabilities
    status, old = call("GET", f"/profiles?filter[name]={urllib.parse.quote(name)}&limit=50")
    for p in old.get("data", []) if status == 200 else []:
        if p["attributes"]["name"] == name:
            call("DELETE", f"/profiles/{p['id']}")
    status, made = call("POST", "/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": name, "profileType": profile_type},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": b["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": match[0]["id"]}]},
        },
    }})
    if status not in (200, 201):
        sys.exit(f"could not make the profile {name} ({status}): {made}")
    import base64
    with open(out, "wb") as f:
        f.write(base64.b64decode(made["data"]["attributes"]["profileContent"]))
    print(f"profile {name} for {identifier}: {made['data']['attributes']['uuid']}")


def new_cert(csr_file, out, cert_type):
    csr = open(csr_file).read()
    csr = "".join(l for l in csr.splitlines() if "-----" not in l)
    status, made = call("POST", "/certificates", {"data": {
        "type": "certificates",
        "attributes": {"certificateType": cert_type, "csrContent": csr},
    }})
    if status not in (200, 201):
        sys.exit(f"could not make the certificate ({status}): {made}")
    import base64
    with open(out, "wb") as f:
        f.write(base64.b64decode(made["data"]["attributes"]["certificateContent"]))
    print(f"made {cert_type.lower()} certificate {made['data']['id']}")


def testflight(identifier):
    status, apps = call("GET", f"/apps?filter[bundleId]={identifier}")
    if status != 200 or not apps["data"]:
        sys.exit(f"no App Store Connect app for {identifier} ({status})")
    app = apps["data"][0]
    print(f"app {app['attributes']['name']} ({app['id']})")
    status, builds = call("GET", f"/builds?filter[app]={app['id']}&sort=-uploadedDate&limit=5")
    for b in builds.get("data", []):
        a = b["attributes"]
        print(f"build {a['version']}: {a['processingState']}, uploaded {a['uploadedDate'][:16]}, expired {a['expired']}")
    # uploads that never became builds (processing refused them) show only here
    for path in (f"/buildUploads?filter[app]={app['id']}&limit=10", f"/apps/{app['id']}/buildUploads?limit=10"):
        status, ups = call("GET", path)
        print(f"{path.split('?')[0]}: {status}")
        if status == 200:
            for u in ups.get("data", []):
                print("upload", json.dumps(u.get("attributes", {}))[:600])
            break

    status, groups = call("GET", f"/apps/{app['id']}/betaGroups")
    group = next((g for g in groups.get("data", []) if g["attributes"]["name"] == "Owner"), None)
    if group is None:
        status, made = call("POST", "/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": "Owner", "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}},
        }})
        if status not in (200, 201):
            sys.exit(f"could not make the Owner group ({status}): {made}")
        group = made["data"]
        print("made the internal group Owner (every build)")
    else:
        print("internal group Owner exists")

    status, users = call("GET", "/users?limit=50")
    if status != 200:
        print(f"can't list the team's users ({status}); add yourself to Owner in TestFlight")
        return
    status, testers = call("GET", f"/betaGroups/{group['id']}/betaTesters?limit=200")
    have = {t["attributes"].get("email", "").lower() for t in testers.get("data", [])}
    for u in users["data"]:
        a = u["attributes"]
        email = a.get("username", "")
        if not email or email.lower() in have:
            continue
        status, made = call("POST", "/betaTesters", {"data": {
            "type": "betaTesters",
            "attributes": {"email": email, "firstName": a.get("firstName", ""), "lastName": a.get("lastName", "")},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}},
        }})
        print(f"added a team user to Owner ({status})" if status in (200, 201) else f"could not add a team user ({status}): {made}")
    print(f"Owner has {len(have)} tester(s) before this run")


def ensure_bundle(identifier, name):
    status, out = call("GET", f"/bundleIds?filter[identifier]={identifier}")
    if status == 200 and any(b["attributes"]["identifier"] == identifier for b in out["data"]):
        print(f"{identifier} is registered")
        return
    status, made = call("POST", "/bundleIds", {"data": {
        "type": "bundleIds",
        "attributes": {"identifier": identifier, "name": name, "platform": "UNIVERSAL"},
    }})
    if status not in (200, 201):
        sys.exit(f"could not register {identifier} ({status}): {made}")
    print(f"registered {identifier}")


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "ensure-bundle":
        ensure_bundle(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 3 and sys.argv[1] == "bundle":
        b, caps = bundle(sys.argv[2])
        print(f"{sys.argv[2]}: platform {b['attributes']['platform']}, capabilities {', '.join(caps) or 'none'}")
    elif len(sys.argv) >= 4 and sys.argv[1] == "capability":
        b, caps = bundle(sys.argv[2])
        if sys.argv[3] in caps:
            print(f"{sys.argv[2]} already has {sys.argv[3]}")
            return
        status, out = call("POST", "/bundleIdCapabilities", {"data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": sys.argv[3]},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": b["id"]}}},
        }})
        if status not in (200, 201):
            sys.exit(f"could not turn on {sys.argv[3]} ({status}): {out}")
        print(f"turned on {sys.argv[3]} for {sys.argv[2]}")
    elif len(sys.argv) >= 2 and sys.argv[1] == "certs":
        status, certs = call("GET", "/certificates?limit=200")
        if status != 200:
            sys.exit(f"cannot list certificates ({status}): {certs}")
        for c in sorted(certs["data"], key=lambda c: c["attributes"]["expirationDate"]):
            a = c["attributes"]
            print(f"{c['id']}  {a['certificateType']:<28} {a['expirationDate'][:10]}  {a['name']}  ({a.get('displayName','')})")
    elif len(sys.argv) >= 2 and sys.argv[1] == "revoke-ci-dev":
        keep = sys.argv[2] if len(sys.argv) > 2 else ""
        status, certs = call("GET", "/certificates?limit=200")
        if status != 200:
            sys.exit(f"cannot list certificates ({status}): {certs}")
        for c in certs["data"]:
            a = c["attributes"]
            if a["certificateType"] == "DEVELOPMENT" and a["name"] == "Apple Development: Created via API" and c["id"] != keep:
                st, _ = call("DELETE", f"/certificates/{c['id']}")
                print(f"revoked {c['id']} ({st})")
    elif len(sys.argv) >= 4 and sys.argv[1] == "dev-cert":
        new_cert(sys.argv[2], sys.argv[3], "DEVELOPMENT")
    elif len(sys.argv) >= 6 and sys.argv[1] == "devid-profile":
        devid_profile(*sys.argv[2:6])
    elif len(sys.argv) >= 6 and sys.argv[1] == "store-profile":
        make_profile(*sys.argv[2:6], "IOS_APP_STORE", ("DISTRIBUTION", "IOS_DISTRIBUTION"))
    elif len(sys.argv) >= 3 and sys.argv[1] == "testflight":
        testflight(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "dist-cert":
        new_cert(sys.argv[2], sys.argv[3], "DISTRIBUTION")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
