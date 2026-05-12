import logging

from . import graph_client

logger = logging.getLogger(__name__)


def handle(body: dict, auth_header: str | None) -> tuple[int, dict]:
    """Handle POST /api/requestPackage.

    Request body:
        {
            "accessPackageId": "...",
            "justification": "...",
            "assignmentPolicyId": "..."   # optional — fetched from index if omitted
        }
    """
    access_package_id = (body.get("accessPackageId") or "").strip()
    justification = (body.get("justification") or "").strip()

    if not access_package_id:
        return 400, {"error": "Missing required field: accessPackageId"}
    if not justification:
        return 400, {"error": "Missing required field: justification"}

    # Auth — exchange user token for Graph token via OBO
    try:
        user_token = graph_client._extract_bearer_token(auth_header)
        graph_token = graph_client.get_obo_token(user_token)
    except Exception as exc:
        logger.warning("Auth failed: %s", exc)
        return 401, {"error": "Authentication failed"}

    # Resolve assignment policy if not provided
    assignment_policy_id = (body.get("assignmentPolicyId") or "").strip()
    if not assignment_policy_id:
        try:
            detail = graph_client.get_access_package_detail(graph_token, access_package_id)
            policies = detail.get("assignmentPolicies", [])
            if not policies:
                return 400, {"error": "No assignment policies found for this access package. It may not be available for self-service requests."}
            assignment_policy_id = policies[0]["id"]
        except Exception as exc:
            logger.error("Failed to resolve policy: %s", exc, exc_info=True)
            return 500, {"error": f"Failed to resolve assignment policy: {exc}"}

    # Submit assignment request
    try:
        result = graph_client.create_assignment_request(
            token=graph_token,
            access_package_id=access_package_id,
            assignment_policy_id=assignment_policy_id,
            justification=justification,
        )
        return 200, {
            "message": "Access package request submitted successfully.",
            "requestId": result.get("id", ""),
            "status": result.get("status", ""),
        }
    except Exception as exc:
        logger.error("Assignment request failed: %s", exc, exc_info=True)
        return 500, {"error": f"Failed to submit assignment request: {exc}"}
