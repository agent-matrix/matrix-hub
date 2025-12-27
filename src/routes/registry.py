"""
Registry routes for direct MCP server registration.

- POST /registry/mcp: Register an MCP server by URL/endpoint

This allows frontends to register MCP servers directly without
requiring a published manifest URL. The backend will:
1. Build or validate the manifest
2. Store it in blob storage
3. Save entity + endpoint to database
4. Optionally discover capabilities
"""

from __future__ import annotations

import json
import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Entity, MCPEndpoint
from .. import schemas
from ..services import validate
from ..services.search import blobstore

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/registry", tags=["registry"])


def _build_minimal_manifest(
    entity_id: str,
    name: str,
    version: str,
    description: Optional[str],
    summary: Optional[str],
    capabilities: list[str],
    endpoint: schemas.MCPEndpointSpec,
) -> dict:
    """Build a minimal valid mcp_server manifest from user input."""
    manifest = {
        "manifestVersion": "1.0",
        "type": "mcp_server",
        "id": entity_id,
        "name": name,
        "version": version,
    }

    if summary:
        manifest["summary"] = summary
    if description:
        manifest["description"] = description

    # Build mcp_registration.server block
    server_block: dict = {
        "name": name,
        "transport": endpoint.transport.upper(),
    }

    if endpoint.url:
        # Normalize SSE URLs to end with /messages/ (consistent with install.py)
        url = endpoint.url
        if endpoint.transport.upper() == "SSE" and not url.endswith("/messages/"):
            if not url.endswith("/"):
                url += "/"
            url += "messages/"
        server_block["url"] = url

    if endpoint.transport.upper() == "STDIO" and endpoint.command:
        server_block["command"] = endpoint.command
        if endpoint.args:
            server_block["args"] = endpoint.args
        if endpoint.env:
            server_block["env"] = endpoint.env

    if description:
        server_block["description"] = description

    manifest["mcp_registration"] = {
        "server": server_block
    }

    # Add capabilities if provided
    if capabilities:
        manifest["capabilities"] = capabilities

    return manifest


def _normalize_url(url: str, transport: str) -> str:
    """Normalize URL based on transport type."""
    if transport.upper() == "SSE" and not url.endswith("/messages/"):
        if not url.endswith("/"):
            url += "/"
        url += "messages/"
    return url


@router.post("/mcp", response_model=schemas.RegisterMCPResponse)
async def register_mcp_server(
    request: schemas.RegisterMCPRequest,
    db: Session = Depends(get_db),
) -> schemas.RegisterMCPResponse:
    """
    Register a new MCP server from a URL or complete manifest.

    This endpoint allows frontends to register MCP servers without requiring
    a published manifest URL. The server will:
    1. Build or validate the manifest
    2. Store it in blob storage (so it's available even without source_url)
    3. Create entity + mcp_endpoint records
    4. Optionally discover tools/resources/prompts

    Request modes:
    - Minimal: endpoint + basic metadata (id, name, version, description)
    - Full: endpoint + complete manifest

    Returns the entity UID and storage references.
    """
    logger.info(
        "registry.mcp.register",
        extra={
            "endpoint_transport": request.endpoint.transport,
            "endpoint_url": request.endpoint.url,
            "has_manifest": request.manifest is not None,
        }
    )

    # Step 1: Build or use provided manifest
    manifest: dict
    if request.manifest:
        # Full manifest mode
        manifest = request.manifest
        # Ensure type is mcp_server
        if manifest.get("type") != "mcp_server":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Manifest type must be 'mcp_server'"
            )
    else:
        # Minimal mode: build manifest from metadata
        if not request.id or not request.name:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Either 'manifest' or both 'id' and 'name' must be provided"
            )

        manifest = _build_minimal_manifest(
            entity_id=request.id,
            name=request.name,
            version=request.version or "0.1.0",
            description=request.description,
            summary=request.summary,
            capabilities=request.capabilities or [],
            endpoint=request.endpoint,
        )

    # Step 2: Validate manifest
    try:
        manifest = validate.validate_manifest(manifest)
    except Exception as e:
        logger.error("registry.mcp.validation_failed", extra={"error": str(e)})
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Manifest validation failed: {str(e)}"
        )

    # Step 3: Build entity UID
    entity_id = manifest["id"]
    version = manifest["version"]
    uid = f"mcp_server:{entity_id}@{version}"

    # Step 4: Store manifest in blob storage
    manifest_json = json.dumps(manifest, indent=2)
    manifest_blob_ref = blobstore.put_text(f"{uid}:manifest", manifest_json)
    logger.info("registry.mcp.manifest_stored", extra={"blob_ref": manifest_blob_ref})

    # Step 5: Create or update Entity
    entity = db.query(Entity).filter(Entity.uid == uid).first()
    if not entity:
        entity = Entity(
            uid=uid,
            type="mcp_server",
            name=manifest["name"],
            version=manifest["version"],
        )
        db.add(entity)

    # Update entity fields from manifest
    entity.summary = manifest.get("summary")
    entity.description = manifest.get("description")
    entity.license = manifest.get("license")
    entity.homepage = manifest.get("homepage")
    entity.capabilities = manifest.get("capabilities", [])
    entity.frameworks = manifest.get("frameworks", [])
    entity.providers = manifest.get("providers", [])
    entity.manifest_blob_ref = manifest_blob_ref
    entity.mcp_registration = manifest.get("mcp_registration")

    # Step 6: Create or update MCPEndpoint
    endpoint_record = db.query(MCPEndpoint).filter(MCPEndpoint.entity_uid == uid).first()
    if not endpoint_record:
        endpoint_record = MCPEndpoint(entity_uid=uid)
        db.add(endpoint_record)

    # Normalize URL if applicable
    endpoint_url = request.endpoint.url
    if endpoint_url and request.endpoint.transport:
        endpoint_url = _normalize_url(endpoint_url, request.endpoint.transport)

    endpoint_record.transport = request.endpoint.transport.upper()
    endpoint_record.url = endpoint_url
    endpoint_record.command = request.endpoint.command
    endpoint_record.args_json = request.endpoint.args
    endpoint_record.env_json = request.endpoint.env
    endpoint_record.headers_json = request.endpoint.headers
    endpoint_record.auth_json = request.endpoint.auth

    # Step 7: Optional discovery (future enhancement)
    discovery_result = None
    if request.discover:
        # TODO: Implement discovery logic
        # This would query the MCP server for capabilities, tools, resources, prompts
        logger.warning("registry.mcp.discovery_not_implemented")
        discovery_result = {"status": "not_implemented"}

    # Step 8: Commit to database
    try:
        db.commit()
        logger.info("registry.mcp.saved", extra={"uid": uid})
    except Exception as e:
        db.rollback()
        logger.error("registry.mcp.save_failed", extra={"error": str(e)})
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to save entity: {str(e)}"
        )

    return schemas.RegisterMCPResponse(
        ok=True,
        uid=uid,
        manifest_blob_ref=manifest_blob_ref,
        endpoint_saved=True,
        discovery=discovery_result,
    )
