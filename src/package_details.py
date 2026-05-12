import logging

from . import graph_client

logger = logging.getLogger(__name__)


def handle(package_id: str, auth_header: str | None) -> tuple[int, dict]:
    """Handle GET /api/packageDetails/{id}.

    Returns detailed information about a single access package including
    resources and assignment policies.
    """
    if not package_id:
        return 400, {"error": "Missing package id"}

    try:
        user_token = graph_client._extract_bearer_token(auth_header)
        graph_token = graph_client.get_obo_token(user_token)
    except Exception as exc:
        logger.warning("Auth failed: %s", exc)
        return 401, {"error": "Authentication failed"}

    try:
        detail = graph_client.get_access_package_detail(graph_token, package_id)
        return 200, detail
    except Exception as exc:
        logger.error("Failed to fetch package %s: %s", package_id, exc, exc_info=True)
        return 500, {"error": f"Failed to fetch package details: {exc}"}
