import logging

from . import graph_client, embedding_client, search_client

logger = logging.getLogger(__name__)


def sync() -> dict:
    """Synchronise Entra ID access packages into the Azure AI Search vector index.

    1. Fetch all access packages (with policies and resources) from Graph API.
    2. Build a searchable text per package and compute embeddings.
    3. Upsert documents into the Azure AI Search index.

    Returns a summary dict with counts.
    """
    search_client.ensure_index_exists()

    # --- 1. Fetch packages ---
    token = graph_client.get_app_token()
    packages = graph_client.list_access_packages(token)
    logger.info("Fetched %d access packages from Graph API", len(packages))

    if not packages:
        return {"fetched": 0, "indexed": 0}

    # --- 2. Build documents and compute embeddings ---
    texts: list[str] = []
    docs: list[dict] = []

    for pkg in packages:
        pkg_id = pkg["id"]
        display_name = pkg.get("displayName", "")
        description = pkg.get("description", "")

        # Fetch resource names for richer embedding text
        try:
            resource_names = graph_client.get_access_package_resources(token, pkg_id)
        except Exception:
            logger.warning("Failed to fetch resources for package %s", pkg_id, exc_info=True)
            resource_names = []

        resources_str = ", ".join(resource_names) if resource_names else ""

        # Pick the first assignment policy id (if any) for request convenience
        policies = pkg.get("assignmentPolicies", [])
        policy_id = policies[0]["id"] if policies else ""

        # Catalog name (from nested catalog object if expanded, else empty)
        catalog_name = ""
        catalog = pkg.get("catalog")
        if catalog:
            catalog_name = catalog.get("displayName", "")

        # Compose the text used for embedding
        embed_text = f"{display_name}. {description}. Resources: {resources_str}"
        texts.append(embed_text)

        docs.append({
            "id": pkg_id,
            "displayName": display_name,
            "description": description,
            "catalogName": catalog_name,
            "resources": resources_str,
            "assignmentPolicyId": policy_id,
        })

    embeddings = embedding_client.get_embeddings_batch(texts)

    for doc, vec in zip(docs, embeddings):
        doc["contentVector"] = vec

    # --- 3. Upsert into index ---
    succeeded = search_client.upsert_documents(docs)
    logger.info("Indexed %d / %d access packages", succeeded, len(docs))

    return {"fetched": len(packages), "indexed": succeeded}
