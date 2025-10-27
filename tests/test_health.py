from app.main import healthz

def test_health():
    assert healthz()["status"] == "ok"