"""Tenant isolation primitives.

Multi-tenancy is enforced through a single, immutable ``TenantContext`` that is
created **once at the trust boundary** (from an authenticated token) and then
threaded through every layer: storage, search, tools, and the agent.

The security invariant this module exists to protect:

    tenant_id ALWAYS comes from the authenticated caller (JWT/auth), NEVER from
    a user prompt or from the LLM's output.

Because downstream components (search service, tool registry, agent) are
*constructed with* a TenantContext and expose no way to change it, there is no
code path in which the agent can read or query another tenant's data — even
under prompt injection. Tools take no ``tenant_id`` argument; the tenant is
injected server-side from this context.

Isolation model (configurable):
    - BRIDGE (default): shared OpenSearch cluster, one index per tenant
      (``filings-{tenant_id}``). Strong isolation at medium cost. Recommended
      for most financial-services SaaS.
    - SILO: separate infrastructure per tenant (handled at deploy time); this
      module still derives per-tenant names so app code is identical.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum

from filings_assistant.common.config import Settings, get_settings

# Tenant IDs must be safe to embed in index names, cache keys, and metric
# dimensions. Restrict to a conservative charset and length.
_TENANT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,62}$")


class TenancyModel(str, Enum):
    """How tenants are isolated at the data layer."""

    BRIDGE = "bridge"  # shared cluster, index-per-tenant (default)
    SILO = "silo"  # separate infra per tenant (deploy-time)


class InvalidTenantError(ValueError):
    """Raised when a tenant_id is missing or malformed."""


def validate_tenant_id(tenant_id: str) -> str:
    """Validate and normalize a tenant_id.

    Args:
        tenant_id: Raw tenant identifier (expected from the auth token).

    Returns:
        The normalized (lower-cased) tenant_id.

    Raises:
        InvalidTenantError: if the id is missing or fails the charset/length rule.
    """
    if not tenant_id:
        raise InvalidTenantError("tenant_id is required and must come from the authenticated token")
    normalized = tenant_id.strip().lower()
    if not _TENANT_ID_RE.match(normalized):
        raise InvalidTenantError(
            f"Invalid tenant_id {tenant_id!r}: must be 2-63 chars, [a-z0-9-], not starting with '-'"
        )
    return normalized


@dataclass(frozen=True)
class TenantContext:
    """Immutable, per-request tenant scope.

    Frozen so it cannot be mutated after creation. Create it ONLY from a
    trusted source (the authenticated principal), never from request bodies,
    prompts, or model output.
    """

    tenant_id: str

    @classmethod
    def from_auth(cls, tenant_id: str) -> TenantContext:
        """Create a context from an authenticated principal's tenant claim."""
        return cls(tenant_id=validate_tenant_id(tenant_id))

    def index_name(self, settings: Settings | None = None) -> str:
        """Return this tenant's OpenSearch index name.

        In both BRIDGE and SILO the app uses a per-tenant index name; SILO just
        additionally separates the underlying infrastructure at deploy time.
        """
        settings = settings or get_settings()
        return f"{settings.opensearch_index}-{self.tenant_id}"

    def cache_key(self, *parts: str) -> str:
        """Return a tenant-namespaced cache key (prevents cross-tenant reuse)."""
        return ":".join([self.tenant_id, *parts])

    def log_fields(self) -> dict[str, str]:
        """Structured-log fields to attach to every tenant-scoped operation."""
        return {"tenant_id": self.tenant_id}


def default_tenant() -> TenantContext:
    """Return the default tenant context (for local/dev single-tenant use).

    Uses ``FA_DEFAULT_TENANT_ID`` (defaults to 'default'). Production code paths
    should always build the context ``from_auth`` instead of relying on this.
    """
    settings = get_settings()
    return TenantContext.from_auth(settings.default_tenant_id)


__all__ = [
    "TenantContext",
    "TenancyModel",
    "InvalidTenantError",
    "validate_tenant_id",
    "default_tenant",
]
