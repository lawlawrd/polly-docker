"""Minimal REST server for the Presidio analyzer."""

from __future__ import annotations

import json
import logging
import os
from logging.config import fileConfig
from pathlib import Path
from typing import Tuple

from flask import Flask, Response, jsonify, request
from presidio_analyzer import (
    AnalyzerEngine,
    AnalyzerEngineProvider,
    AnalyzerRequest,
    RecognizerResult,
)
from werkzeug.exceptions import HTTPException

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
    logger = logging.getLogger("presidio-analyzer")
    logger.setLevel(os.environ.get("LOG_LEVEL", logger.level))
    return logger


def _exclude_attributes_from_dto(results):
    for result in results:
        if hasattr(result, "recognition_metadata"):
            delattr(result, "recognition_metadata")


def _prioritize_emails(results: list[RecognizerResult]) -> list[RecognizerResult]:
    """Drop any non-email entities that overlap an email span."""

    emails = [res for res in results if res.entity_type == "EMAIL_ADDRESS"]
    if not emails:
        return results

    filtered: list[RecognizerResult] = []
    for result in results:
        if result.entity_type == "EMAIL_ADDRESS":
            filtered.append(result)
            continue

        overlaps_email = any(
            not (result.end <= email.start or result.start >= email.end)
            for email in emails
        )
        if overlaps_email:
            continue
        filtered.append(result)
    return filtered


def create_app() -> Flask:
    """Create the Flask application that exposes the analyzer."""

    logger = _configure_logger()
    app = Flask(__name__)

    engine: AnalyzerEngine = AnalyzerEngineProvider(
        analyzer_engine_conf_file=os.environ.get("ANALYZER_CONF_FILE"),
        nlp_engine_conf_file=os.environ.get("NLP_CONF_FILE"),
        recognizer_registry_conf_file=os.environ.get(
            "RECOGNIZER_REGISTRY_CONF_FILE"
        ),
    ).create_engine()

    logger.info("Starting analyzer engine")
    logger.info(_WELCOME)

    @app.get("/health")
    def health() -> str:
        return "Presidio Analyzer service is up"

    @app.post("/analyze")
    def analyze() -> Tuple[Response, int] | Response:
        try:
            payload = AnalyzerRequest(request.get_json())
            if not payload.text:
                raise ValueError("No text provided")
            if not payload.language:
                raise ValueError("No language provided")

            detections = engine.analyze(
                text=payload.text,
                language=payload.language,
                correlation_id=payload.correlation_id,
                score_threshold=payload.score_threshold,
                entities=payload.entities,
                return_decision_process=payload.return_decision_process,
                ad_hoc_recognizers=payload.ad_hoc_recognizers,
                context=payload.context,
                allow_list=payload.allow_list,
                allow_list_match=payload.allow_list_match,
                regex_flags=payload.regex_flags,
            )
            detections = _prioritize_emails(detections)
            _exclude_attributes_from_dto(detections)
            body = json.dumps(
                detections,
                default=lambda item: item.to_dict(),
                sort_keys=True,
            )
            return Response(body, content_type="application/json")
        except TypeError as err:
            message = (
                "Failed to parse /analyze request for AnalyzerEngine.analyze(). "
                f"{err.args[0]}"
            )
            logger.error(message)
            return jsonify(error=message), 400
        except ValueError as err:
            logger.error(str(err))
            return jsonify(error=str(err)), 400
        except Exception as err:  # pragma: no cover - defensive
            logger.error(
                "A fatal error occurred during execution of AnalyzerEngine.analyze(). %s",
                err,
            )
            return jsonify(error=str(err)), 500

    @app.get("/recognizers")
    def recognizers() -> Tuple[Response, int] | Response:
        try:
            names = [rec.name for rec in engine.get_recognizers(request.args.get("language"))]
            return jsonify(names), 200
        except Exception as err:  # pragma: no cover - defensive
            logger.error(
                "A fatal error occurred during execution of AnalyzerEngine.get_recognizers(). %s",
                err,
            )
            return jsonify(error=str(err)), 500

    @app.get("/supportedentities")
    def supported_entities() -> Tuple[Response, int] | Response:
        try:
            entities = engine.get_supported_entities(request.args.get("language"))
            return jsonify(entities), 200
        except Exception as err:  # pragma: no cover - defensive
            logger.error(
                "A fatal error occurred during execution of AnalyzerEngine.supported_entities(). %s",
                err,
            )
            return jsonify(error=str(err)), 500

    @app.errorhandler(HTTPException)
    def http_exception(exc: HTTPException):
        return jsonify(error=exc.description), exc.code

    return app


if __name__ == "__main__":
    flask_app = create_app()
    flask_app.run(host="0.0.0.0", port=int(os.environ.get("PORT", _DEFAULT_PORT)))
