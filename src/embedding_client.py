import os
import logging

from azure.identity import ManagedIdentityCredential
from openai import AzureOpenAI

logger = logging.getLogger(__name__)

_client: AzureOpenAI | None = None


def _get_client() -> AzureOpenAI:
    global _client
    if _client is None:
        endpoint = os.environ["AZURE_OPENAI_ENDPOINT"]
        api_version = os.environ.get("AZURE_OPENAI_API_VERSION", "2024-10-21")

        credential = ManagedIdentityCredential()
        token_provider = lambda: credential.get_token("https://cognitiveservices.azure.com/.default").token
        _client = AzureOpenAI(
            azure_endpoint=endpoint,
            azure_ad_token_provider=token_provider,
            api_version=api_version,
        )
    return _client


def get_embedding(text: str) -> list[float]:
    """Return a 1536-dim embedding vector for the given text."""
    deployment = os.environ.get("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-small")
    client = _get_client()
    response = client.embeddings.create(input=[text], model=deployment)
    return response.data[0].embedding


def get_embeddings_batch(texts: list[str], batch_size: int = 16) -> list[list[float]]:
    """Return embeddings for a list of texts, batching calls to stay within limits."""
    deployment = os.environ.get("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-small")
    client = _get_client()
    all_embeddings: list[list[float]] = []

    for i in range(0, len(texts), batch_size):
        batch = texts[i : i + batch_size]
        response = client.embeddings.create(input=batch, model=deployment)
        all_embeddings.extend([item.embedding for item in response.data])
        logger.info("Embedded batch %d–%d of %d", i, i + len(batch), len(texts))

    return all_embeddings
