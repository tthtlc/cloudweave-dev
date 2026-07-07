from fastapi import FastAPI

from app.auth.routes import router as auth_router
from app.admin.routes import router as admin_router
from app.common.errors import APIError, api_error_handler
from app.common.middleware import RequestIDMiddleware
from app.compute.routes import router as compute_router
from app.config.settings import get_settings
from app.connections.routes import router as connections_router
from app.jobs.routes import router as jobs_router
from app.network.routes import router as network_router
from app.providers.routes import router as providers_router
from app.storage.routes import router as storage_router


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title=settings.app_title,
        version=settings.app_version,
        description="REST API wrapper for Apache Libcloud compute drivers",
    )
    app.add_middleware(RequestIDMiddleware)
    app.add_exception_handler(APIError, api_error_handler)

    app.include_router(auth_router)
    app.include_router(providers_router)
    app.include_router(connections_router)
    app.include_router(compute_router)
    app.include_router(network_router)
    app.include_router(storage_router)
    app.include_router(jobs_router)
    app.include_router(admin_router)

    @app.get("/health")
    def health():
        return {"status": "ok"}

    return app


app = create_app()
