#!/usr/bin/env bash
set -e
# App Service 上で FastAPI アプリを Gunicorn + Uvicorn worker で起動するスクリプト
gunicorn -w ${WEB_CONCURRENCY:-2} -k uvicorn.workers.UvicornWorker app:app --bind=0.0.0.0:${PORT:-8000} --timeout 600
