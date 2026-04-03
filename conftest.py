"""
Root conftest.py — sets required environment variables before any app module
is imported during test collection.

pydantic-settings reads from os.environ at class instantiation time, so
these must be set here (not in a fixture) to prevent ValidationError during
collection.  Real values in a .env file or the shell environment take
precedence via os.environ.setdefault().
"""

import os

os.environ.setdefault("ANTHROPIC_API_KEY", "test-anthropic-key")
os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/fake_service_account.json")
os.environ.setdefault("GOOGLE_SHEET_ID", "test-sheet-id")
os.environ.setdefault("GOOGLE_DRIVE_FILE_ID", "test-drive-file-id")
os.environ.setdefault("GOOGLE_DOC_ID", "test-doc-id")
