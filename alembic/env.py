from __future__ import annotations

# --- Ensure project root is importable so `src.*` works when alembic runs -----
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]  # repo root (parent of alembic/)
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

# -----------------------------------------------------------------------------


from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool
from sqlalchemy.engine import Connection

# Import application settings and metadata
try:
    from src.config import settings
    from src.models import Base
except Exception as e:  # pragma: no cover
    # Give a clear error if imports fail (usually PYTHONPATH / venv issue)
    raise RuntimeError(
        "Alembic could not import 'src.config' / 'src.models'. "
        "Make sure you run alembic inside your virtualenv and that the project "
        "root is on PYTHONPATH. (env.py adds the repo root to sys.path automatically.)"
    ) from e

# This is the Alembic Config object, which provides access to the values
# within the .ini file in use, if any.
config = context.config

# Interpret the config file for Python logging.
# If you have an alembic.ini with a [loggers] section this will configure it.
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Set the target metadata for 'autogenerate' support.
target_metadata = Base.metadata

# DEBUG: print loaded metadata tables to verify model detection
#print("Loaded tables:", Base.metadata.tables)

# If alembic.ini does not define sqlalchemy.url, set it from settings
if not config.get_main_option("sqlalchemy.url"):
    # settings.DATABASE_URL should be set via env or defaults
    config.set_main_option("sqlalchemy.url", settings.DATABASE_URL)


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode."""
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        compare_type=True,
        compare_server_default=True,
    )

    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode."""
    configuration = config.get_section(config.config_ini_section) or {}
    configuration["sqlalchemy.url"] = config.get_main_option("sqlalchemy.url")

    connectable = engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
        future=True,
    )

    with connectable.connect() as connection:  # type: Connection
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            compare_type=True,
            compare_server_default=True,
        )

        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
