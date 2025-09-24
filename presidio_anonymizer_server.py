"""Minimal REST server for the Presidio anonymizer."""

from __future__ import annotations

import logging
import os
from logging.config import fileConfig
from pathlib import Path

from flask import Flask, Response, jsonify, request
from presidio_anonymizer import AnonymizerEngine, DeanonymizeEngine
from presidio_anonymizer.entities import InvalidParamError
from presidio_anonymizer.services.app_entities_convertor import (
    AppEntitiesConvertor,
)
from werkzeug.exceptions import BadRequest, HTTPException

_DEFAULT_PORT = "3000"
_LOGGING_CONF_FILE = Path(__file__).with_name("logging.ini")
_WELCOME = r"""
 _______  _______  _______  _______ _________ ______  _________ _______
(  ____ )(  ____ )(  ____ \\(  ____ \\__   __/(  __  \\ \__   __/(  ___  )
| (    )|| (    )|| (    \/| (    \/   ) (   | (  \\  )   ) (   | (   ) |
| (____)|| (____)|| (__    | (_____    | |   | |   ) |   | |   | |   | |
|  _____)|     __)|  __)   (_____  )   | |   | |   | |   | |   | |   | |
| (      | (\\ (   | (            ) |   | |   | |   ) |   | |   | |   | |
| )      | ) \\ \\__| (____/\\/\\____) |___) (___| (__/  )___) (___| (___) |
|/       |/   \\__/(_______/\\_______)\\_______/(______/ \\_______/(_______)
"""


def _configure_logger() -> logging.Logger:
    if _LOGGING_CONF_FILE.exists():
        fileConfig(_LOGGING_CONF_FILE)
    else:
        logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger("presidio-anonymizer")
    logger.setLevel(os.environ.get("LOG_LEVEL", logger.level))
    return logger


def create_app() -> Flask:
    """Create the Flask application that exposes the anonymizer."""

    logger = _configure_logger()
    app = Flask(__name__)

    anonymizer = AnonymizerEngine()
    deanonymizer = DeanonymizeEngine()

    logger.info("Starting anonymizer engine")
    logger.info(_WELCOME)

    @app.get("/health")
    def health() -> str:
        return "Presidio Anonymizer service is up"

    @app.post("/anonymize")
    def anonymize() -> Response:
        body = request.get_json()
        if not body:
            raise BadRequest("Invalid request json")

        configuration = AppEntitiesConvertor.operators_config_from_json(
            body.get("anonymizers")
        )
        if AppEntitiesConvertor.check_custom_operator(configuration):
            raise BadRequest("Custom type anonymizer is not supported")

        results = AppEntitiesConvertor.analyzer_results_from_json(
            body.get("analyzer_results")
        )
        outcome = anonymizer.anonymize(
            text=body.get("text", ""),
            analyzer_results=results,
            operators=configuration,
        )
        return Response(outcome.to_json(), mimetype="application/json")

    @app.post("/deanonymize")
    def deanonymize() -> Response:
        body = request.get_json()
        if not body:
            raise BadRequest("Invalid request json")

        entities = AppEntitiesConvertor.deanonymize_entities_from_json(body)
        configuration = AppEntitiesConvertor.operators_config_from_json(
            body.get("deanonymizers")
        )
        outcome = deanonymizer.deanonymize(
            text=body.get("text", ""),
            entities=entities,
            operators=configuration,
        )
        return Response(outcome.to_json(), mimetype="application/json")

    @app.get("/anonymizers")
    def anonymizers():
        return jsonify(anonymizer.get_anonymizers())

    @app.get("/deanonymizers")
    def deanonymizers():
        return jsonify(deanonymizer.get_deanonymizers())

    @app.errorhandler(InvalidParamError)
    def invalid_param(err: InvalidParamError):
        logger.warning(
            "Request failed with parameter validation error: %s", err.err_msg
        )
        return jsonify(error=err.err_msg), 422

    @app.errorhandler(HTTPException)
    def http_exception(exc: HTTPException):
        return jsonify(error=exc.description), exc.code

    @app.errorhandler(Exception)
    def server_error(exc: Exception):  # pragma: no cover - defensive
        logger.error("A fatal error occurred during execution: %s", exc)
        return jsonify(error="Internal server error"), 500

    return app


if __name__ == "__main__":
    flask_app = create_app()
    flask_app.run(host="0.0.0.0", port=int(os.environ.get("PORT", _DEFAULT_PORT)))
