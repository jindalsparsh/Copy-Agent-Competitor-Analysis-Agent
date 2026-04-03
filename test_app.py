import sys
from pathlib import Path

# Add the project root to sys.path
root = Path(__file__).parent.resolve()
sys.path.append(str(root))

print("Testing app import...")
try:
    from app.main import app
    print("App import successful.")
    print("Health check...")
    from fastapi.testclient import TestClient
    client = TestClient(app)
    response = client.get("/health")
    print(f"Health response: {response.status_code} - {response.json()}")
    print("SUCCESS")
except Exception as e:
    print(f"FAILED: {e}")
    import traceback
    traceback.print_exc()
