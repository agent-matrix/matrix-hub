import json
import os
from pathlib import Path

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

# Local DB for CI
os.environ.setdefault("DATABASE_URL", "sqlite+pysqlite:///./test_install.sqlite")
os.environ.setdefault("MATRIX_REMOTES", "[]")

from src.models import Base, Entity
from src.services import install as installer


@pytest.fixture(scope="module")
def engine():
    eng = create_engine("sqlite+pysqlite:///./test_install.sqlite", future=True)
    Base.metadata.create_all(eng)
    yield eng
    Base.metadata.drop_all(eng)


@pytest.fixture(scope="module")
def Session(engine):
    return sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


@pytest.fixture
def db(Session):
    db = Session()
    try:
        yield db
    finally:
        db.close()


@pytest.fixture
def project_dir(tmp_path: Path) -> Path:
    (tmp_path / "apps" / "demo").mkdir(parents=True)
    return tmp_path / "apps" / "demo"


@pytest.fixture(autouse=True)
def seed_entity(db):
    db.query(Entity).delete()
    e = Entity(
        uid="agent:test-agent@0.1.0",
        type="agent",
        name="Test Agent",
        version="0.1.0",
        summary="A test agent.",
        description="Used for install flow tests.",
        source_url="https://example.invalid/manifest.yaml",  # will be stubbed
    )
    db.add(e)
    db.commit()
    yield


def test_install_plan_and_lockfile(db, project_dir, monkeypatch):
    # Stub manifest loader to avoid network
    manifest = {
        "schema_version": 1,
        "type": "agent",
        "id": "test-agent",
        "name": "Test Agent",
        "version": "0.1.0",
        "description": "Used for install tests.",
        "artifacts": [],  # keep empty to avoid external commands
        "adapters": [
            {"framework": "langgraph", "template_key": "langgraph-node", "params": {"class_name": "TestNode"}}
        ],
        "mcp_registration": {
            "tool": {
                "name": "test_tool",
                "integration_type": "REST",
                "request_type": "POST",
                "url": "http://localhost:9999/invoke",
                "input_schema": {"type": "object"},
            }
        },
    }

    monkeypatch.setattr(installer, "_load_manifest", lambda entity: manifest)

    # Stub adapters writer
    def _fake_write_adapters(mfest, target: str):
        p = Path(target) / "src" / "flows" / "test_node.py"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("# generated", encoding="utf-8")
        return [str(p)]

    monkeypatch.setattr(installer, "write_adapters", _fake_write_adapters)

    # Stub gateway client wrappers (no-ops)
    monkeypatch.setattr(installer, "register_tool", lambda *a, **k: {"ok": True}, raising=False)
    monkeypatch.setattr(installer, "register_server", lambda *a, **k: {"ok": True}, raising=False)
    monkeypatch.setattr(installer, "register_resources", lambda *a, **k: [], raising=False)
    monkeypatch.setattr(installer, "register_prompts", lambda *a, **k: [], raising=False)
    monkeypatch.setattr(installer, "trigger_discovery", lambda *a, **k: {"status": "ok"}, raising=False)

    result = installer.install_entity(
        db=db,
        entity_id="agent:test-agent",
        version="0.1.0",
        target=str(project_dir),
    )

    # Basic shape checks
    assert "plan" in result and "results" in result and "files_written" in result and "lockfile" in result
    assert isinstance(result["files_written"], list)
    assert any(str(project_dir) in fp or fp.endswith(".json") or fp.endswith(".py") for fp in result["files_written"])

    # Lockfile schema
    lock = result["lockfile"]
    assert lock.get("version") == 1
    assert isinstance(lock.get("entities"), list) and lock["entities"][0]["id"] == "agent:test-agent@0.1.0"

    # Ensure lockfile actually written
    lf = project_dir / "matrix.lock.json"
    assert lf.exists()
    data = json.loads(lf.read_text(encoding="utf-8"))
    assert data.get("version") == 1
