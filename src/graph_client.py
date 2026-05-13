import os
import logging

import httpx
import msal

logger = logging.getLogger(__name__)

GRAPH_BASE = "https://graph.microsoft.com/v1.0"


def _get_confidential_app() -> msal.ConfidentialClientApplication:
    return msal.ConfidentialClientApplication(
        client_id=os.environ["APP_CLIENT_ID"],
        client_credential=os.environ["APP_CLIENT_SECRET"],
        authority=f"https://login.microsoftonline.com/{os.environ['APP_TENANT_ID']}",
    )


def get_app_token() -> str:
    """Acquire an application-only token (client credentials) for Graph API.
    Used by the sync pipeline (no user context)."""
    app = _get_confidential_app()
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    if "access_token" not in result:
        raise RuntimeError(f"Failed to acquire app token: {result.get('error_description', result)}")
    return result["access_token"]


def get_obo_token(user_assertion: str) -> str:
    """Exchange a user token for a Graph API token via the On-Behalf-Of flow.
    Used by HTTP endpoints that act on behalf of the signed-in user."""
    tenant_id = os.environ["APP_TENANT_ID"]
    app = msal.ConfidentialClientApplication(
        client_id=os.environ["APP_CLIENT_ID"],
        client_credential=os.environ["APP_CLIENT_SECRET"],
        authority=f"https://login.microsoftonline.com/{tenant_id}",
    )
    result = app.acquire_token_on_behalf_of(
        user_assertion=user_assertion,
        scopes=[
            "https://graph.microsoft.com/EntitlementManagement.ReadWrite.All",
            "https://graph.microsoft.com/User.Read",
        ],
    )
    if "access_token" not in result:
        raise RuntimeError(f"OBO token exchange failed: {result.get('error_description', result)}")

    # Log token scopes for debugging
    import base64, json as _json
    try:
        payload = result["access_token"].split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = _json.loads(base64.urlsafe_b64decode(payload))
        logger.info("OBO token scopes: %s, roles: %s, aud: %s",
                     claims.get("scp"), claims.get("roles"), claims.get("aud"))
    except Exception:
        logger.warning("Could not decode OBO token for logging")

    return result["access_token"]


def _extract_bearer_token(auth_header: str | None) -> str:
    """Extract the bearer token from the Authorization header."""
    if not auth_header or not auth_header.startswith("Bearer "):
        raise ValueError("Missing or invalid Authorization header")
    return auth_header[7:]


# ---------------------------------------------------------------------------
# Graph API helpers
# ---------------------------------------------------------------------------

def list_access_packages(token: str) -> list[dict]:
    """Fetch all access packages, handling pagination."""
    url = f"{GRAPH_BASE}/identityGovernance/entitlementManagement/accessPackages?$expand=assignmentPolicies,catalog&$top=100"
    packages = []

    with httpx.Client(timeout=60) as client:
        while url:
            resp = client.get(url, headers={"Authorization": f"Bearer {token}"})
            resp.raise_for_status()
            data = resp.json()
            packages.extend(data.get("value", []))
            url = data.get("@odata.nextLink")
            logger.info("Fetched %d access packages so far", len(packages))

    return packages


def get_access_package_resources(token: str, package_id: str) -> list[str]:
    """Fetch the resource names associated with an access package."""
    url = (
        f"{GRAPH_BASE}/identityGovernance/entitlementManagement"
        f"/accessPackages/{package_id}"
        f"?$expand=resourceRoleScopes($expand=role,scope)"
    )
    resource_names = []

    with httpx.Client(timeout=30) as client:
        resp = client.get(url, headers={"Authorization": f"Bearer {token}"})
        resp.raise_for_status()
        data = resp.json()
        for item in data.get("resourceRoleScopes", []):
            scope = item.get("scope", {})
            name = scope.get("displayName")
            if name and name != "Root":
                resource_names.append(name)

    return resource_names


def get_access_package_detail(token: str, package_id: str) -> dict:
    """Fetch detailed information about a single access package."""
    url = (
        f"{GRAPH_BASE}/identityGovernance/entitlementManagement"
        f"/accessPackages/{package_id}?$expand=assignmentPolicies"
    )
    with httpx.Client(timeout=30) as client:
        resp = client.get(url, headers={"Authorization": f"Bearer {token}"})
        resp.raise_for_status()
        pkg = resp.json()

    resources = get_access_package_resources(token, package_id)

    policies = []
    for p in pkg.get("assignmentPolicies", []):
        policies.append({
            "id": p["id"],
            "displayName": p.get("displayName", ""),
            "allowedTargetScope": p.get("allowedTargetScope", ""),
            "expiration": p.get("expiration", {}),
        })

    return {
        "id": pkg["id"],
        "displayName": pkg["displayName"],
        "description": pkg.get("description", ""),
        "isHidden": pkg.get("isHidden", False),
        "createdDateTime": pkg.get("createdDateTime", ""),
        "resources": resources,
        "assignmentPolicies": policies,
    }


def get_me(token: str) -> dict:
    """Get the profile of the signed-in user."""
    with httpx.Client(timeout=30) as client:
        resp = client.get(
            f"{GRAPH_BASE}/me",
            headers={"Authorization": f"Bearer {token}"},
        )
        resp.raise_for_status()
        return resp.json()


def create_assignment_request(
    token: str,
    access_package_id: str,
    assignment_policy_id: str,
    justification: str,
    target_id: str | None = None,
) -> dict:
    """Submit an access package assignment request.

    If target_id is provided, it is used directly (adminAdd with app token).
    Otherwise, the token is assumed to be a user (OBO) token (userAdd)
    and the requesting user is inferred by Graph from the token.
    """
    if target_id:
        request_type = "adminAdd"
        assignment = {
            "targetId": target_id,
            "accessPackageId": access_package_id,
            "assignmentPolicyId": assignment_policy_id,
        }
    else:
        request_type = "userAdd"
        assignment = {
            "accessPackageId": access_package_id,
            "assignmentPolicyId": assignment_policy_id,
        }

    url = f"{GRAPH_BASE}/identityGovernance/entitlementManagement/assignmentRequests"
    body = {
        "requestType": request_type,
        "assignment": assignment,
        "justification": justification,
    }

    with httpx.Client(timeout=30) as client:
        resp = client.post(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            json=body,
        )
        if resp.status_code >= 400:
            error_body = resp.text
            logger.error(
                "Graph assignmentRequests failed %s: %s | request body: %s",
                resp.status_code, error_body, body,
            )
            raise RuntimeError(
                f"Graph API {resp.status_code}: {error_body}"
            )
        return resp.json()
