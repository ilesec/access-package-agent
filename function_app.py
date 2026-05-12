import json
import logging

import azure.functions as func

from src import search_packages, package_details, request_package, sync_access_packages

app = func.FunctionApp()

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# HTTP-triggered endpoints (called by the Copilot plugin)
# ---------------------------------------------------------------------------

@app.function_name("searchPackages")
@app.route(route="searchPackages", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def search_packages_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """Search for access packages using natural language (hybrid vector + text search)."""
    logger.info("searchPackages called — method=%s, url=%s, user_agent=%s, content_type=%s",
                req.method, req.url, req.headers.get("User-Agent", ""), req.headers.get("Content-Type", ""))
    try:
        body = req.get_json()
    except ValueError:
        logger.warning("searchPackages: invalid JSON body")
        return func.HttpResponse(json.dumps({"error": "Invalid JSON body"}), status_code=400, mimetype="application/json")

    logger.info("searchPackages request body: %s", json.dumps(body))
    try:
        status, result = search_packages.handle(body)
    except Exception as e:
        logger.exception("searchPackages failed")
        return func.HttpResponse(json.dumps({"error": str(e)}), status_code=500, mimetype="application/json")
    logger.info("searchPackages response: status=%d, result_count=%d", status, len(result.get("results", [])))
    return func.HttpResponse(json.dumps(result), status_code=status, mimetype="application/json")


@app.function_name("packageDetails")
@app.route(route="packageDetails/{id}", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def package_details_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """Get detailed information about a specific access package."""
    pkg_id = req.route_params.get("id", "")
    auth_header = req.headers.get("Authorization")

    status, result = package_details.handle(pkg_id, auth_header)
    return func.HttpResponse(json.dumps(result), status_code=status, mimetype="application/json")


@app.function_name("requestPackage")
@app.route(route="requestPackage", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def request_package_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """Request assignment to an access package on behalf of the signed-in user."""
    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(json.dumps({"error": "Invalid JSON body"}), status_code=400, mimetype="application/json")

    auth_header = req.headers.get("Authorization")
    status, result = request_package.handle(body, auth_header)
    return func.HttpResponse(json.dumps(result), status_code=status, mimetype="application/json")


# ---------------------------------------------------------------------------
# Timer-triggered sync pipeline
# ---------------------------------------------------------------------------

@app.function_name("syncAccessPackages")
@app.timer_trigger(schedule="0 0 */6 * * *", arg_name="timer", run_on_startup=False)
def sync_access_packages_endpoint(timer: func.TimerRequest) -> None:
    """Run every 6 hours to sync access packages from Entra ID into the search index."""
    logger.info("Starting access package sync (past_due=%s)", timer.past_due)
    try:
        summary = sync_access_packages.sync()
        logger.info("Sync complete: %s", summary)
    except Exception:
        logger.exception("Access package sync failed")
        raise
