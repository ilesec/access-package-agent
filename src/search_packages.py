import json
import logging

from . import embedding_client, search_client

logger = logging.getLogger(__name__)


def handle(body: dict) -> tuple[int, dict]:
    """Handle POST /api/searchPackages.

    Request body:  {"query": "I need access to Azure DevOps"}
    Response body: [{"id", "displayName", "description", "resources", "score"}, ...]
    """
    query = (body.get("query") or "").strip()
    if not query:
        return 400, {"error": "Missing required field: query"}

    top = min(int(body.get("top", 5)), 20)

    # Embed the user query
    query_vector = embedding_client.get_embedding(query)

    # Hybrid search (full-text + vector)
    results = search_client.hybrid_search(query_text=query, query_vector=query_vector, top=top)

    logger.info("Search for '%s' returned %d results", query, len(results))
    return 200, {"results": results}
