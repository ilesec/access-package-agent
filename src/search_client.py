import os
import logging

from azure.identity import ManagedIdentityCredential
from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    SearchIndex,
    SimpleField,
    SearchableField,
    SearchField,
    SearchFieldDataType,
    VectorSearch,
    HnswAlgorithmConfiguration,
    VectorSearchProfile,
)
from azure.search.documents.models import VectorizedQuery

logger = logging.getLogger(__name__)


def _get_credential():
    return ManagedIdentityCredential()


def _get_search_client() -> SearchClient:
    endpoint = os.environ["AZURE_SEARCH_ENDPOINT"]
    index_name = os.environ.get("AZURE_SEARCH_INDEX_NAME", "access-packages-index")
    return SearchClient(endpoint=endpoint, index_name=index_name, credential=_get_credential())


def ensure_index_exists() -> None:
    """Create the access-packages-index if it doesn't already exist."""
    endpoint = os.environ["AZURE_SEARCH_ENDPOINT"]
    index_name = os.environ.get("AZURE_SEARCH_INDEX_NAME", "access-packages-index")
    client = SearchIndexClient(endpoint=endpoint, credential=_get_credential())

    fields = [
        SimpleField(name="id", type=SearchFieldDataType.String, key=True, filterable=True),
        SearchableField(name="displayName", type=SearchFieldDataType.String, filterable=True),
        SearchableField(name="description", type=SearchFieldDataType.String),
        SearchableField(name="catalogName", type=SearchFieldDataType.String, filterable=True),
        SearchableField(name="resources", type=SearchFieldDataType.String),
        SimpleField(name="assignmentPolicyId", type=SearchFieldDataType.String, filterable=False),
        SearchField(
            name="contentVector",
            type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
            searchable=True,
            vector_search_dimensions=1536,
            vector_search_profile_name="default-vector-profile",
        ),
    ]

    vector_search = VectorSearch(
        algorithms=[
            HnswAlgorithmConfiguration(
                name="default-hnsw",
                parameters={"m": 4, "efConstruction": 400, "efSearch": 500, "metric": "cosine"},
            )
        ],
        profiles=[
            VectorSearchProfile(name="default-vector-profile", algorithm_configuration_name="default-hnsw")
        ],
    )

    index = SearchIndex(name=index_name, fields=fields, vector_search=vector_search)

    try:
        client.get_index(index_name)
        logger.info("Index '%s' already exists — updating.", index_name)
        client.create_or_update_index(index)
    except Exception:
        logger.info("Creating index '%s'.", index_name)
        client.create_or_update_index(index)


def upsert_documents(documents: list[dict]) -> int:
    """Upload or merge documents into the index. Returns count of succeeded items."""
    client = _get_search_client()
    succeeded = 0
    batch_size = 1000
    for i in range(0, len(documents), batch_size):
        batch = documents[i : i + batch_size]
        result = client.upload_documents(documents=batch)
        succeeded += sum(1 for r in result if r.succeeded)
        logger.info("Upserted batch %d–%d, succeeded: %d", i, i + len(batch), succeeded)
    return succeeded


def hybrid_search(query_text: str, query_vector: list[float], top: int = 5) -> list[dict]:
    """Run a hybrid (text + vector) search and return the top results."""
    client = _get_search_client()

    vector_query = VectorizedQuery(
        vector=query_vector,
        k_nearest_neighbors=top,
        fields="contentVector",
    )

    results = client.search(
        search_text=query_text,
        vector_queries=[vector_query],
        select=["id", "displayName", "description", "catalogName", "resources", "assignmentPolicyId"],
        top=top,
    )

    output = []
    for result in results:
        output.append(
            {
                "id": result["id"],
                "displayName": result["displayName"],
                "description": result.get("description", ""),
                "catalogName": result.get("catalogName", ""),
                "resources": result.get("resources", ""),
                "assignmentPolicyId": result.get("assignmentPolicyId", ""),
                "score": result["@search.score"],
            }
        )
    return output
